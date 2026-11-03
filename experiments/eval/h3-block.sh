#!/bin/bash
# H3 block on N VMs (evaluation-pipeline rev 3 §2.3, §6.1; user H3 design 2026-10-20, second revision): for one
# workload (vector DB or RecSys) and one topology N (4 or 8; N = 2 points come from the 2-VM run sets), per system in
# SYSTEMS one server lifetime with ONE aggregate SLO search (HSLO): the offered TOTAL read-op rate is split evenly over
# the serving VMs, same SLO, ramp, confirm and overload rules as the 2-VM run sets, result = aggregate max under the
# SLO; per-step Popcorn counters of every VM are recorded (stats snapshots) for the fault figure at the result.
# CDF=1 adds one Popcorn lifetime at this block's Popcorn max-under-SLO rate RT (its max_offered_x_pass) with the
# kprobe hist (h3-cdf.sh), both workloads: [RecSys: the usual 1 q/s warm-up] -> part settle (CDF_S at RT) -> h3 gate ->
# hist clear -> part cdf (CDF_S at RT) -> hist dump while the servers are up -> stop (vector DB: run.sh part hooks).
# Called by experiments/eval/runset-h3-{vdb,rs}.sh (never by hand in a real run).
# usage: h3-block.sh <evidence dir (exists; empty except sequence*)>
# env (all workloads): H3_WL (vdb | recsys), H3_N (2..8, divides H3_TOTAL_VCPU), H3_TOTAL_VCPU (32), SYSTEMS ("hw pop"
#   in a shuffled order seeded by the owner), EVAL_RUN (k), SEED (loadgen seed of the SLO searches), REGION, C8 K8 GT8
#   RECV_MODE POP_BUNDLE_SHA (Popcorn N-node bundle, POP_IPS = the N guests), PRETOUCH_DIR (VM8-v* / ENV-pretouch-v*
#   evidence of the current QEMU lifetimes, pretouch-check-n.sh), MEASURE_ENV_DIR MEASURE_PART_DIR (h3-gate.sh),
#   EXPECT_DAX_UUID, CDF (0 | 1), CDF_S (window, s)
#   De Stijl v2 (SYSTEMS with ds; same keys and rules as h2n-block.sh): DS_C DS_BUNDLE_SHA DS_K DS_GT [DS_REGION]
#   [H3_DS_T_US]; pop and ds never share a block (different guest kernels); ds cycle = p-destijl-shm.sh precheck / load
#   (protocol=destijl, init_state=shared, recv_mode RECV_MODE: poll | sleep) / chown / preload / enable / status /
#   teardown; servers get ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=<T> (default 0 = synchronous). Checks per ds lifetime:
#   vector DB opcoh_check.py destijl on all N nodes (OPCOH_NODES = N; FAIL = NOTE unless H3_OPCOH_STRICT=1), both
#   workloads recv_check.py --name <lifetime> after the teardown (E/recv-check-<name>.txt; FAIL stops the block);
#   RecSys ds with recv_mode=sleep adds --proc-sysfs /sys/kernel/cxl_shm (per-step receive counters for recv_check).
# vdb: VPLAIN, PLAIN_BUILD, LOADGEN, X_DATA, X_WRITES (writes file whose targets cover the N VMs), X_NB, X_MAXIDS,
#   X_MAXW, X_MAXD, X_INIT_CAP, U (update share %, mix update=U,search=100-U)
# recsys: VM_PLAIN, PLAIN_BUILD, LOADGEN (with query_spread), D (inputs dir), RATE (samples/s), XT (lifetime bound, s)
# Threads = vCPUs per VM (user 2026-10-20): VCPU = H3_TOTAL_VCPU / N; vector DB --search-threads VCPU-1 + 1 writer on
# every VM; RecSys node 0 --update-threads VCPU (+1 serving thread, as the 2-VM block), nodes 1..N-1 --serve-threads
# VCPU, queries round robin over nodes 1..N-1 (loadgen --opt query_spread=rr).
# Order: lock -> pretouch check (N VMs) -> h3 gate -> guest prechecks + install sha256 vs the Host builds -> dmesg
# baseline -> lifetimes (each: h3 gate, dax owner, [Popcorn: shm load / preload / enable / recv_mode / instr], server
# lifetime, checks, [teardown], dmesg check) -> CDF lifetime (CDF=1) -> pretouch check (end) -> BLOCK DONE.
# Outputs: E/h3-results.tsv (one row per HSLO lifetime), E/<sys>-n<N>/ (vdb: run.sh run dir with part slo/;
# recsys: session dir with warmup/, slo/), E/cdf/ (hist-vm<k>.txt, cdf.csv, cdf-summary.txt, cdf lifetime dir),
# E/block.log, E/rollback.out. Every exit (trap): servers of this block stopped (run dirs / session dirs, then by
# command line), kprobe teardown, cxl_shm teardown of every load without "teardown PASS", /dev/dax0.0 root:root 600
# on every VM, final dmesg check, lock released; "ROLLBACK FAIL" / "CLEANUP FAILED" lines = stop and manual check.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control
EV=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$EV/../.." && pwd)
XV=$TREE/experiments/vectordb XR=$TREE/experiments/recsys XK=$TREE/experiments/rocksdb
HG=$TREE/scripts/host/h3-gate.sh CDFS=$EV/h3-cdf.sh OPC=$TREE/workloads/vectordb/tests/opcoh_check.py
die() { echo "BLOCK STOP: $*"; exit 2; }
# H3_BLOCK_DRY=1 (runset-h3-*.sh --dry only): every check up to the evidence-dir check, then exit 0 before the lock;
# a missing pending artifact (N-target writes file, query_spread loadgen) is reported, not fatal, in a dry start only
DRYB=${H3_BLOCK_DRY:-0}
pending() { if [ "$DRYB" = 1 ]; then echo "BLOCK DRY NOTE: $* (a real run stops here)"; else die "$*"; fi; }
: "${H3_WL:?}" "${H3_N:?}" "${SYSTEMS:?}" "${EVAL_RUN:?}" "${SEED:?}" "${C8:?}" "${K8:?}" "${GT8:?}"
: "${RECV_MODE:?}" "${POP_BUNDLE_SHA:?}" "${PRETOUCH_DIR:?}" "${MEASURE_ENV_DIR:?}" "${MEASURE_PART_DIR:?}"
: "${EXPECT_DAX_UUID:?}" "${CDF:?}" "${CDF_S:?}"
TV=${H3_TOTAL_VCPU:-32} N=$H3_N
[[ $N =~ ^[2-8]$ ]] && [ $((TV % N)) = 0 ] || die "H3_N must be 2..8 and divide H3_TOTAL_VCPU ($TV)"
VCPU=$((TV / N))
[[ $EVAL_RUN =~ ^[1-9]$ ]] && [[ $SEED =~ ^[0-9]+$ ]] || die "bad EVAL_RUN / SEED"
[[ $CDF =~ ^[01]$ ]] && [[ $CDF_S =~ ^[1-9][0-9]*$ ]] || die "bad CDF / CDF_S"
. "$EV/recv-mode.sh"   # run 2 receiver rules (adaptive; POP_RECV_MODE, POP_ADAPT_KO, RECV_IPOLL as h2n-block.sh)
[[ $RECV_MODE =~ ^(poll|idle|sleep|adaptive)$ ]] || die "bad RECV_MODE"
PRM=${POP_RECV_MODE:-$RECV_MODE} IPOLL=${RECV_IPOLL:-} POPSV=- DSRX= DSFP=0
[[ $IPOLL =~ ^[01]?$ ]] || die "bad RECV_IPOLL ($IPOLL: 0 | 1)"
export H3_CDF_PFN_MOD=${H3_CDF_PFN_MOD:-1}   # kprobe hist page sampling (h3-cdf.sh; 1 = off; runset-h3-rs.sh passes 16)
bash "$CDFS" filter > /dev/null || die "bad H3_CDF_PFN_MOD (power of two, 1 = off)"
HASDS=0
for s in $SYSTEMS; do case $s in hw|pop) ;; ds) HASDS=1;; mg) die "Megalon in H3 needs Megalon builds with LOGICAL_NODE_NUM = $N (RUN-H3.md, 'Megalon')";; *) die "bad system $s";; esac; done
[ "$CDF" = 0 ] || [[ " $SYSTEMS " == *" pop "* ]] || die "CDF=1 needs pop in SYSTEMS (the rate is Popcorn's max under the SLO)"
# De Stijl v2 (ds): its own guest kernel, bundle, region and T (as h2n-block.sh)
KEXP=$K8 DST=0
if [ $HASDS = 1 ]; then
  [[ " $SYSTEMS " != *" pop "* ]] || die "pop and ds need different guest kernels: run them in separate blocks"
  : "${DS_C:?}" "${DS_BUNDLE_SHA:?}" "${DS_K:?}" "${DS_GT:?}"
  [[ $DS_K == *-ds-destijl-* ]] || die "DS_K=$DS_K is not a De Stijl release (-ds-destijl-<n>)"
  why=$(recv_rules ds "$RECV_MODE" "$DS_C" "$N") || die "De Stijl receiver: $why"
  DST=${H3_DS_T_US:-0}
  [[ $DST =~ ^(0|[1-9][0-9]*)$ ]] || die "bad H3_DS_T_US ($DST: integer us, 0 = synchronous)"
  REGION=${DS_REGION:-$TREE/config/cxl_region-destijl.yaml}   # replaces REGION for the whole block (app offset)
  KEXP=$DS_K
  [ -f "$REGION" ] && [ -f "$DS_C/p-destijl-shm.sh" ] && [ "$(sha256sum < "$DS_C/packet.sha256" | cut -c1-64)" = "$DS_BUNDLE_SHA" ] \
    && (cd "$DS_C" && sha256sum -c --quiet packet.sha256) || die "REGION ($REGION) or the De Stijl bundle ($DS_C) does not verify"
else
: "${REGION:?}"
[ -f "$REGION" ] && [ "$(sha256sum < "$C8/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] \
  && (cd "$C8" && sha256sum -c --quiet packet.sha256) || die "REGION or the Popcorn bundle ($C8) does not verify"
fi
if [[ " $SYSTEMS " == *" pop "* ]]; then
  why=$(recv_rules pop "$PRM" "$C8" "$N") || die "Popcorn receiver: $why"
  [ "$PRM" != adaptive ] && { [ "$PRM" != sleep ] || [ -z "${POP_ADAPT_KO:-}" ]; } || POPSV=$(recv_pop_srcversion)   # run 2 sleep 20/50: same module
fi
IPS=() DOMS=()
for k in $(seq 0 $((N - 1))); do IPS+=(192.168.122.$((100 + k))); DOMS+=(cxl_vm$k); done
export NODES="${IPS[*]}" VM_DOMAINS="${DOMS[*]}" POP_IPS="${IPS[*]}" EXPECT_RUNNING="${DOMS[*]}"
export MEASURE_ENV_DIR MEASURE_PART_DIR H1_MEASURE_RUN=1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
case $H3_WL in
  vdb)
    : "${VPLAIN:?}" "${PLAIN_BUILD:?}" "${LOADGEN:?}" "${X_DATA:?}" "${X_WRITES:?}" "${X_NB:?}" "${X_MAXIDS:?}" "${X_MAXW:?}" "${X_MAXD:?}" "${X_INIT_CAP:?}" "${U:?}"
    case $U in 5|50|90) ;; *) die "U must be 5, 50 or 90 (H1 mixes)";; esac
    V=$VPLAIN HOSTSRV=$PLAIN_BUILD/bin/vdb-server PAT='[/]bin/vdb-server( |$)'
    INIT=/home/comsys/vdb/init/seg32c32m-a27m NA=26990000 HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1
    SA="--nodes $N --segments 32 --M 16 --efc 128 --ef 32 --max-writes $X_MAXW --max-ids $X_MAXIDS --max-deletes $X_MAXD
 --search-threads $((VCPU - 1)) --wait-timeout-ms 60000 --start-timeout-ms 5400000 --init-capacity $X_INIT_CAP"
    SA=$(echo $SA)
    # targets of the writes file must cover exactly the N VMs (one writer per VM receives updates)
    python3 -I -B - "$X_WRITES" "$N" <<'PY' || pending "writes file $X_WRITES does not target exactly $N VMs (generate it: RUN-H3.md)"
import sys, numpy as np
w = np.memmap(sys.argv[1], dtype=np.dtype([("op", "u1"), ("target", "u1"), ("p", "u1", 22)]), mode="r")
t = np.unique(w["target"][: min(len(w), 2_000_000)])
sys.exit(0 if list(t) == list(range(int(sys.argv[2]))) else 1)
PY
    INSTALL="${V#/home/comsys/}/bin/vdb-server $HOSTSRV
${V#/home/comsys/}/bin/vdb-node.sh $TREE/scripts/guest/vdb-node.sh
${V#/home/comsys/}/cfg/cxl_region.yaml $REGION";;
  recsys)
    : "${VM_PLAIN:?}" "${PLAIN_BUILD:?}" "${LOADGEN:?}" "${D:?}" "${RATE:?}" "${XT:?}"
    [[ $RATE =~ ^[1-9][0-9]*$ ]] && [ $((RATE % 50)) = 0 ] || die "RATE must be a multiple of 50 samples/s"
    [ "$N" -ge 3 ] || [ -n "${H3_ALLOW_N2:-}" ] || die "RecSys H3 N = 2 comes from rs-main (H3_N2_SOURCE=2vm)"
    V=$VM_PLAIN HOSTSRV=$PLAIN_BUILD/bin/recsys-server PAT='[/]bin/recsys-server( |$)'
    UPD_FILE=updates-day23-0-2M.smp QRY_FILE=queries-day23-89137318-1M.smp
    SA="--nodes $N --row-div 1 --serve-threads $VCPU --update-threads 1 --load-threads 8 --start-timeout-ms $((XT * 500))
 --update-mode stream --verify-rows 1 --proc-sysfs /sys/kernel/swmc/instr --proc-sysfs /sys/kernel/cxl_shm/instr
 --proc-sysfs /sys/kernel/swmc/page_coherence --proc-kthread cxl_recv"
    SA=$(echo $SA) N0X="--update-threads $VCPU --serve-threads 1"
    for f in $UPD_FILE $QRY_FILE dist_quantile.txt; do
      h=$(sed -n "s/^\([0-9a-f]\{64\}\)  $f\$/\1/p" "$D/MANIFEST.txt"); [ -n "$h" ] || die "$f not in $D/MANIFEST.txt"
    done
    grep -q 'query_spread' "$LOADGEN" 2>/dev/null || pending "loadgen $LOADGEN has no query_spread option (recsys-loadgen build of branch eval-h3: RUN-H3.md)"
    LGC=(--opt samples=$D/$UPD_FILE --opt queries=$D/$QRY_FILE --opt quantiles=$D/dist_quantile.txt
         --fixed update=$RATE --mix query=1 --x-stream query --opt query_spread=rr)
    INSTALL="${V#/home/comsys/}/bin/recsys-server $HOSTSRV
${V#/home/comsys/}/bin/recsys-node.sh $TREE/scripts/guest/recsys-node.sh
${V#/home/comsys/}/cfg/cxl_region.yaml $REGION";;
  *) die "H3_WL must be vdb or recsys";;
esac
[ -x "$HOSTSRV" ] || die "missing $HOSTSRV"
[ -x "$LOADGEN" ] || pending "missing $LOADGEN"
# shellcheck disable=SC2086
APP=$("$HOSTSRV" $SA $([ $H3_WL = recsys ] && echo "--publish-ms 0") --print-app-bytes) || die "print-app-bytes ($HOSTSRV, --nodes $N)"
RING=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
[ $((APP + RING)) -lt 268435456 ] || die "app HWcc $APP B + ring $RING B exceed the 256 MiB HWcc budget at N = $N"
OWNER=eval-h3-$H3_WL-n$N-run$EVAL_RUN
ORDER=$(python3 -I -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "h3-$H3_WL-n$N" $SYSTEMS)
echo "BLOCK PLAN: $H3_WL N=$N vcpu/VM=$VCPU nodes=[${IPS[*]}] order=[$ORDER] cdf=$CDF app=$APP ring=$RING server_args=[$SA]"
[ $HASDS = 0 ] || echo "BLOCK PLAN: destijl release=$DS_K bundle=$DS_C guest_tools=$DS_GT region=$REGION T=$DST us recv_mode=$RECV_MODE (node env CXL_SYSTEM=ds CXL_DESTIJL_T_US=$DST)"
if [ "$DRYB" = 1 ]; then echo "BLOCK DRY STOP: evidence-dir check reached ($E; dry: no lock, no VM contact)"; exit 0; fi
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || die "$E missing or not empty"
# ---------------------------------------------------------------------------------------------------- real block
bash "$HG" lock "$OWNER" || die "lock"
CDFUP=0 DMESG_DONE=0
log() { echo "$(date -Is) $*" | tee -a "$E/block.log"; }
stop() { log "BLOCK STOP $*"; exit 1; }
servers_gone() { local ip; for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip "pgrep -c -f -- '$PAT'" < /dev/null)" = 0 ] || return 1; done; }
dax_unused() {  # every VM: sudo -n fuser prints nothing and rc 1 (anything else = in use; fail closed)
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip 'f=$(sudo -n fuser /dev/dax0.0 2>&1); r=$?; echo "dax_users=[$f] rc=$r"' < /dev/null 2>&1)
    echo "$(date -Is) $1 $ip $out" >> "$E/dax-users.txt"
    [ "$out" = "dax_users=[] rc=1" ] || return 1
  done
}
dax_owner() {  # comsys | root, every VM, stat checked
  local ip out want
  for ip in "${IPS[@]}"; do
    if [ "$1" = comsys ]; then out=$($SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null 2>&1); want="comsys:root 600"
    else out=$($SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; stat -c "%U:%G %a" /dev/dax0.0' < /dev/null 2>&1); want="root:root 600"; fi
    echo "$(date -Is) $ip dax0.0 -> $out" >> "$E/dax-owner.txt"
    [ "$out" = "$want" ] || return 1
  done
}
dmesg_count() { local c; c=$($SSH comsys@${IPS[$1]} 'dmesg | wc -l' < /dev/null 2>/dev/null) || return 1; [[ $c =~ ^[0-9]+$ ]] || return 1; echo "$c"; }
DMESG_BAD='BUG:|Oops|WARNING:|Call Trace|general protection|segfault|[Ee]rror|ERROR|soft lockup|hung_task'
dmesg_check() {  # <tag>: 1 on a new bad line, an ssh failure or a wrap (experiments/rocksdb/v1-block.sh rule)
  local i n c bad=0
  for i in "${!IPS[@]}"; do
    n=$(cat "$E/dmesg-base-vm$i.txt" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || { log "dmesg vm$i ($1): stored baseline '$n'"; bad=1; continue; }
    c=$(dmesg_count $i) || { log "dmesg vm$i ($1): ssh/count failed"; bad=1; continue; }
    [ "$c" -ge "$n" ] || { log "dmesg vm$i ($1): ring buffer wrapped ($n -> $c)"; bad=1; continue; }
    $SSH comsys@${IPS[$i]} "dmesg | tail -n +$((n + 1))" < /dev/null > "$E/dmesg-new-$1-vm$i.txt" 2>&1 || { bad=1; continue; }
    grep -qE "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" && { log "dmesg vm$i ($1): $(grep -E "$DMESG_BAD" "$E/dmesg-new-$1-vm$i.txt" | head -3)"; bad=1; }
  done
  return $bad
}
shm_teardown_left() {  # every cxl_shm load of this block without "teardown PASS"
  local r
  for r in "$E"/shm-*/; do
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    dax_unused cleanup || { echo "CLEANUP FAILED: $r: /dev/dax0.0 in use, teardown not attempted (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"; continue; }
    env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1 \
      || { grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
           && env K=$K8 GT=$GT8 C=$C8 R=$r bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; }
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"
  done
  for r in "$E"/dsshm-*/; do  # De Stijl loads (ds lifetimes): same rule, p-destijl-shm.sh teardown
    r=${r%/}; [ -d "$r" ] && [ -f "$r/load-vm0.txt" ] || continue
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && continue
    dax_unused cleanup || { echo "CLEANUP FAILED: $r: /dev/dax0.0 in use, teardown not attempted (manual: p-destijl-shm.sh teardown)" | tee -a "$E/cleanup.out"; continue; }
    env K=$DS_K GT=$DS_GT C=$DS_C R=$r DS_IPS="${IPS[*]}" bash $DS_C/p-destijl-shm.sh teardown >> "$E/cleanup.out" 2>&1
    grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: p-destijl-shm.sh teardown)" | tee -a "$E/cleanup.out"
  done
}
finish() {
  trap '' INT TERM HUP
  set +eu
  pkill -TERM -P $$ 2>/dev/null; sleep 1
  local S ip out
  for S in "$E"/*/session.env; do  # RecSys sessions still running
    S=$(dirname "$S"); [ -e "$S/stopped" ] || bash $XR/session.sh stop "$S" >> "$E/rollback.out" 2>&1
  done
  for ip in "${IPS[@]}"; do  # our servers by command line (vdb run.sh stops its own nodes in its traps)
    out=$($SSH comsys@$ip "pkill -u comsys -f -- '$PAT'; for i in \$(seq 15); do pgrep -u comsys -f -- '$PAT' > /dev/null || break; sleep 1; done
      pkill -9 -u comsys -f -- '$PAT'; sleep 1; echo procs=\$(pgrep -c -u comsys -f -- '$PAT')" < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "procs=0" || echo "ROLLBACK FAIL: $ip server process left (see rollback.out)" | tee -a "$E/rollback.out"
  done
  [ $CDFUP = 0 ] || bash $CDFS teardown "$E/cdf" >> "$E/rollback.out" 2>&1 || echo "ROLLBACK FAIL: kprobe teardown (see $E/cdf/cdf-teardown.txt)" | tee -a "$E/rollback.out"
  shm_teardown_left
  dax_unused rollback || echo "ROLLBACK FAIL: /dev/dax0.0 in use on a VM (see dax-users.txt)" | tee -a "$E/rollback.out"
  dax_owner root || echo "ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see dax-owner.txt)" | tee -a "$E/rollback.out"
  [ $DMESG_DONE = 0 ] || { dmesg_check final || echo "$(date -Is) final dmesg check: see block.log" >> "$E/rollback.out"; }
  bash "$HG" unlock "$OWNER"
}
trap finish EXIT
trap 'log "BLOCK STOP signal"; exit 130' INT TERM HUP
gate() { bash "$HG" check "$E/gate-$1.txt" > /dev/null || stop "h3 gate ($1; see gate-$1.txt)"; }
{ echo "# H3 block $OWNER: $H3_WL N=$N vcpu/VM=$VCPU order [$ORDER] cdf=$CDF cdf_s=$CDF_S seed=$SEED"
  echo "cdf_pfn_mod=$H3_CDF_PFN_MOD cdf_filter=[$(bash "$CDFS" filter)]"
  echo "nodes=${IPS[*]} domains=${DOMS[*]} server_args=[$SA] app_hwcc=$APP ring=$RING region_sha256=$(sha256sum < "$REGION" | cut -c1-64)"
  echo "host_server=$HOSTSRV sha256=$(sha256sum < "$HOSTSRV" | cut -c1-64) loadgen=$LOADGEN sha256=$(sha256sum < "$LOADGEN" | cut -c1-64)"
  [ $H3_WL = vdb ] && echo "writes=$X_WRITES sha256=$(sha256sum < "$X_WRITES" | cut -c1-64) U=$U"
  [ $H3_WL = recsys ] && echo "rate=$RATE samples/s n0x=[$N0X] lgc=[${LGC[*]}]"
  [ $HASDS = 0 ] || echo "destijl: bundle=$DS_C bundle_sha=$DS_BUNDLE_SHA release=$DS_K guest_tools=$DS_GT region=$REGION t_us=$DST recv_mode=$RECV_MODE"
  for d in "${DOMS[@]}"; do x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null); echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -c1-64) bytes=${#x}"; done
} > "$E/h3-params.txt"
log "== PT pretouch check (start, $N VMs)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-start.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (start)"
log "== H0 h3 gate"; gate H0
log "== guest prechecks (install sha256 = Host builds; guests 2..N-1 inherit vm0's files at the topology freeze)"
SUMS=; [ $H3_WL = vdb ] && SUMS=$(sha256sum < "$HOST_IMAGE/SHA256SUMS" | cut -c1-64)
for i in "${!IPS[@]}"; do
  if [ $H3_WL = vdb ]; then
    $SSH comsys@${IPS[$i]} "EXPECT_K=$KEXP EXPECT_DAX_UUID=$EXPECT_DAX_UUID INIT_DIR=$INIT INIT_SUMS=$SUMS INIT_CHECK=$([ $i = 0 ] && echo 1 || echo 0) INSTALL_DIRS='$(echo "$INSTALL" | awk '{print $1}' | tr '\n' ' ')' bash -s" \
      < $XV/m4-precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  else
    $SSH comsys@${IPS[$i]} "EXPECT_K=$KEXP MEM_MIN=8EXPECT_DAX_UUID='$EXPECT_DAX_UUID' INSTALL_FILES='$(echo "$INSTALL" | awk '{print $1}' | tr '\n' ' ')' bash -s" \
      < $XR/precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  fi
  grep -q "^PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i: $(grep -m1 'PRECHECK FAIL' "$E/precheck-vm$i.txt")"
  while read -r g h; do
    grep -q "^$(sha256sum < "$h" | cut -c1-64)  /home/comsys/$g\$" "$E/precheck-vm$i.txt" || stop "vm$i /home/comsys/$g != $h (install needed on the guest)"
  done <<< "$INSTALL"
  [ "$($SSH comsys@${IPS[$i]} nproc < /dev/null)" = "$VCPU" ] || stop "vm$i nproc != $VCPU"
done
for i in "${!IPS[@]}"; do c=$(dmesg_count $i) || stop "dmesg baseline vm$i"; echo "$c" > "$E/dmesg-base-vm$i.txt"; done
DMESG_DONE=1
if [ $H3_WL = vdb ]; then printf '# name\tsystem\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\n' > "$E/h3-results.tsv"
else printf '# name\tsystem\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\tstreamcheck\n' > "$E/h3-results.tsv"; fi
echo "$ORDER" > "$E/order.txt"
OWNED=root
preload0() {  # <name>: node 0 preloads the initial data through a plain mapping (cxl_shm loaded, coherence not enabled)
  local t
  t=$(date +%s)
  if [ $H3_WL = vdb ]; then
    $SSH comsys@${IPS[0]} "mkdir -p $V/runs && echo \$\$ > $V/runs/preload-$1.pid && exec timeout -k 30 1200 env CXL_REGION_CONFIG=$V/cfg/cxl_region.yaml $V/bin/vdb-server --node 0 --preload-only --init-dir $INIT $SA" \
      < /dev/null > "$E/preload-$1.log" 2>&1
  else
    $SSH comsys@${IPS[0]} "mkdir -p $V/runs/preload-$1 && CXL_REGION_CONFIG=$V/cfg/cxl_region.yaml setsid -w sh -c 'echo \$\$ > $V/runs/preload-$1/node0.pid; exec timeout $XT $V/bin/recsys-server --node 0 --preload-only $SA --publish-ms 0'" \
      < /dev/null > "$E/preload-$1.log" 2>&1
  fi
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$1.log"
  { grep -q "PRELOAD DONE" "$E/preload-$1.log" && servers_gone; } || stop "preload ($1)"
}
# ---- Popcorn cxl_shm cycle (P-popcorn-deploy §6a, init_state=shared) on the N guests -------------------------------
pop_up() {  # <name>
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$1 INIT_STATE=shared)
  [ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root before Popcorn"; OWNED=root; }
  servers_gone || stop "a server runs before the Popcorn load"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck >> "$E/block.log" 2>&1 || stop "shm precheck"
  dax_unused pre-load-$1 || stop "/dev/dax0.0 in use before the cxl_shm load"
  local ph ip m i t
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph >> "$E/block.log" 2>&1 || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "test -f $V/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $V/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  preload0 "$1"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable >> "$E/block.log" 2>&1 || stop "enable gate"
  recv_apply pop "$1" "$PRM"
  POPNAME=$1
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1 || stop "status pre"
}
pop_down() {
  recv_post "$POPNAME"
  env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1
  servers_gone || stop "servers left (Popcorn teardown not attempted)"
  dax_unused pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm teardown"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/block.log" 2>&1 || stop "shm teardown"
}
# ---- De Stijl v2 cxl_shm cycle (protocol=destijl, init_state=shared; as h2n-block.sh ds_up / ds_down) ---------------
ds_up() {  # <name>
  DSP=(K=$DS_K GT=$DS_GT C=$DS_C R=$E/dsshm-$1 INIT_STATE=shared "LOAD_EXTRA=recv_mode=$RECV_MODE")
  [ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root before De Stijl"; OWNED=root; }
  servers_gone || stop "a server runs before the De Stijl load"
  env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh precheck >> "$E/block.log" 2>&1 || stop "ds shm precheck"
  dax_unused pre-load-$1 || stop "/dev/dax0.0 in use before the cxl_shm (destijl) load"
  local ph ip m p i
  for ph in load chown; do env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh $ph >> "$E/block.log" 2>&1 || stop "ds shm $ph"; done
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "test -f $V/cfg/cxl_region.yaml && test -f $DS_GT/cxl_region.yaml && sha256sum $V/cfg/cxl_region.yaml $DS_GT/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip (De Stijl tools)"
  done
  preload0 "$1"
  env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh enable >> "$E/block.log" 2>&1 || stop "ds enable gate"
  recv_apply ds "$1" "$RECV_MODE"
  DSNAME=$1
  env "${DSP[@]}" STATUS_TAG=pre bash $DS_C/p-destijl-shm.sh status >> "$E/block.log" 2>&1 || stop "ds status pre"
}
ds_down() {
  recv_post "$DSNAME"
  env "${DSP[@]}" STATUS_TAG=post bash $DS_C/p-destijl-shm.sh status >> "$E/block.log" 2>&1
  servers_gone || stop "servers left (De Stijl teardown not attempted)"
  dax_unused pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm (destijl) teardown"
  env "${DSP[@]}" bash $DS_C/p-destijl-shm.sh teardown >> "$E/block.log" 2>&1 || stop "ds shm teardown"
}
sys_up() {  # <sys> <name>: dax owner + Popcorn / De Stijl cycle
  case $1 in
    hw) [ $OWNED = comsys ] || { dax_owner comsys || stop "dax0.0 -> comsys"; OWNED=comsys; };;
    pop) pop_up "$2";;
    ds) ds_up "$2";;
  esac
}
sys_down() {  # <sys>: Popcorn / De Stijl teardown after the lifetime (nothing for hw)
  case $1 in pop) pop_down;; ds) ds_down;; esac
}
ds_recv() {  # <name>: recv_check.py on this ds lifetime after its teardown (as h2n-block.sh); FAIL stops the block
  python3 -I -B $EV/recv_check.py "$E" --mode "$RECV_MODE" --name "$1" --out "$E/recv-check-$1.txt" > /dev/null 2>&1
  local r; r=$(tail -n 1 "$E/recv-check-$1.txt" 2>/dev/null)
  log "$1: recv check: ${r:-no recv-check-$1.txt}"
  [[ $r == "RECVCHECK PASS"* ]] || stop "$1: recv check FAIL (see recv-check-$1.txt)"
}
# SYSTEM label and the extra server arguments / node env per system (pop and ds start from the preloaded data)
sys_label() { case $1 in pop) echo Popcorn-$PRM;; ds) echo DeStijl-$RECV_MODE-T$DST;; *) echo all-HWcc;; esac; }
sys_pre() { case $1 in pop|ds) echo "$2";; esac; }
sys_env() { [ $1 != ds ] || echo "ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=$DST"; }
# loadgen arguments of the CDF settle and cdf parts (both workloads): one CDF_S window at the CDF rate
cdf_args() { echo "--mode fixed --rates $1 --warmup-s 10 --step-warmup-s 0 --step-measure-s $CDF_S --drain-s 10"; }
# ---- vector DB lifetime: run.sh (N nodes, PARTS) with the H1 SLO part arguments --------------------------------------
vdb_life() {  # <sys> <name> <kind: slo | cdf> [<cdf offered rate>]
  local s=$1 name=$2 kind=$3 R=$E/$2 k L RP note parts=slo
  [ $kind = slo ] || parts="settle cdf"
  local LG=(--opt data=$X_DATA --opt writes=$X_WRITES --opt k=10 --mix "update=$U,search=$((100 - U))" --slo search:99:100 --x-stream search --raw)
  local RE=(SYSTEM=$(sys_label $s) V=$V HOST_SERVER=$HOSTSRV LOADGEN=$LOADGEN INIT=$INIT
    READY_TIMEOUT=5400 RUN_KIND=measurement TRACE=0 STATS_OP=10 "NODE_ENV=$(sys_env $s)" "PARTS=$parts" H1_MEASURE_RUN=1 MEASURE_PART_DIR=$MEASURE_PART_DIR
    "SERVER_ARGS=$SA$(sys_pre $s ' --preloaded')"
    "PART_ARGS_slo=--mode slo --start 10 --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3 --step-measure-s 15 --confirm-s 30 --confirm-reps 3"
    PART_SEED_slo=$SEED
    "PART_GATE_CMD=bash $HG check")   # between parts: the N-VM gate (run.sh part hook), never the 2-VM h1-gate.sh
  # CDF lifetime (verifier M1): part settle (CDF_S at the CDF rate) -> gate -> hist clear (PART_PRE_CMD) -> part cdf
  # (CDF_S at the same rate) -> hist dump (PART_POST_CMD) while the servers are still up
  [ $kind = slo ] || RE+=("PART_ARGS_settle=$(cdf_args "$4")" PART_SEED_settle=$((SEED + 3)) "PART_ARGS_cdf=$(cdf_args "$4")"
    PART_SEED_cdf=$((SEED + 2)) "PART_PRE_CMD=bash $CDFS part-pre $E/cdf" "PART_POST_CMD=bash $CDFS part-post $E/cdf")
  gate $name; sys_up $s $name
  servers_gone || stop "a vdb-server runs before $name"
  log "$name: run.sh parts [$parts] ($s, N=$N)"
  env "${RE[@]}" bash $XV/run.sh "$name" "$E" -- "${LG[@]}" > "$E/$name.out" 2>&1; local rc=$?
  log "$name: run.sh rc $rc: $(tail -n 1 "$E/$name.out")"
  [ $kind = slo ] || { grep -q "CDF DUMP PASS" "$R/part-hooks.txt" 2>/dev/null || stop "$name: no CDF DUMP PASS (see $R/part-hooks.txt)"; }
  sys_down $s
  servers_gone || stop "servers left after $name"
  [ -d "$R" ] || stop "$name: no run dir"
  for k in "${!IPS[@]}"; do  # clean stop, no bad record, op coherence on and error-free (m4-run.sh rules, N nodes)
    L=$R/node$k.log
    { grep -q "vdb-server: stopping" $L && [ "$(grep -c '^bad_records=0$' $L)" = 1 ]; } || stop "$name node$k: no clean stop / bad_records"
    grep -q "^vdb-server: op coherence on," $L || stop "$name node$k: op coherence not on"
    [ $s != pop ] || grep -qE "^vdb-server: op coherence on, popcorn source swmc_acct[ ,]" $L || stop "$name node$k: popcorn source != swmc_acct"
    [ $s != ds ] || [ "$DST" = 0 ] || grep -q "^vdb-server: de stijl staleness T=$DST us on " $L || stop "$name node$k: staleness T=$DST not applied"
    { grep -qx "opcoh.read_errors=0" $L && grep -qx "opcoh.register_errors=0" $L; } || stop "$name node$k: opcoh errors"
  done
  for RP in $(for p in $parts; do echo $R/$p; done); do
  note=""
  [ -s $RP/loadgen/summary.json ] || stop "$name: no loadgen output"
  grep -q '"reason":"stream [a-z]* exhausted' $RP/loadgen/steps.jsonl && stop "$name: writes file exhausted"
  { grep -qx "ok_without_coh=0" $RP/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $RP/loadgen/vectordb.txt &&
    grep -qx "bad_coh_version=0" $RP/loadgen/vectordb.txt; } || stop "$name: responses without an op coherence block"
  python3 $XV/opsplit.py $RP > $RP/opsplit.log 2>&1 || stop "$name: opsplit.py (see $RP/opsplit.log)"
  if [ $s = ds ]; then  # opcoh_check.py destijl on all N nodes (OPCOH_NODES, as h2n-block.sh); FAIL stops only with H3_OPCOH_STRICT=1
    OPCOH_NODES=$N OPCOH_PARTS=$RP python3 $OPC $RP destijl > $RP/opcoh-check.txt 2>&1
    oc=$(grep -m1 -oE '^OPCOH_CHECK (PASS|FAIL)' $RP/opcoh-check.txt | cut -d' ' -f2); oc=${oc:-ERROR}
    if [ "$oc" != PASS ]; then
      [ "${H3_OPCOH_STRICT:-0}" = 1 ] && stop "$name: opcoh_check destijl $oc (see $RP/opcoh-check.txt)"
      log "$name NOTE: opcoh_check destijl $oc on $N nodes (H3_OPCOH_STRICT=0: recorded; see $RP/opcoh-check.txt)"
    fi
  else
    # hw / pop keep the earlier H3 behaviour (their per-node opcoh errors are checked above); opcoh_check.py now takes
    # OPCOH_NODES = N (h2n-block.sh), switching hw / pop here is a separate change of the H3 checks
    echo "opcoh_check.py not run for $s in H3 (ds lifetimes only); per-node opcoh errors checked above" > $RP/opcoh-check.txt
  fi
  python3 $XV/urate_check.py $RP --writers 1 > $RP/urate-check.txt 2>&1 || true
  python3 $XV/e1_check.py --writes $X_WRITES --na $NA --nb $X_NB --searches $RP/loadgen/searches.bin --out $RP/e1 --sample 500 > /dev/null \
    || stop "$name: E1 violation (see $RP/e1.e1.txt)"
  grep -q 'workload_finish":"ok' $RP/loadgen/summary.json || stop "$name: loadgen workload finish"
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' $RP/loadgen/summary.json 2>/dev/null)
  if [ -n "$note" ]; then
    [ $kind = slo ] && [ "$note" = "confirm failed at three rates; the knee is noisy (longer --confirm-s?)" ] || stop "$name: loadgen note: $note"
    log "$name NOTE: $note"
  elif [ $rc != 0 ]; then stop "$name: run.sh rc $rc"; fi
  done
  [ $kind = slo ] && python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); f=lambda v: "" if v is None else str(v)
print("\t".join(sys.argv[2:6] + [f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")), s.get("note",""), sys.argv[6]]))' \
    $RP/loadgen/summary.json "$name" $s $N $VCPU "$name/slo" >> "$E/h3-results.tsv"
  [ $s != ds ] || ds_recv $name
  dmesg_check $name || stop "$name: dmesg check"
}
# ---- RecSys lifetime: session.sh (N nodes) ---------------------------------------------------------------------------
rs_measure() {  # <session> <name> <loadgen args...>
  local S=$1 n=$2; shift 2
  [ "$n" = cdf ] || gate "$(basename "$S")-$n"   # cdf: gated by the caller before the hist clear
  env LOADGEN=$LOADGEN PROFILE=main RUN_KIND=measurement STATS_OP=10 IDLE_WAIT_S=2400 H1_MEASURE_RUN=1 MEASURE_PART_DIR=$MEASURE_PART_DIR \
    SLO_MS=100 "SLO_RULE=DeepRecSys ISCA'20: query p95 <= 100 ms" bash $XR/session.sh measure "$S" "$n" -- "$@" > "$S.$n.out" 2>&1
  local rc=$?
  [ $rc = 5 ] && stop "$(basename "$S")/$n: $(grep -m1 '^STATS MISSING' "$S.$n.out")"
  return $rc
}
rs_life() {  # <sys> <name> <slo | cdf> [<cdf query rate>]
  local s=$1 name=$2 kind=$3 S=$E/$2 rc note sc SE
  gate $name; sys_up $s $name
  servers_gone || stop "a recsys-server runs before $name"
  # ds with recv_mode=sleep: recv_check.py needs the per-step sleep_wakeups / tick_kicks (/sys/kernel/cxl_shm; the
  # vector DB server snapshots it always, RecSys only with this --proc-sysfs, as main-block.sh STREAM_PROC_CXL_SHM=1)
  local SAX=$SA; [ $s != ds ] || [ "$RECV_MODE" != sleep ] || SAX="$SA --proc-sysfs /sys/kernel/cxl_shm"
  # adaptive (run 2): per-step adaptive counters (/sys/kernel/cxl_shm) and idle-poller CPU (kthreads cxl_ipoll/<cpu>)
  local lm=-; case $s in pop) lm=$PRM;; ds) lm=$RECV_MODE;; esac
  [ "$lm" != adaptive ] || SAX="$SA --proc-sysfs /sys/kernel/cxl_shm --proc-kthread cxl_ipoll"
  SE=(SYSTEM=$(sys_label $s) V=$V HOST_SERVER=$HOSTSRV "SERVER_ARGS=$SAX" T_MS=0
      "NODE_ENV=ENV:XTIMEOUT=$XT$([ $s != ds ] || echo " $(sys_env ds)")" "NODE0_ARGS=$(sys_pre $s '--preloaded ')$N0X" READY_TIMEOUT=$((XT / 2)))
  env "${SE[@]}" bash $XR/session.sh start "$S" > "$S.start.out" 2>&1 || stop "$name session start: $(tail -n 2 "$S.start.out" | tr '\n' ' ')"
  log "$name: $(tail -n 1 "$S.start.out")"
  rs_measure "$S" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 50 --drain-s 10 || stop "$name warm-up rc $?"
  if [ $kind = slo ]; then
    rs_measure "$S" slo "${LGC[@]}" --opt seed=$SEED --seed $SEED --slo query:95:100 --raw --tol 0.02 \
      --mode slo --start 1 --factor 1.5 --precision 0.02 --confirm-precision 0.01 --max-confirm-probes 6 --confirm-step-down 0.05 \
      --max-steps 40 --min-step-queries 100 --ramp-knee 2
    rc=$?
    grep -q 'workload_finish":"ok' "$S/slo/loadgen/summary.json" 2>/dev/null || stop "$name slo: loadgen workload finish (rc $rc)"
    if [ $rc = 1 ]; then
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$S/slo/loadgen/summary.json" 2>/dev/null)
      [ -n "$note" ] || stop "$name slo: loadgen rc 1 without a note"; log "$name NOTE: $note"
    elif [ $rc != 0 ]; then stop "$name slo rc $rc"; fi
    python3 $XR/stream_check.py "$S/slo" > "$S/slo/stream-check.txt" 2>&1
    sc=$(grep -m1 '^STREAMCHECK' "$S/slo/stream-check.txt")
    case "$sc" in "STREAMCHECK PASS"*|"STREAMCHECK NOTE"*) ;; *) stop "$name: ${sc:-stream_check.py failed}";; esac
    python3 $XR/check_breakdown.py "$S/slo" > "$S/slo/breakdown-check.txt" 2>&1
    grep -q "^BREAKDOWN PASS" "$S/slo/breakdown-check.txt" || log "$name NOTE: check_breakdown (node 1 only): $(head -c 300 "$S/slo/breakdown-check.txt")"
    python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); f=lambda v: "" if v is None else str(v)
print("\t".join(sys.argv[2:6] + [f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")), s.get("note",""), sys.argv[6], sys.argv[7]]))' \
      "$S/slo/loadgen/summary.json" "$name" $s $N $VCPU "$name/slo" "$(echo "$sc" | cut -d' ' -f2)" >> "$E/h3-results.tsv"
  else  # CDF lifetime (verifier M1; same structure as the vector DB): settle -> gate -> clear -> cdf -> dump (servers up)
    # shellcheck disable=SC2046
    rs_measure "$S" settle "${LGC[@]}" --opt seed=$((SEED + 3)) --seed $((SEED + 3)) --raw $(cdf_args "$4") || stop "$name settle rc $?"
    gate "$name-cdf"
    bash $CDFS clear "$E/cdf" >> "$E/block.log" 2>&1 || stop "cdf clear"
    # shellcheck disable=SC2046
    rs_measure "$S" cdf "${LGC[@]}" --opt seed=$((SEED + 2)) --seed $((SEED + 2)) --raw $(cdf_args "$4") || stop "$name cdf rc $?"
    bash $CDFS dump "$E/cdf" >> "$E/block.log" 2>&1 || stop "cdf dump"
    python3 $XR/stream_check.py "$S/settle" > "$S/settle/stream-check.txt" 2>&1
    python3 $XR/stream_check.py "$S/cdf" > "$S/cdf/stream-check.txt" 2>&1
  fi
  bash $XR/session.sh stop "$S" > "$S.stop.out" 2>&1 || stop "$name session stop / final checks: $(tail -n 2 "$S.stop.out" | tr '\n' ' ')"
  if [ $s = ds ] && [ "$DST" != 0 ]; then local k
    for k in "${!IPS[@]}"; do grep -q "^recsys-server: de stijl staleness T=$DST us on " "$S/node$k.log" || stop "$name node$k: staleness T=$DST not applied"; done
  fi
  sys_down $s
  servers_gone || stop "servers left after $name"
  [ $s != ds ] || ds_recv $name
  dmesg_check $name || stop "$name: dmesg check"
}
# ---- sequence ----------------------------------------------------------------------------------------------------
for s in $ORDER; do
  log "== HSLO $s n$N"
  if [ $H3_WL = vdb ]; then vdb_life $s $s-n$N slo; else rs_life $s $s-n$N slo; fi
done
if [ "$CDF" = 1 ]; then  # Popcorn lifetime at this block's Popcorn max under the SLO, kprobe hist on every VM
  row=$(awk -F'\t' '!/^#/ && $2 == "pop"' "$E/h3-results.tsv" | tail -n 1)
  RT=$(echo "$row" | cut -f5) CONF=$(echo "$row" | cut -f7)
  if [ "$CONF" != True ] || ! [[ $RT =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    log "CDF NOTE: no confirmed Popcorn result at N=$N ($row): CDF pass skipped"
  else
    mkdir -p "$E/cdf"
    # verifier L2: the CDF rate is the offered rate of the result (loadgen max_offered_x_pass: the vector DB total
    # request rate of the mix, the RecSys query rate), not a rate converted from achieved ops
    echo "cdf rate: Popcorn max_offered_x_pass $RT at N=$N (offered rate of the confirmed result; loadgen --rates units)" | tee "$E/cdf/cdf-rate.txt"
    # verifier M2 (behaviour unchanged): upper bound of distinct I->S pages per VM in the CDF part from the Popcorn
    # SLO lifetime's at_result counters, against the 2^17-entry hist map; H3_CDF_PFN_MOD (default 1 = off) is applied
    # by h3-cdf.sh setup and recorded in cdf-setup.txt
    python3 -I -B $EV/h3_cdf_estimate.py "$E/pop-n$N/slo" --nodes $N --window-s $((CDF_S + 20)) --pfn-mod "${H3_CDF_PFN_MOD:-1}" \
      > "$E/cdf/cdf-estimate.txt" 2>&1 || log "CDF NOTE: estimate failed (see cdf/cdf-estimate.txt)"
    log "cdf estimate: $(tail -n 1 "$E/cdf/cdf-estimate.txt")"
    log "== CDF pop n$N at $RT (pfn_mod ${H3_CDF_PFN_MOD:-1})"
    bash $CDFS setup "$E/cdf" >> "$E/block.log" 2>&1 && CDFUP=1 || { CDFUP=1; stop "cdf setup"; }
    if [ $H3_WL = vdb ]; then vdb_life pop pop-n$N-cdf cdf "$RT"; else rs_life pop pop-n$N-cdf cdf "$RT"; fi
    bash $CDFS teardown "$E/cdf" >> "$E/block.log" 2>&1 || stop "cdf teardown"
    CDFUP=0
    python3 -I -B $XK/h3-page-cdf.py "$E"/cdf/hist-vm*.txt --out "$E/cdf/cdf.csv" > "$E/cdf/cdf-summary.txt" 2>&1 \
      || log "CDF NOTE: $(tail -n 1 "$E/cdf/cdf-summary.txt") (recorded; Dropped > 0 = incomplete CDF)"
    log "cdf: $(head -n 1 "$E/cdf/cdf-summary.txt")"
  fi
fi
[ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root"; OWNED=root; }
log "== PT pretouch check (end)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-end.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (end)"
log "BLOCK DONE $OWNER"
