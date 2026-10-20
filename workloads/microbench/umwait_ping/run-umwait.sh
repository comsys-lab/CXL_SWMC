#!/bin/bash
# umwait-remote-wake matrix (reports/experiments/umwait-remote-wake.md), run from the Host by the experiment session.
#   run-umwait.sh <evidence dir>        e.g. recovery/umwait-remote-wake-v1 (must not exist or be empty)
# Env: BIN (default builds/umwait-ping/1/umwait_ping), REGION (default CXL_SWMC/config/cxl_region-ring2m.yaml),
#      CPU (guest CPU for both roles, default 1), N (pings, default 50000), GAP_MIN/GAP_MAX (us, default 1/200),
#      OFFSET (device offset of line X; default from REGION: msg_ring offset - 2 MiB), IP0/IP1, DRY=1 (prechecks only).
# Matrix: {spin, umwait C0.2 (--c02 0), umwait C0.1 (--c02 1)} x {vm0->vm1, vm1->vm0}; the responder runs on the
# second VM of the direction, the initiator on the first.
# Touches, on both guests: /home/comsys/umwait_ping{,.region.yaml} (copied), /dev/dax0.0 owner (chown comsys, restored
# to root:root 600 on exit, also on failure). Reads umwait_control before/after; never writes it; no module change.
# Refuses when workspaces/MEASUREMENT.lock exists, an evaluation chain / runset / main-block runs, or cxl_shm is
# loaded on either guest.
set -euo pipefail
umask 022
P=/home/comsys/sungsu/destijl-control
R=${1:?usage: run-umwait.sh <evidence dir>}
BIN=${BIN:-$P/builds/umwait-ping/1/umwait_ping}
REGION=${REGION:-$P/CXL_SWMC/config/cxl_region-ring2m.yaml}
CPU=${CPU:-1}; N=${N:-50000}; GAP_MIN=${GAP_MIN:-1}; GAP_MAX=${GAP_MAX:-200}
IP=("${IP0:-192.168.122.100}" "${IP1:-192.168.122.101}")
GBIN=/home/comsys/umwait_ping; GREG=/home/comsys/umwait_ping.region.yaml
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
  -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes
  -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
on() { local k=$1; shift; ssh -T "${FLAGS[@]}" "comsys@${IP[$k]}" "$@" < /dev/null; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
die() { log "STOP: $*"; exit 1; }

# ---- refusals (before anything is written to a guest) ----
[ -e "$P/workspaces/MEASUREMENT.lock" ] && { echo "refuse: workspaces/MEASUREMENT.lock exists" >&2; exit 1; }
busy=$(pgrep -af 'eval/[^ ]*-chain-[^ ]*\.sh|runset|main-block' | grep -v -e "^$$ " -e pgrep || true)
[ -n "$busy" ] && { echo "refuse: evaluation processes running:" >&2; echo "$busy" >&2; exit 1; }
[ -x "$BIN" ] || { echo "refuse: no binary $BIN" >&2; exit 1; }
[ -r "$REGION" ] || { echo "refuse: no region config $REGION" >&2; exit 1; }
if [ -e "$R" ] && [ -n "$(ls -A "$R")" ]; then echo "refuse: $R exists and is not empty (evidence is frozen)" >&2; exit 1; fi
mkdir -p "$R"

if [ -z "${OFFSET:-}" ]; then
  ring=$(sed -n 's/^msg_ring: *\[ *\([0-9]*\) *,.*/\1/p' "$REGION")
  [ -n "$ring" ] || die "no msg_ring in $REGION"
  OFFSET=$((ring - 2097152))
fi

for k in 0 1; do
  on $k true || die "ssh vm$k"
  if on $k "lsmod | grep -qw '^cxl_shm'"; then die "cxl_shm is loaded on vm$k (this test runs without it; not unloading)"; fi
  on $k "sudo -n true" || die "no passwordless sudo on vm$k"
  on $k "uname -r; nproc; grep -m1 -o -w waitpkg /proc/cpuinfo || echo no-waitpkg; \
    for f in enable_c02 max_time; do echo \"\$f=\$(cat /sys/devices/system/cpu/umwait_control/\$f 2>/dev/null || echo missing)\"; done; \
    stat -c '%U:%G %a' /dev/dax0.0; cat /sys/bus/dax/devices/dax0.0/align 2>/dev/null || true; lsmod" > "$R/before-vm$k.txt" \
    || die "precheck read on vm$k"
  [ "$(on $k nproc)" -gt "$CPU" ] || die "vm$k has no CPU $CPU"
done
{ echo "date=$(date -Is)"; echo "script=$0 sha256=$(sha256sum "$0" | cut -d' ' -f1)"
  echo "bin=$BIN sha256=$(sha256sum "$BIN" | cut -d' ' -f1)"
  [ -r "$(dirname "$BIN")/manifest.txt" ] && sed 's/^/build: /' "$(dirname "$BIN")/manifest.txt"
  echo "region=$REGION sha256=$(sha256sum "$REGION" | cut -d' ' -f1)"
  echo "offset=$OFFSET cpu=$CPU n=$N gap_us=$GAP_MIN..$GAP_MAX ips=${IP[*]}"; } > "$R/manifest.txt"
log "prechecks PASS (no lock, no chain, cxl_shm absent on both VMs); offset=$OFFSET"
for k in 0 1; do
  log "vm$k: $(grep -E '^(enable_c02|max_time)=|waitpkg' "$R/before-vm$k.txt" | tr '\n' ' ')"
  grep -q '^enable_c02=1$' "$R/before-vm$k.txt" || log "NOTE vm$k enable_c02 != 1: its C0.2 runs execute as C0.1"
  grep -qx waitpkg "$R/before-vm$k.txt" || log "NOTE vm$k has no waitpkg: its umwait runs fail at once (spin still runs)"
done
[ "${DRY:-0}" = 1 ] && { log "DRY=1: stop after prechecks"; exit 0; }

restore() {
  local k
  for k in 0 1; do
    on $k "pkill -u comsys -x umwait_ping || true" || true
    on $k "sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; stat -c '%U:%G %a' /dev/dax0.0; \
      for f in enable_c02 max_time; do echo \"\$f=\$(cat /sys/devices/system/cpu/umwait_control/\$f 2>/dev/null || echo missing)\"; done" \
      > "$R/after-vm$k.txt" 2>&1 || true
    log "vm$k restored: $(tr '\n' ' ' < "$R/after-vm$k.txt")"
  done
}
trap restore EXIT

for k in 0 1; do
  scp -q "${FLAGS[@]}" "$BIN" "comsys@${IP[$k]}:$GBIN" && scp -q "${FLAGS[@]}" "$REGION" "comsys@${IP[$k]}:$GREG" \
    || die "copy to vm$k"
  [ "$(on $k "sha256sum $GBIN" | cut -d' ' -f1)" = "$(sha256sum "$BIN" | cut -d' ' -f1)" ] || die "binary hash on vm$k"
  on $k "sudo -n chown comsys /dev/dax0.0 && stat -c '%U:%G %a' /dev/dax0.0" > "$R/chown-vm$k.txt" || die "chown vm$k"
done

printf 'run\tinit_vm\tresp_vm\tmode\tc02\tnonce\tinit_rc\tresp_rc\n' > "$R/runs.tsv"
nonce=$(( $(date +%s) & 0xffffff ))
fail=0
for dir in "0 1" "1 0"; do
  read -r I S <<< "$dir"
  for m in spin umwait:0 umwait:1; do
    mode=${m%%:*}; c02=0; [ "$mode" = umwait ] && c02=${m#*:}
    tag=vm$I-to-vm$S-$mode; [ "$mode" = umwait ] && { [ "$c02" = 0 ] && tag+=-c02 || tag+=-c01; }
    nonce=$((nonce + 1))
    common="--mode $mode --c02 $c02 --nonce $nonce --region $GREG --offset $OFFSET --cpu $CPU --n $N --csv -"
    log "run $tag nonce=$nonce"
    on $S "$GBIN --role resp $common" > "$R/$tag.resp.csv" 2> "$R/$tag.resp.log" & rpid=$!
    sleep 1
    irc=0; on $I "$GBIN --role init $common --gap-us-min $GAP_MIN --gap-us-max $GAP_MAX" \
      > "$R/$tag.init.csv" 2> "$R/$tag.init.log" || irc=$?
    rrc=0; wait $rpid || rrc=$?
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$I" "$S" "$mode" "$c02" "$nonce" "$irc" "$rrc" >> "$R/runs.tsv"
    log "  init: $(grep '^summary' "$R/$tag.init.log" || echo 'no summary') rc=$irc"
    log "  resp: $(grep '^summary' "$R/$tag.resp.log" || echo 'no summary') rc=$rrc"
    [ $irc = 0 ] && [ $rrc = 0 ] || fail=$((fail + 1))
  done
done
grep -h '^summary' "$R"/*.log > "$R/summary.txt" || true
log "matrix done: $fail failed run(s); evidence $R"
[ $fail = 0 ]
