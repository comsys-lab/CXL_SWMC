#!/bin/bash
# New H2 block (vector DB VM-count scaling; user decisions 2026-10-20 22:3x, state/PROJECT.md; RUN-H2N.md): on N VMs
# (cxl_vm0..N-1 of the VM8 topology, EVERY VM 4 vCPU / 24 GB), the lifetimes of H2N_LIFETIMES in the given order,
# each one server lifetime with ONE aggregate SLO search (HSLO; experiments/eval/h3-block.sh rules): the offered TOTAL
# rate of the mix is split evenly over the N VMs (loadgen draws each search's target uniformly; the update stream's
# targets cover the N VMs, writes file per N), same SLO / ramp / confirm / overload rules as the 2-VM run sets, result =
# aggregate max under the SLO. Per step: stats snapshots of every VM (Popcorn fault counters, Megalon object counters)
# for the fault table at the result. No fixed-load windows, no CDF pass. Generalised from h3-block.sh (vector DB part):
# fixed vCPU per VM (H2N_VCPU, not a total split), the mix per lifetime, Megalon (mg; mgoff = timers off, optional),
# opcoh_check on N nodes, the CXL.mem bandwidth sampler between lock and unlock.
# Called by experiments/eval/runset-h2n.sh (never by hand in a real run).
# usage: h2n-block.sh <evidence dir (exists; empty except sequence*)>
# env: H2N_N (2..8), H2N_VCPU (4), H2N_LIFETIMES ("<sys>:<mix> ..." in execution order; sys hw | pop | mg | mgoff,
#   mix u5 | u50 | u90), EVAL_RUN (k), SEED, REGION, C8 K8 GT8 RECV_MODE POP_BUNDLE_SHA, PRETOUCH_DIR (VM8-v* evidence
#   of the current QEMU lifetimes), MEASURE_ENV_DIR MEASURE_PART_DIR (h3-gate.sh), EXPECT_DAX_UUID,
#   VPLAIN PLAIN_BUILD LOADGEN X_DATA X_WRITES X_NB X_MAXIDS X_MAXW X_MAXD X_INIT_CAP,
#   Megalon (only when a lifetime is mg / mgoff): MEG_BUILD VMEG MEG_CFG MEG_LIB MG_MAXD,
#   H2N_SLO_PART (loadgen SLO part arguments), H2N_OPCOH_STRICT (0 | 1), H2N_CXLBW (0 | 1), H2N_HOSTCPU (0 | 1)
# Order: lock -> [CXL.mem sampler] -> pretouch check (N VMs) -> h3 gate -> guest prechecks + install sha256 vs the Host
# builds -> dmesg baseline -> lifetimes (each: h3 gate, dax owner, [Popcorn: shm load / preload / enable / recv_mode /
# instr], run.sh part slo, checks, [teardown], dmesg check) -> pretouch check (end) -> BLOCK DONE.
# Outputs: E/h2n-results.tsv (one row per lifetime), E/<sys>-<mix>-n<N>/ (run.sh run dir with part slo/), E/cxlbw/
# (sampler: perf.csv, start/stop-epoch.txt), E/hostcpu/ (host-cpu-sampler.py: samples.csv, manifest.txt), E/block.log,
# E/rollback.out. EXIT trap as h3-block.sh (servers stopped,
# cxl_shm teardown, dax0.0 root:root 600, final dmesg check, unlock; the sampler stops itself at the unlock).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control
EV=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$EV/../.." && pwd)
XV=$TREE/experiments/vectordb XK=$TREE/experiments/rocksdb
HG=$TREE/scripts/host/h3-gate.sh OPC=$TREE/workloads/vectordb/tests/opcoh_check.py
die() { echo "BLOCK STOP: $*"; exit 2; }
# H2N_BLOCK_DRY=1 (runset-h2n.sh --dry only): every check up to the evidence-dir check, then exit 0 before the lock; a
# pending artifact (per-N Megalon build / install dir / config) is reported, not fatal, in a dry start only
DRYB=${H2N_BLOCK_DRY:-0}
pending() { if [ "$DRYB" = 1 ]; then echo "BLOCK DRY NOTE: $* (a real run stops here)"; else die "$*"; fi; }
: "${H2N_N:?}" "${H2N_VCPU:?}" "${H2N_LIFETIMES:?}" "${H2N_SLO_PART:?}" "${EVAL_RUN:?}" "${SEED:?}" "${REGION:?}" "${C8:?}" "${K8:?}" "${GT8:?}"
: "${RECV_MODE:?}" "${POP_BUNDLE_SHA:?}" "${PRETOUCH_DIR:?}" "${MEASURE_ENV_DIR:?}" "${MEASURE_PART_DIR:?}" "${EXPECT_DAX_UUID:?}"
: "${VPLAIN:?}" "${PLAIN_BUILD:?}" "${LOADGEN:?}" "${X_DATA:?}" "${X_WRITES:?}" "${X_NB:?}" "${X_MAXIDS:?}" "${X_MAXW:?}" "${X_MAXD:?}" "${X_INIT_CAP:?}"
N=$H2N_N VCPU=$H2N_VCPU STRICT=${H2N_OPCOH_STRICT:-0} CXLBW=${H2N_CXLBW:-0} HOSTCPU=${H2N_HOSTCPU:-0}
[[ $N =~ ^[2-8]$ ]] || die "H2N_N must be 2..8"
[[ $VCPU =~ ^[2-9]$|^[1-9][0-9]$ ]] || die "bad H2N_VCPU"
[[ $EVAL_RUN =~ ^[1-9]$ ]] && [[ $SEED =~ ^[0-9]+$ ]] || die "bad EVAL_RUN / SEED"
[[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || die "bad RECV_MODE"
[[ $STRICT =~ ^[01]$ ]] && [[ $CXLBW =~ ^[01]$ ]] && [[ $HOSTCPU =~ ^[01]$ ]] || die "bad H2N_OPCOH_STRICT / H2N_CXLBW / H2N_HOSTCPU"
[[ $X_MAXD =~ ^[1-9][0-9]*$ ]] || die "bad X_MAXD"
# lifetimes: <sys>:<mix>, no repeats
LIVES=() HASMG=0 HASPOP=0 seen=" "
for l in $H2N_LIFETIMES; do
  s=${l%%:*} m=${l#*:}
  case $s in hw|pop) ;; mg|mgoff) HASMG=1;; *) die "bad system in $l";; esac
  case $m in u5|u50|u90) ;; *) die "bad mix in $l (u5 | u50 | u90)";; esac
  [ $s = pop ] && HASPOP=1
  [[ $seen == *" $l "* ]] && die "lifetime $l listed twice"; seen+="$l "
  LIVES+=("$l")
done
[ ${#LIVES[@]} -ge 1 ] || die "no lifetimes"
[ -f "$REGION" ] && [ "$(sha256sum < "$C8/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] \
  && (cd "$C8" && sha256sum -c --quiet packet.sha256) || die "REGION or the Popcorn bundle ($C8) does not verify"
IPS=() DOMS=()
for k in $(seq 0 $((N - 1))); do IPS+=(192.168.122.$((100 + k))); DOMS+=(cxl_vm$k); done
export NODES="${IPS[*]}" VM_DOMAINS="${DOMS[*]}" POP_IPS="${IPS[*]}" EXPECT_RUNNING="${DOMS[*]}"
export MEASURE_ENV_DIR MEASURE_PART_DIR H1_MEASURE_RUN=1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
# SQ8 overlay (h2n-sq8.conf; user decision 2026-10-21): H2N_VEC_FORMAT (fp32 | sq8; sq8 adds --vec-format sq8 to every
# system's server arguments), H2N_EF (query ef), H2N_INIT (guest init dir on vm0), H2N_HOST_IMAGE (Host copy of it,
# SHA256SUMS checked against the guest's). Unset = the fp32 values every h2n run before SQ8 used.
INIT=${H2N_INIT:-/home/comsys/vdb/init/seg32c32m-a27m} NA=26990000 HOST_IMAGE=${H2N_HOST_IMAGE:-$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1}
VF=${H2N_VEC_FORMAT:-fp32} EF=${H2N_EF:-32}
[[ $VF =~ ^(fp32|sq8)$ ]] && [[ $EF =~ ^[1-9][0-9]*$ ]] || die "bad H2N_VEC_FORMAT / H2N_EF ($VF, $EF)"
[ -f "$HOST_IMAGE/SHA256SUMS" ] && [ -f "$HOST_IMAGE/manifest.txt" ] || die "Host init image $HOST_IMAGE has no SHA256SUMS / manifest.txt"
if [ $VF = sq8 ]; then grep -qx "vec_format sq8" "$HOST_IMAGE/manifest.txt" && [ -f "$HOST_IMAGE/sq8.bin" ] || die "$HOST_IMAGE is not an sq8 image"
else ! grep -qx "vec_format sq8" "$HOST_IMAGE/manifest.txt" || die "$HOST_IMAGE is an sq8 image (H2N_VEC_FORMAT=fp32)"; fi
VFSA=; [ $VF = fp32 ] || VFSA=" --vec-format $VF"
PAT='[/]bin/vdb-server( |$)'
COMMON_SA="--nodes $N --segments 32 --M 16 --efc 128 --ef $EF --search-threads $((VCPU - 1)) --wait-timeout-ms 60000 --start-timeout-ms 5400000$VFSA"
# plain backend (all-HWcc, Popcorn): 28m-x capacity, delete log per node X_MAXD (h2n_layout.py: total constant over N)
SA="$COMMON_SA --max-writes $X_MAXW --max-ids $X_MAXIDS --max-deletes $X_MAXD --init-capacity $X_INIT_CAP"
HOSTSRV=$PLAIN_BUILD/bin/vdb-server
[ -x "$HOSTSRV" ] || die "missing $HOSTSRV"
[ -x "$LOADGEN" ] || die "missing $LOADGEN"
# targets of the writes file must cover exactly the N VMs (one writer per VM receives updates)
python3 -I -B - "$X_WRITES" "$N" <<'PY' || die "writes file $X_WRITES does not target exactly $N VMs"
import sys, numpy as np
w = np.memmap(sys.argv[1], dtype=np.dtype([("op", "u1"), ("target", "u1"), ("p", "u1", 22)]), mode="r")
t = np.unique(w["target"])  # the whole file (verifier review v1 L8)
sys.exit(0 if list(t) == list(range(int(sys.argv[2]))) else 1)
PY
INSTALL="${VPLAIN#/home/comsys/}/bin/vdb-server $HOSTSRV
${VPLAIN#/home/comsys/}/bin/vdb-node.sh $TREE/scripts/guest/vdb-node.sh
${VPLAIN#/home/comsys/}/cfg/cxl_region.yaml $REGION"
# shellcheck disable=SC2086
APP=$("$HOSTSRV" $SA --print-app-bytes) || die "print-app-bytes ($HOSTSRV, --nodes $N)"
RING=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
[ $((APP + RING)) -lt 268435456 ] || die "app HWcc $APP B + ring $RING B exceed the 256 MiB HWcc budget at N = $N"
# SWcc fit of the plain layout at this N and X_MAXD (backend.h formulas; the server's own fits() check runs at start)
LAYOUT=$(python3 -I -B "$EV/h2n_layout.py" --vec-format $VF --check "$N" "$X_MAXD") || die "h2n_layout.py: $LAYOUT"
MGSA= MGINSTALL= MGAPP=-
if [ $HASMG = 1 ]; then
  : "${MEG_BUILD:?}" "${VMEG:?}" "${MEG_CFG:?}" "${MEG_LIB:?}" "${MG_MAXD:?}"
  # VDB_MG_CAPACITY=h1 (m4-run.sh X_MEGALON_H1CAP=1): 28M capacity, no --init-capacity; delete log per node MG_MAXD
  MGSA="--backend megalon $COMMON_SA --max-writes 2097152 --max-ids 28000000 --max-deletes $MG_MAXD"
  MGOK=1
  for f in "$MEG_BUILD/bin/vdb-server" "$MEG_BUILD/manifest.txt" "$MEG_CFG" "$MEG_LIB/manifest.txt"; do
    [ -f "$f" ] || { MGOK=0; pending "Megalon input missing for N = $N: $f (megalon-n agent)"; }
  done
  [[ $VMEG == /home/comsys/* ]] || { MGOK=0; pending "Megalon guest dir for N = $N is not set (VMEG=$VMEG)"; }
  if [ $MGOK = 1 ]; then
    grep -qx "megalon_build=$MEG_LIB" "$MEG_BUILD/manifest.txt" || die "$MEG_BUILD is not on $MEG_LIB"
    grep -q "^shim_kind=shared$" "$MEG_BUILD/manifest.txt" || die "$MEG_BUILD has no shared (v3) shim"
    for c in constants_h_LOGICAL_NODE_NUM constants_rs_LOGICAL_NODE_NUM; do
      grep -qx "$c=$N" "$MEG_LIB/manifest.txt" || die "$MEG_LIB: $c != $N (Megalon must be built for N nodes)"
    done
    # shellcheck disable=SC2086
    MGAPP=$("$MEG_BUILD/bin/vdb-server" $MGSA --print-app-bytes) || die "print-app-bytes (Megalon, --nodes $N)"
    VM=${VMEG#/home/comsys/}
    MGINSTALL="$VM/bin/vdb-server $MEG_BUILD/bin/vdb-server
$VM/bin/vdb-node.sh $TREE/scripts/guest/vdb-node.sh
$VM/lib/libmegalon-objapi.so $MEG_BUILD/lib/libmegalon-objapi.so
$VM/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
$VM/lib/libtbb.so.12 $MEG_BUILD/lib/libtbb.so.12
$VM/lib/libtbbmalloc.so.2 $MEG_BUILD/lib/libtbbmalloc.so.2
$VM/lib/libhwloc.so.15 $MEG_BUILD/lib/libhwloc.so.15
$VM/lib/libatomic.so.1 $MEG_BUILD/lib/libatomic.so.1
$VM/cfg/megalon.yaml $MEG_CFG
$VM/cfg/cxl_region.yaml $REGION"
  fi
fi
SAMPLER=$EV/cxl-bw-sampler.sh   # copy of workspaces/cxl-bw/cxl-bw-sampler.sh (perf CXL CM PMU, 1 s, until unlock)
[ $CXLBW = 0 ] || [ -f "$SAMPLER" ] || die "H2N_CXLBW=1 needs $SAMPLER"
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)
[ $CXLBW = 0 ] || [ "${PARANOID:-9}" -le 0 ] || echo "BLOCK NOTE: kernel.perf_event_paranoid=$PARANOID > 0: the CXL.mem sampler will refuse (recorded; the block runs without it)"
HCS=$EV/host-cpu-sampler.py   # Host CPU of each VM's QEMU emulator / vhost threads + loadgen, 1 s, until unlock (M4, L10)
[ $HOSTCPU = 0 ] || [ -f "$HCS" ] || die "H2N_HOSTCPU=1 needs $HCS"
LG_CPUS_H=56-63               # run.sh default LG_CPUS (loadgen CPUs), sampled as Host CPU busy
OWNER=eval-h2n-n$N-run$EVAL_RUN
echo "BLOCK PLAN: vec_format=$VF ef=$EF init=$INIT host_image=$HOST_IMAGE"
echo "BLOCK PLAN: h2n vdb N=$N vcpu/VM=$VCPU threads $((VCPU - 1))+1 nodes=[${IPS[*]}] lifetimes=[${LIVES[*]}] app=$APP mg_app=$MGAPP ring=$RING cxlbw=$CXLBW hostcpu=$HOSTCPU opcoh_strict=$STRICT"
echo "BLOCK PLAN: server_args plain=[$SA]${MGSA:+ megalon=[$MGSA]}"
echo "BLOCK PLAN: $LAYOUT"
if [ "$DRYB" = 1 ]; then echo "BLOCK DRY STOP: evidence-dir check reached ($E; dry: no lock, no VM contact)"; exit 0; fi
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || die "$E missing or not empty"
# ---------------------------------------------------------------------------------------------------- real block
bash "$HG" lock "$OWNER" || die "lock"
DMESG_DONE=0
log() { echo "$(date -Is) $*" | tee -a "$E/block.log"; }
stop() { log "BLOCK STOP $*"; exit 1; }
if [ $CXLBW = 1 ]; then  # stops by itself within ~10 s of the unlock (UNTIL_UNLOCK=1); a refusal is recorded, not fatal
  setsid nohup bash "$SAMPLER" "$E/cxlbw" > "$E/cxlbw.log" 2>&1 < /dev/null &
  log "cxl-bw sampler pid $! -> $E/cxlbw (sampler sha256 $(sha256sum < "$SAMPLER" | cut -c1-16), paranoid=$PARANOID)"
fi
if [ $HOSTCPU = 1 ]; then  # read only (/proc, /run/libvirt/qemu/<dom>.pid); stops by itself ~10 s after the unlock
  setsid nohup nice -n 19 taskset -c 18-23 python3 -I -B "$HCS" "$E/hostcpu" --domains "${DOMS[*]}" --loadgen "$LOADGEN" \
    --cpus "$LG_CPUS_H" > "$E/hostcpu.log" 2>&1 < /dev/null &
  log "host-cpu sampler pid $! -> $E/hostcpu (sampler sha256 $(sha256sum < "$HCS" | cut -c1-16))"
fi
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
dmesg_check() {  # <tag>: 1 on a new bad line, an ssh failure or a wrap
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
}
finish() {
  trap '' INT TERM HUP
  set +eu
  pkill -TERM -P $$ 2>/dev/null; sleep 1
  local ip out
  for ip in "${IPS[@]}"; do  # our servers by command line (run.sh stops its own nodes in its traps)
    out=$($SSH comsys@$ip "pkill -u comsys -f -- '$PAT'; for i in \$(seq 15); do pgrep -u comsys -f -- '$PAT' > /dev/null || break; sleep 1; done
      pkill -9 -u comsys -f -- '$PAT'; sleep 1; echo procs=\$(pgrep -c -u comsys -f -- '$PAT')" < /dev/null 2>&1)
    echo "$out" | sed "s/^/$(date -Is) $ip /" >> "$E/rollback.out"
    echo "$out" | grep -qx "procs=0" || echo "ROLLBACK FAIL: $ip server process left (see rollback.out)" | tee -a "$E/rollback.out"
  done
  shm_teardown_left
  dax_unused rollback || echo "ROLLBACK FAIL: /dev/dax0.0 in use on a VM (see dax-users.txt)" | tee -a "$E/rollback.out"
  dax_owner root || echo "ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see dax-owner.txt)" | tee -a "$E/rollback.out"
  [ $DMESG_DONE = 0 ] || { dmesg_check final || echo "$(date -Is) final dmesg check: see block.log" >> "$E/rollback.out"; }
  bash "$HG" unlock "$OWNER"
}
trap finish EXIT
trap 'log "BLOCK STOP signal"; exit 130' INT TERM HUP
gate() { bash "$HG" check "$E/gate-$1.txt" > /dev/null || stop "h3 gate ($1; see gate-$1.txt)"; }
{ echo "# h2n block $OWNER: vdb N=$N vcpu/VM=$VCPU lifetimes [${LIVES[*]}] seed=$SEED recv_mode=$RECV_MODE"
  echo "nodes=${IPS[*]} domains=${DOMS[*]} server_args=[$SA] megalon_args=[$MGSA] app_hwcc=$APP mg_app_hwcc=$MGAPP ring=$RING region_sha256=$(sha256sum < "$REGION" | cut -c1-64)"
  echo "host_server=$HOSTSRV sha256=$(sha256sum < "$HOSTSRV" | cut -c1-64) loadgen=$LOADGEN sha256=$(sha256sum < "$LOADGEN" | cut -c1-64)"
  [ $HASMG = 1 ] && echo "megalon_build=$MEG_BUILD lib=$MEG_LIB cfg=$MEG_CFG sha256=$(sha256sum < "$MEG_CFG" | cut -c1-64) vmeg=$VMEG mg_max_deletes=$MG_MAXD"
  echo "writes=$X_WRITES sha256=$(sha256sum < "$X_WRITES" | cut -c1-64) max_deletes=$X_MAXD"
  echo "slo_part=[$H2N_SLO_PART]"
  for d in "${DOMS[@]}"; do x=$(virsh -c qemu:///system dumpxml --inactive "$d" 2>/dev/null); echo "vm_xml_sha256.$d=$(printf '%s' "$x" | sha256sum | cut -c1-64) bytes=${#x}"; done
} > "$E/h2n-params.txt"
log "== PT pretouch check (start, $N VMs)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-start.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (start)"
log "== H0 h3 gate"; gate H0
log "== guest prechecks (install sha256 = Host builds; guests 2..N-1 inherit vm0's files at the topology freeze)"
SUMS=$(sha256sum < "$HOST_IMAGE/SHA256SUMS" | cut -c1-64)
ALLINST=$INSTALL${MGINSTALL:+
$MGINSTALL}
for i in "${!IPS[@]}"; do
  $SSH comsys@${IPS[$i]} "EXPECT_K=$K8 EXPECT_DAX_UUID=$EXPECT_DAX_UUID INIT_DIR=$INIT INIT_SUMS=$SUMS INIT_CHECK=$([ $i = 0 ] && echo 1 || echo 0) INSTALL_DIRS='$(echo "$ALLINST" | awk '{print $1}' | tr '\n' ' ')' bash -s" \
    < $XV/m4-precheck.sh > "$E/precheck-vm$i.txt" 2>&1
  grep -q "^PRECHECK PASS" "$E/precheck-vm$i.txt" || stop "precheck vm$i: $(grep -m1 'PRECHECK FAIL' "$E/precheck-vm$i.txt")"
  while read -r g h; do
    grep -q "^$(sha256sum < "$h" | cut -c1-64)  /home/comsys/$g\$" "$E/precheck-vm$i.txt" || stop "vm$i /home/comsys/$g != $h (install needed on the guest)"
  done <<< "$ALLINST"
  [ "$($SSH comsys@${IPS[$i]} nproc < /dev/null)" = "$VCPU" ] || stop "vm$i nproc != $VCPU"
done
for i in "${!IPS[@]}"; do c=$(dmesg_count $i) || stop "dmesg baseline vm$i"; echo "$c" > "$E/dmesg-base-vm$i.txt"; done
DMESG_DONE=1
printf '# name\tsystem\tmix\tU\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\topcoh_check\n' > "$E/h2n-results.tsv"
echo "${LIVES[*]}" > "$E/order.txt"
OWNED=root
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
    [ "$($SSH comsys@$ip "test -f $VPLAIN/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $VPLAIN/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)
  $SSH comsys@${IPS[0]} "mkdir -p $VPLAIN/runs && echo \$\$ > $VPLAIN/runs/preload-$1.pid && exec timeout -k 30 1200 env CXL_REGION_CONFIG=$VPLAIN/cfg/cxl_region.yaml $VPLAIN/bin/vdb-server --node 0 --preload-only --init-dir $INIT $SA" \
    < /dev/null > "$E/preload-$1.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-$1.log"
  { grep -q "PRELOAD DONE" "$E/preload-$1.log" && servers_gone; } || stop "preload ($1)"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable >> "$E/block.log" 2>&1 || stop "enable gate"
  for ip in "${IPS[@]}"; do
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled" < /dev/null)
    echo "$ip recv_mode=$m instr_enabled=$i" >> "$E/recv-mode-$1.txt"
    [ "$m" = "$RECV_MODE" ] && [ "$i" = 1 ] || stop "recv_mode / instr on $ip ($m, $i)"
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1 || stop "status pre"
}
pop_down() {
  env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status >> "$E/block.log" 2>&1
  servers_gone || stop "servers left (Popcorn teardown not attempted)"
  dax_unused pre-teardown || stop "/dev/dax0.0 in use before the cxl_shm teardown"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/block.log" 2>&1 || stop "shm teardown"
}
sys_up() {  # <sys> <name>: dax owner (hw, mg, mgoff: comsys) + Popcorn cycle
  case $1 in
    hw|mg|mgoff) [ $OWNED = comsys ] || { dax_owner comsys || stop "dax0.0 -> comsys"; OWNED=comsys; };;
    pop) pop_up "$2";;
  esac
}
# ---- one lifetime: run.sh (N nodes, PARTS=slo) with the H1 SLO part arguments ---------------------------------------
vdb_life() {  # <sys> <mix>
  local s=$1 mix=$2 U=${2#u} name=$1-$2-n$N R k L RP note rc mode oc=- OPS
  R=$E/$name
  local LG=(--opt data=$X_DATA --opt writes=$X_WRITES --opt k=10 --mix "update=$U,search=$((100 - U))" --slo search:99:100 --x-stream search --raw)
  local RE=(V=$VPLAIN HOST_SERVER=$HOSTSRV LOADGEN=$LOADGEN INIT=$INIT READY_TIMEOUT=5400 RUN_KIND=measurement TRACE=0 STATS_OP=10
    PARTS=slo H1_MEASURE_RUN=1 MEASURE_PART_DIR=$MEASURE_PART_DIR "PART_ARGS_slo=$H2N_SLO_PART" PART_SEED_slo=$SEED
    "PART_GATE_CMD=bash $HG check")   # between parts: the N-VM gate (run.sh part hook), never the 2-VM h1-gate.sh
  case $s in
    hw)  RE+=(SYSTEM=all-HWcc NODE_ENV= NODE0_ENV= "SERVER_ARGS=$SA"); mode=hwcc OPS=none;;
    pop) RE+=(SYSTEM=Popcorn-$RECV_MODE NODE_ENV= NODE0_ENV= "SERVER_ARGS=$SA --preloaded"); mode=popcorn OPS=swmc_acct;;
    mg)  RE+=(SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server "SERVER_ARGS=$MGSA" "NODE_ENV=ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml"
              NODE0_ENV=ENV:MEGALON_REINIT=1); mode=megalon-vm OPS=cohsnap;;
    mgoff) RE+=(SYSTEM=Megalon V=$VMEG HOST_SERVER=$MEG_BUILD/bin/vdb-server "SERVER_ARGS=$MGSA"
              "NODE_ENV=ENV:RACKOBJ_CONFIG=$VMEG/cfg/megalon.yaml ENV:MEGALON_COH_TIMERS=0" NODE0_ENV=ENV:MEGALON_REINIT=1); mode=megalon-t0 OPS=cohsnap;;
  esac
  gate $name; sys_up $s $name
  servers_gone || stop "a vdb-server runs before $name"
  log "$name: run.sh part slo ($s, $mix, N=$N)"
  env "${RE[@]}" bash $XV/run.sh "$name" "$E" -- "${LG[@]}" > "$E/$name.out" 2>&1; rc=$?
  log "$name: run.sh rc $rc: $(tail -n 1 "$E/$name.out")"
  [ $s = pop ] && pop_down
  servers_gone || stop "servers left after $name"
  [ -d "$R" ] || stop "$name: no run dir"
  for k in "${!IPS[@]}"; do  # clean stop, no bad record, op coherence on and error-free (m4-run.sh rules, N nodes)
    L=$R/node$k.log
    { grep -q "vdb-server: stopping" $L && [ "$(grep -c '^bad_records=0$' $L)" = 1 ]; } || stop "$name node$k: no clean stop / bad_records"
    grep -q "^vdb-server: op coherence on," $L || stop "$name node$k: op coherence not on"
    case $OPS in
      swmc_acct) grep -qE "^vdb-server: op coherence on, popcorn source swmc_acct[ ,]" $L || stop "$name node$k: popcorn source != swmc_acct";;
      cohsnap) grep -qE "^vdb-server: op coherence on, .*megalon cohsnap on," $L || stop "$name node$k: megalon cohsnap not on";;
    esac
    { grep -qx "opcoh.read_errors=0" $L && grep -qx "opcoh.register_errors=0" $L; } || stop "$name node$k: opcoh errors"
  done
  RP=$R/slo
  [ -s $RP/loadgen/summary.json ] || stop "$name: no loadgen output"
  grep -q '"reason":"stream [a-z]* exhausted' $RP/loadgen/steps.jsonl && stop "$name: writes file exhausted"
  { grep -qx "ok_without_coh=0" $RP/loadgen/vectordb.txt && grep -qx "updates_ok_without_coh=0" $RP/loadgen/vectordb.txt &&
    grep -qx "bad_coh_version=0" $RP/loadgen/vectordb.txt; } || stop "$name: responses without an op coherence block"
  python3 $XV/opsplit.py $RP > $RP/opsplit.log 2>&1 || stop "$name: opsplit.py (see $RP/opsplit.log)"
  # opcoh_check on all N nodes (generalised; OPCOH_NODES = N): a FAIL stops only with H2N_OPCOH_STRICT=1
  OPCOH_NODES=$N OPCOH_PARTS=$RP MEGALON_LEAN=1 OPCOH_RECORD_BYTES=$([ $VF = sq8 ] && echo 832 || echo 3136) \
    python3 $OPC $RP $mode > $RP/opcoh-check.txt 2>&1
  oc=$(grep -m1 -oE '^OPCOH_CHECK (PASS|FAIL)' $RP/opcoh-check.txt | cut -d' ' -f2); oc=${oc:-ERROR}
  if [ "$oc" != PASS ]; then
    [ $STRICT = 1 ] && stop "$name: opcoh_check $mode $oc (see $RP/opcoh-check.txt)"
    log "$name NOTE: opcoh_check $mode $oc on $N nodes (H2N_OPCOH_STRICT=0: recorded; see $RP/opcoh-check.txt)"
  fi
  python3 $XV/urate_check.py $RP --writers 1 > $RP/urate-check.txt 2>&1 || true
  python3 $XV/e1_check.py --writes $X_WRITES --na $NA --nb $X_NB --searches $RP/loadgen/searches.bin --out $RP/e1 --sample 500 > /dev/null \
    || stop "$name: E1 violation (see $RP/e1.e1.txt)"
  grep -q 'workload_finish":"ok' $RP/loadgen/summary.json || stop "$name: loadgen workload finish"
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' $RP/loadgen/summary.json 2>/dev/null)
  if [ -n "$note" ]; then
    # main 2026-10-21 13:3x: "the start rate already violates the SLO" is a result (no rate under the SLO at or above
    # the ramp start: the row keeps empty max/confirm values) and the block goes on; before, it stopped the block and
    # skipped every later lifetime (SQ8 run 1 N=2: mg-u90 stop -> pop u5/u50/u90 not run)
    case "$note" in
      "confirm failed at three rates; the knee is noisy (longer --confirm-s?)"|"the start rate already violates the SLO; lower --start") ;;
      *) stop "$name: loadgen note: $note";;
    esac
    log "$name NOTE: $note"
  elif [ $rc != 0 ]; then stop "$name: run.sh rc $rc"; fi
  python3 -I -c 'import json,sys
s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); f=lambda v: "" if v is None else str(v)
print("\t".join(sys.argv[2:8] + [f(s.get("max_offered_x_pass")), f(c.get("x_mean")), f(s.get("confirmed")), s.get("note",""), sys.argv[8], sys.argv[9]]))' \
    $RP/loadgen/summary.json "$name" $s $mix $U $N $VCPU "$name/slo" "$oc" >> "$E/h2n-results.tsv"
  dmesg_check $name || stop "$name: dmesg check"
}
# ---- sequence ----------------------------------------------------------------------------------------------------
for l in "${LIVES[@]}"; do
  log "== HSLO ${l%%:*} ${l#*:} n$N"
  vdb_life "${l%%:*}" "${l#*:}"
done
[ $OWNED = root ] || { dax_owner root || stop "dax0.0 back to root"; OWNED=root; }
log "== PT pretouch check (end)"
bash $XK/pretouch-check-n.sh "$PRETOUCH_DIR" "$E/pretouch-check-end.txt" >> "$E/block.log" 2>&1 || stop "pretouch check (end)"
log "BLOCK DONE $OWNER"
