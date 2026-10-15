# Shared functions of the M4 / M5 block drivers (m4-block.sh, m5-block.sh); sourced, not run.
# Caller sets: P, X, E (evidence dir), B (block), R (round), OWNER, SEED_BASE; install check list INSTALL (lines
# "<guest path below /home/comsys> <Host file>"); GUEST_INIT, HOST_IMAGE (dirs of the initial image).
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
CHOWNED=0
# Stop this block's servers only: the guest run dirs recorded in this block's run manifests (run.sh writes
# guest_run_dir before it starts a server).
block_stop_servers() {
  local ip g
  for ip in "${IPS[@]}"; do
    for g in $(sed -n 's/^guest_run_dir=//p' "$E"/*/manifest.txt 2>/dev/null); do
      $SSH comsys@$ip "for k in 0 1; do [ -e $g/node\$k.pid ] && \$(dirname $g)/../bin/vdb-node.sh stop $g \$k; done; true" < /dev/null 2>&1 \
        | sed "s|^|$ip $g |" >> "$E/rollback.out"
    done
    $SSH comsys@$ip 'echo procs=$(pgrep -c -x vdb-server)' < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
}
# page MSI: every shm-<run> dir whose load was attempted (load-vm0.txt) and that has no "teardown PASS" in its
# steps.log gets p-popcorn-shm.sh teardown; if teardown stops on the instrumentation gate, instr-on, then teardown.
block_shm_cleanup() {
  [ -n "${C8:-}" ] || return 0
  local r
  for r in "$E"/shm-*/; do
    r=${r%/}
    [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    echo "$(date -Is) cleanup teardown $r" >> "$E/cleanup.out"
    if ! env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; then
      if grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null; then
        env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
          && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1
      fi
    fi
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: packet §6)" | tee -a "$E/cleanup.out"
  done
}
# dax0.0 back to root:root 600 (blocks that chowned it)
block_dax_root() {
  local ip
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
      < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
}
block_rollback() { block_stop_servers; block_dax_root; }
# On every block exit: stop this block's servers, clean up page MSI, then dax rollback, then the lock.
block_finish() {
  block_stop_servers
  block_shm_cleanup
  [ $CHOWNED = 1 ] && block_dax_root
  bash $X/host-gate.sh unlock "$OWNER"
}
block_start() {
  [ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
  bash $X/host-gate.sh lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
  trap block_finish EXIT
  echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD))"
}
run() {  # name, env assignments...  (stops the sequence on M4RUN STOP)
  local name=$1; shift
  env SEED=$((SEED_BASE + R)) "$@" bash $X/m4-run.sh "$name" "$E" 2>&1 | tee -a "$E/runs.log" | grep -E "^M4RUN|SEQUENCE"
  local st=${PIPESTATUS[0]}
  [ $st = 0 ] || { echo "$(date -Is) SEQUENCE STOP at $name"; exit 1; }
}
# run order: seeded by SHUFFLE_SEED (default the block owner)
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "${SHUFFLE_SEED:-$OWNER}" "$@"; }
# confirm mean of a run, only if the SLO search ended without a note (a "confirm failed" run is never used for L)
confirm_x() {
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{})
if s.get("note"): sys.exit("run has a note: " + s["note"])
x=c.get("x_mean",0)
if not x > 0: sys.exit("no confirm result")
print(x)' "$1"
}
rate() { python3 -c 'import sys; x,u=float(sys.argv[1]),float(sys.argv[2]); assert x>0; print(round(0.5*x/(1-u/100),3))' "$1" "$2"; }
chown_dax() {
  local ip
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip.out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$E/chown-$ip.out" || { echo "SEQUENCE STOP: chown $ip"; exit 1; }
  done
}
precheck() {  # expected kernel release
  local kr=$1 i f sums
  sums=$(sha256sum < "$HOST_IMAGE/SHA256SUMS" | cut -d' ' -f1)
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$kr INIT_DIR=$GUEST_INIT INIT_SUMS=$sums INIT_CHECK=$([ $i = 0 ] && echo 1 || echo 0) INSTALL_DIRS='$(echo "$INSTALL" | awk '{print $1}' | tr '\n' ' ')' bash -s" \
      < $X/m4-precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || { echo "SEQUENCE STOP: precheck ${IPS[$i]}"; exit 1; }
    while read -r g h; do
      [ -n "$g" ] || continue
      [ -f "$h" ] || { echo "SEQUENCE STOP: missing Host file $h"; exit 1; }
      grep -q "^$(sha256sum "$h" | cut -d' ' -f1)  /home/comsys/$g\$" "$E/precheck-${IPS[$i]}.out" \
        || { echo "SEQUENCE STOP: ${IPS[$i]} /home/comsys/$g != $h"; exit 1; }
    done <<< "$INSTALL"
  done
}
