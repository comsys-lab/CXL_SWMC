#!/bin/bash
# ROCKSDB-V1 block (reports/ROCKSDB-V1-packet.md), modelled on experiments/lmdb/f1-block.sh, for N VMs (NODES).
# Holds the measurement/VM lock (host-gate.sh lock <OWNER>) for the whole block; on EVERY exit (trap): our rocksdb
# processes killed by command line on every VM (TERM, <= 15 s, KILL; procs=0 and an empty `sudo -n fuser /dev/dax0.0`
# required), every Popcorn cxl_shm load of this block without "teardown PASS" torn down, /dev/dax0.0 back to
# root:root 600 on every VM (stat checked), final dmesg check recorded, lock released. "ROLLBACK FAIL" / "CLEANUP
# FAILED" lines = stop and manual check. Stops at the first unexpected result.
# usage: v1-block.sh <evidence dir (exists; empty except tasks-check.txt / block.out)>
# Steps: lock, PT pretouch check (N VMs), H0 Host gate, G1 install (new guest dir L, sha256 of every VM MUST match the
# Host's), G2 pre-check (kernel, cxl_shm not loaded, dax0.0 root:root 600 and unused, no server, install sha256 match,
# memory), dmesg baseline, then the runs of RUNS in order; before an all-HWcc run /dev/dax0.0 is chowned to comsys,
# before a Popcorn run it is back at root:root 600 (p-popcorn-shm.sh owns chown/teardown then); after every run a
# dmesg check; PT pretouch check (end); BLOCK DONE.
# env (required): OWNER (lock owner, e.g. ROCKSDB-V1-v1-n2), EXPECT_K (guest release = Popcorn build 12, all systems run
#   on it), PRETOUCH_DIR (ENV-pretouch evidence dir of the VMs' current QEMU lifetime), L (guest install dir, NEW per
#   block and per N, e.g. /home/comsys/rocksdb3-n2: 8-VM overlays inherit vm0's files, so a fresh name per N), RUNS (one
#   run per line: "<name> VAR=value ..." passed to pilot-run.sh, e.g. "hw-u50-func SYS=all-HWcc KIND=functional
#   UPDATE_RATIO=0.5 LOG=1 KEYS=2000000"; all-HWcc runs before Popcorn runs is the recommended order).
# optional: NODES (192.168.122.100 192.168.122.101), VM_DOMAINS (cxl_vm0 cxl_vm1; libvirt names in NODES order),
#   BUILD (builds/rocksdb/3), LOADGEN_BUILD (builds/rocksdb-loadgen/1), C8 K8 GT8 RECV_MODE (needed when a run has
#   SYS=Popcorn), MEASURE (0; 1 = H1_MEASURE_RUN=1 with MEASURE_PART_DIR: loadgen in measure.slice + h1-gate),
#   EXPECT_DAX_UUID, MIN_MEM_G (16), REGION (CXL_SWMC/config/cxl_region.yaml; Popcorn on N > 2 needs
#   config/cxl_region-ring2m.yaml: 2 MiB msg_ring), POP_IPS is set to NODES for the Popcorn bundle (p-popcorn-shm.sh
#   drives only .100/.101 without it; bundle-n-v1 for N > 2); with MEASURE=1 also MEASURE_ENV / MEASURE_PART_SCRIPT
#   (N-VM scripts, e.g. scripts/host/measure-env-n.sh) and EXPECT_RUNNING (default VM_DOMAINS) for h1-gate.sh;
#   GATE_SCRIPT (optional): a Host gate wrapper called as `bash $GATE_SCRIPT check <out>` (rc 0 = pass) instead of
#   h1-gate.sh / host-gate.sh, for H0 and for every run (N-VM measurement gate, e.g. scripts/host/h3-gate.sh).
# eval3 additions (2026-11-01; all optional, unset = the behaviour above):
#   POP_BUNDLE_SHA  sha256 of C8/packet.sha256; checked (+ sha256sum -c) before anything runs when a run has SYS=Popcorn;
#                   REGION must then equal C8/tools/cxl_region.yaml
#   EXPECT_NPROC    online CPUs every guest must show (precheck; 4 = the 4 vCPU rule, user 2026-11-01)
#   SLO_EXTRA       exported loadgen arguments appended to every KIND=slo run (pilot-run.sh)
#   DRY=1           validate the environment, bundles, region, build files and every RUNS line (pilot-run.sh DRY=1) and
#                   print the plan; no lock, no ssh, nothing written; the evidence dir need not exist. "BLOCK DRY PASS".
# The helper scripts are taken from this script's own directory (the live tree when run from CXL_SWMC).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=$1
DRY=${DRY:-0}; [[ $DRY =~ ^[01]$ ]] || { echo "BLOCK STOP: bad DRY"; exit 2; }
P=/home/comsys/sungsu/destijl-control X=$(cd "$(dirname "$0")" && pwd) G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
: "${OWNER:?}" "${EXPECT_K:?}" "${PRETOUCH_DIR:?}" "${L:?L = new guest install dir}" "${RUNS:?}"
case "$L" in /home/comsys/?*) ;; *) echo "BLOCK STOP: L must be under /home/comsys/"; exit 2;; esac
read -r -a IPS <<< "${NODES:-192.168.122.100 192.168.122.101}"
export NODES="${IPS[*]}" VM_DOMAINS="${VM_DOMAINS:-cxl_vm0 cxl_vm1}" POP_IPS="${IPS[*]}"
REGION=${REGION:-$P/CXL_SWMC/config/cxl_region.yaml}
BUILD=${BUILD:-$P/builds/rocksdb/3} LOADGEN_BUILD=${LOADGEN_BUILD:-$P/builds/rocksdb-loadgen/1}
PAT='(^|[ /])bin/rocksdb-serve[r]( |$)'
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
if grep -q "SYS=Popcorn" <<< "$RUNS"; then : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"; [ "$EXPECT_K" = "$K8" ] || { echo "BLOCK STOP: EXPECT_K != K8"; exit 2; }; fi
# De Stijl v2 runs (SYS=DeStijl; as experiments/eval/h2n-block.sh ds): DS_C DS_K DS_GT DS_BUNDLE_SHA RECV_MODE (poll |
# sleep); EXPECT_K = DS_K (every run of the block on the De Stijl kernel), so Popcorn and De Stijl never share a block;
# REGION must be the De Stijl region config (the bundle's tools/cxl_region.yaml, e.g. config/cxl_region-destijl.yaml).
if grep -q "SYS=DeStijl" <<< "$RUNS"; then
  : "${DS_C:?}" "${DS_K:?}" "${DS_GT:?}" "${DS_BUNDLE_SHA:?}" "${RECV_MODE:?}"
  ! grep -q "SYS=Popcorn" <<< "$RUNS" || { echo "BLOCK STOP: Popcorn and De Stijl runs need different guest kernels"; exit 2; }
  [ "$EXPECT_K" = "$DS_K" ] || { echo "BLOCK STOP: EXPECT_K != DS_K"; exit 2; }
  [ -f "$DS_C/p-destijl-shm.sh" ] && [ "$(sha256sum < "$DS_C/packet.sha256" | cut -c1-64)" = "$DS_BUNDLE_SHA" ] \
    && (cd "$DS_C" && sha256sum -c --quiet packet.sha256) || { echo "BLOCK STOP: DS_C is not the verified De Stijl bundle"; exit 2; }
  cmp -s "$REGION" "$DS_C/tools/cxl_region.yaml" || { echo "BLOCK STOP: REGION differs from the De Stijl bundle's region config"; exit 2; }
fi
if [ "${MEASURE:-0}" = 1 ]; then  # h1-gate.sh needs both (partition + measurement environment evidence)
  : "${MEASURE_PART_DIR:?MEASURE=1 needs MEASURE_PART_DIR}" "${MEASURE_ENV_DIR:?MEASURE=1 needs MEASURE_ENV_DIR}"
  export H1_MEASURE_RUN=1 MEASURE_PART_DIR MEASURE_ENV_DIR EXPECT_RUNNING="${EXPECT_RUNNING:-$VM_DOMAINS}"
  [ -z "${MEASURE_ENV:-}" ] || export MEASURE_ENV
  [ -z "${MEASURE_PART_SCRIPT:-}" ] || export MEASURE_PART_SCRIPT
fi
if [ -n "${GATE_SCRIPT:-}" ]; then  # h3-gate.sh (popcorn-n): needs the running set and both measurement evidence dirs
  [ -f "$GATE_SCRIPT" ] || { echo "BLOCK STOP: GATE_SCRIPT $GATE_SCRIPT missing"; exit 2; }
  : "${MEASURE_ENV_DIR:?GATE_SCRIPT needs MEASURE_ENV_DIR}" "${MEASURE_PART_DIR:?GATE_SCRIPT needs MEASURE_PART_DIR}"
  export GATE_SCRIPT MEASURE_ENV_DIR MEASURE_PART_DIR EXPECT_RUNNING="${EXPECT_RUNNING:-$VM_DOMAINS}"
fi
if grep -q "SYS=Popcorn" <<< "$RUNS" && [ -n "${POP_BUNDLE_SHA:-}" ]; then  # eval3: verified Popcorn bundle + its region
  [ -f "$C8/p-popcorn-shm.sh" ] && [ "$(sha256sum < "$C8/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] \
    && (cd "$C8" && sha256sum -c --quiet packet.sha256) || { echo "BLOCK STOP: C8 is not the verified Popcorn bundle (POP_BUNDLE_SHA)"; exit 2; }
  cmp -s "$REGION" "$C8/tools/cxl_region.yaml" || { echo "BLOCK STOP: REGION differs from the Popcorn bundle's region config"; exit 2; }
fi
[ -z "${EXPECT_NPROC:-}" ] || [[ $EXPECT_NPROC =~ ^[1-9][0-9]*$ ]] || { echo "BLOCK STOP: bad EXPECT_NPROC"; exit 2; }
[ -f "$BUILD/manifest.txt" ] && [ -x "$BUILD/bin/rocksdb-server" ] && [ -x "$LOADGEN_BUILD/loadgen" ] || { echo "BLOCK STOP: BUILD or LOADGEN_BUILD incomplete"; exit 2; }
[ -f "$REGION" ] || { echo "BLOCK STOP: REGION $REGION missing"; exit 2; }
if [ "$DRY" = 1 ]; then  # plan only: no lock, no ssh, nothing written
  echo "BLOCK DRY: E=$E OWNER=$OWNER N=${#IPS[@]} NODES=[${IPS[*]}] VM_DOMAINS=[$VM_DOMAINS] EXPECT_K=$EXPECT_K"
  echo "BLOCK DRY: L=$L BUILD=$BUILD (server $(sha256sum < $BUILD/bin/rocksdb-server | cut -c1-16)) LOADGEN_BUILD=$LOADGEN_BUILD (loadgen $(sha256sum < $LOADGEN_BUILD/loadgen | cut -c1-16))"
  echo "BLOCK DRY: REGION=$REGION sha256=$(sha256sum < "$REGION" | cut -c1-16) $(grep -E '^msg_ring:' "$REGION" | cut -d'#' -f1)"
  echo "BLOCK DRY: PRETOUCH_DIR=$PRETOUCH_DIR GATE=${GATE_SCRIPT:-host-gate/h1-gate} MEASURE=${MEASURE:-0} EXPECT_DAX_UUID=${EXPECT_DAX_UUID:-} EXPECT_NPROC=${EXPECT_NPROC:-} MIN_MEM_G=${MIN_MEM_G:-16}"
  echo "BLOCK DRY: SLO_EXTRA=[${SLO_EXTRA:-}]"
  echo "BLOCK DRY: steps: lock $OWNER; pretouch-check-n; H0 gate; G1 install.sh -> $L on ${#IPS[@]} VMs; G2 precheck x${#IPS[@]}; dmesg base"
  [ -d "$E" ] && echo "BLOCK DRY: evidence dir exists ($(ls -A "$E" | wc -l) entries)" || echo "BLOCK DRY: evidence dir does not exist yet (the caller creates it + tasks-check.txt)"
  drc=0
  while read -r name args; do
    [ -n "${name:-}" ] || continue
    # shellcheck disable=SC2206
    A=($args)
    sys=""; for x in "${A[@]}"; do case $x in SYS=*) sys=${x#SYS=};; esac; done
    case "$sys" in
      all-HWcc) ;;
      Popcorn) A+=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE);;
      DeStijl) A+=(DS_C=$DS_C DS_K=$DS_K DS_GT=$DS_GT RECV_MODE=$RECV_MODE);;
      *) echo "BLOCK DRY STOP: $name: SYS must be all-HWcc, Popcorn or DeStijl"; drc=1; continue;;
    esac
    env DRY=1 LOCK_OWNER=$OWNER NODES="${IPS[*]}" V=$L BUILD=$BUILD LOADGEN_BUILD=$LOADGEN_BUILD "${A[@]}" bash $X/pilot-run.sh "$name" "$E" < /dev/null 2>&1 | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" = 0 ] || drc=1
  done <<< "$RUNS"
  [ $drc = 0 ] && { echo "BLOCK DRY PASS"; exit 0; } || { echo "BLOCK DRY FAIL"; exit 1; }
fi
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -vE '^(tasks-check\.txt|block\.out)$')" ] || { echo "BLOCK STOP: $E missing or not empty"; exit 2; }
[ -s "$E/tasks-check.txt" ] || { echo "BLOCK STOP: $E/tasks-check.txt missing (state/TASKS.md: no other active VM user)"; exit 2; }
bash $G lock "$OWNER" || { echo "BLOCK STOP: lock"; exit 2; }
DMESG_BAD='BUG:|Oops|WARNING:|Call Trace|general protection|segfault|[Ee]rror|ERROR|soft lockup|hung_task'
finish() {
  set +eu
  pkill -TERM -P $$ 2>/dev/null; sleep 1  # our own children first (pilot-run.sh, run.sh, loadgen)
  local out ip r
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "pkill -u comsys -f '$PAT'; for i in \$(seq 15); do pgrep -u comsys -f '$PAT' > /dev/null || break; sleep 1; done
      pkill -9 -u comsys -f '$PAT'; sleep 1; echo procs=\$(pgrep -c -u comsys -f '$PAT'); echo fuser=[\$(sudo -n fuser /dev/dax0.0 2>&1 | tr -d ' \n')]" < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "procs=0" && echo "$out" | grep -qx "fuser=\[\]" \
      || echo "ROLLBACK FAIL: $ip rocksdb process left or /dev/dax0.0 still in use (see rollback.out)" | tee -a "$E/rollback.out"
  done
  for r in "$E"/shm-*/; do  # every attempted cxl_shm load without "teardown PASS"
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    env POP_IPS="$POP_IPS" K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1 \
      || { grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null && env POP_IPS="$POP_IPS" K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
           && env POP_IPS="$POP_IPS" K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; }
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: reports/M5-pilot-kv.md §6)" | tee -a "$E/cleanup.out"
  done
  for r in "$E"/dsshm-*/; do  # De Stijl loads: same rule, p-destijl-shm.sh teardown
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    env DS_IPS="${IPS[*]}" K=$DS_K GT=$DS_GT C=$DS_C R=$r bash $DS_C/p-destijl-shm.sh teardown >> "$E/cleanup.out" 2>&1
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: p-destijl-shm.sh teardown)" | tee -a "$E/cleanup.out"
  done
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "stat=root:root 600" || echo "ROLLBACK FAIL: $ip dax0.0 not root:root 600" | tee -a "$E/rollback.out"
  done
  [ -z "${DMESG_BASE_DONE:-}" ] || { ( dmesg_check final ) > "$E/dmesg-final.out" 2>&1 || echo "$(date -Is) final dmesg check: see dmesg-final.out" >> "$E/rollback.out"; }
  bash $G unlock "$OWNER"
}
dmesg_count() { local c; c=$($SSH comsys@${IPS[$1]} 'dmesg | wc -l' < /dev/null 2>/dev/null) || return 1; [[ $c =~ ^[0-9]+$ ]] || return 1; echo "$c"; }
dmesg_base() {
  local i c
  for i in "${!IPS[@]}"; do c=$(dmesg_count $i) || stop "dmesg baseline vm$i"; echo "$c" > "$E/dmesg-base-vm$i.txt"; done
  DMESG_BASE_DONE=1
}
dmesg_check() {  # tag; 1 on a new bad line, an ssh failure, a bad stored count or a wrap
  local i n c bad=0
  for i in "${!IPS[@]}"; do
    n=$(cat "$E/dmesg-base-vm$i.txt" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || { echo "dmesg vm$i ($1): stored baseline '$n'" | tee -a "$E/block.log"; bad=1; continue; }
    c=$(dmesg_count $i) || { echo "dmesg vm$i ($1): ssh/count failed" | tee -a "$E/block.log"; bad=1; continue; }
    [ "$c" -ge "$n" ] || { echo "dmesg vm$i ($1): ring buffer wrapped ($n -> $c)" | tee -a "$E/block.log"; bad=1; continue; }
    $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 || { bad=1; continue; }
    grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" > /dev/null && { echo "dmesg vm$i ($1): $(grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" | head -3)" | tee -a "$E/block.log"; bad=1; }
  done
  return $bad
}
trap finish EXIT
trap 'echo "$(date -Is) BLOCK STOP signal" | tee -a "$E/block.log"; exit 130' INT TERM HUP
stop() { echo "$(date -Is) BLOCK STOP $*" | tee -a "$E/block.log"; exit 1; }
step() { echo "$(date -Is) == $*" | tee -a "$E/block.log"; }
dax_owner() {  # comsys | root
  local ip out want
  for ip in "${IPS[@]}"; do
    if [ "$1" = comsys ]; then out=$($SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null 2>&1); want="comsys:root 600"
    else out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null 2>&1); want="root:root 600"; fi
    echo "$(date -Is) $ip dax0.0 -> $out" >> "$E/block.log"
    [ "$out" = "$want" ] || stop "dax0.0 on $ip: '$out' != '$want'"
  done
}

step "PT pretouch check (start, ${#IPS[@]} VMs)"
bash $X/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-start.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (start)"
step "H0 Host gate"
if [ -n "${GATE_SCRIPT:-}" ]; then export GATE_SCRIPT; bash "$GATE_SCRIPT" check "$E/gate-H0.txt" || stop "gate ($GATE_SCRIPT)"
elif [ "${MEASURE:-0}" = 1 ]; then bash $P/CXL_SWMC/experiments/h1/h1-gate.sh check "$E/gate-H0.txt" || stop "h1 gate"
else bash $G check "$E/gate-H0.txt" || stop "host gate"; fi
step "G1 install ($L)"
NODES="${IPS[*]}" BUILD=$BUILD L=$L REGION=$REGION bash $X/install.sh "$E/install.log" > "$E/install.out" 2>&1 || stop "install (see install.out)"
[ "$(grep -c '^ldd_not_found=0$' "$E/install.log")" = "${#IPS[@]}" ] || stop "install: ldd"
WANT="$(sha256sum < $BUILD/bin/rocksdb-server | cut -c1-64) $(sha256sum < $X/rocksdb-node.sh | cut -c1-64) $(sha256sum < $REGION | cut -c1-64)"
{ echo "region=$REGION sha256=$(sha256sum < $REGION | cut -c1-64) $(grep -E '^msg_ring:' $REGION) nodes=${#IPS[@]}"
  case ${#IPS[@]} in 2) s=4096;; 4) s=1024;; 8) s=256;; *) s=unknown;; esac
  echo "msg_ring_slots_per_window(popcorn-n, 2 MiB ring)=$s (meaningful with cxl_region-ring2m.yaml)"; } | tee -a "$E/block.log" > "$E/region.txt"
step "G2 pre-check"
for i in "${!IPS[@]}"; do
  $SSH comsys@${IPS[$i]} "EXPECT_K=$EXPECT_K L=$L EXPECT_SHA='$WANT' EXPECT_DAX_UUID=${EXPECT_DAX_UUID:-} EXPECT_NPROC=${EXPECT_NPROC:-} MIN_MEM_G=${MIN_MEM_G:-16} bash -s" \
    < $X/precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i: $(grep 'PRECHECK FAIL' "$E/precheck-vm$i.txt")"
done
dmesg_base
OWNED=root
while read -r name args; do
  [ -n "${name:-}" ] || continue
  # shellcheck disable=SC2206
  A=($args)
  sys=""; for x in "${A[@]}"; do case $x in SYS=*) sys=${x#SYS=};; esac; done
  case "$sys" in
    all-HWcc) [ "$OWNED" = comsys ] || { step "dax0.0 -> comsys (all-HWcc)"; dax_owner comsys; OWNED=comsys; };;
    Popcorn)  [ "$OWNED" = root ] || { step "dax0.0 -> root:root 600 (Popcorn cycle owns it)"; dax_owner root; OWNED=root; }
              A+=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE);;
    DeStijl)  [ "$OWNED" = root ] || { step "dax0.0 -> root:root 600 (De Stijl cycle owns it)"; dax_owner root; OWNED=root; }
              A+=(DS_C=$DS_C DS_K=$DS_K DS_GT=$DS_GT RECV_MODE=$RECV_MODE);;
    *) stop "$name: SYS must be all-HWcc, Popcorn or DeStijl";;
  esac
  step "$name ${A[*]}"
  env LOCK_OWNER=$OWNER NODES="${IPS[*]}" V=$L BUILD=$BUILD LOADGEN_BUILD=$LOADGEN_BUILD "${A[@]}" bash $X/pilot-run.sh "$name" "$E" < /dev/null 2>&1 \
    | tee -a "$E/runs.log" | grep -E "^PILOTRUN"
  [ ${PIPESTATUS[0]} = 0 ] || stop "$name"
  kind=""; for x in "${A[@]}"; do case $x in KIND=*) kind=${x#KIND=};; esac; done
  if grep -q "^PILOTRUN $name OK" "$E/runs.log"; then :
  elif grep -q "^PILOTRUN $name NOTE" "$E/runs.log" && [[ $kind =~ ^(slo|fix)$ ]]; then  # slo: confirm note; fix: aborted step (judged after)
    echo "$(date -Is) $name NOTE accepted (KIND=$kind): $(grep "^PILOTRUN $name NOTE" "$E/runs.log")" | tee -a "$E/block.log"
  else stop "$name not OK (a NOTE is accepted only for KIND=slo and KIND=fix)"; fi
  dmesg_check "$name" || stop "$name: dmesg check"
done <<< "$RUNS"
[ "$OWNED" = root ] || { step "dax0.0 -> root:root 600"; dax_owner root; }
step "PT pretouch check (end)"
bash $X/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-end.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (end)"
step "BLOCK DONE"
