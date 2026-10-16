#!/bin/bash
# The recommendation-system H1 MAIN block (reports/RECSYS-main-packet.md): full-size tables (26 tables, 26M cap,
# 167,731,776 slots x 576 B = 89.98 GiB), T = 60 s, serving on node 1, MOT1 v6 (user 2026-10-16):
#   SLO query p95 <= 100 ms (DeepRecSys ISCA'20; reports/MOT1-v6-sources.md §1), fixed for every system (<E>/slo.txt);
#   updater on node 0 replays the real MLPerf day-23 multi-hot trace at the Ekko operating point EKKO=avg (3.08% of
#   rows/hour -> PUBLISH_FRAC 0.0308/60 per T) or EKKO=peak (4.3%/10 min -> 0.043/10 per T); the sample rate is
#   computed on the Host by recsys-rate from the trace (<E>/update-rate.txt) so that one T publishes that fraction.
#   (v5 rule "SLO = 5 x all-HWcc p99 at the lowest load" and the fixed 2,100 samples/s are superseded.) Every system on the Popcorn build POP_BUILD (>= 10) kernel (K8): all-HWcc and Megalon with cxl_shm unloaded, page MSI
# with cxl_shm loaded once for its whole server lifetime (init_state=shared + preload, recv_mode RECV_MODE).
# usage: main-block.sh <evidence dir (exists; only sequence* files)>
# env (required): C8 (Popcorn deploy bundle dir, = builds/popcorn_new/10/deploy-v1), K8, GT8 (names kept from v5),
#   RECV_MODE, optional POP_BUILD (10, >= 10), POP_BUNDLE_SHA (build-10 deploy-v1 packet hash), D (inputs dir with MANIFEST.txt),
#   VM_PLAIN (guest dir: build-3 server, all-HWcc + page MSI), VM_MEG (guest dir: Megalon build + recsys-2vm.yaml),
#   MEG_BUILD (recsys-megalon build on MEGALON_BASE, default builds/megalon/75), PLAIN_BUILD (v6 recsys build dir), EKKO
#   (avg | peak), LOADGEN; optional SEED (20261016), UPD_FILE / QRY_FILE (names in D; default the day-23 slices of
#   builds/recsys-inputs/1),
#   ROUNDS (3), FIXED (1; 0 = no fixed-load window), XT (server lifetime bound, s, default 28800),
#   SYSTEMS (subset of "hw pop mg", seeded order kept), L_FROM (fixed-load-L.txt; needed when hw is not in SYSTEMS
#   and FIXED=1).
# Load once per system (recorded exception to "every run starts from the initial image"): per system one server
# lifetime (session.sh) with, in this order,
#   warmup 1 query/s + the updater, 10 s + 70 s, unmeasured (results kept, never used): after the server's own read of
#          every slot (both nodes, before READY; page MSI read first-touch faults happen there), the first T = 60 s
#          publication round (updater write faults / page MSI invalidations) and the query path's first use
#   gate   1 query/s, 60 s, no SLO abort: the lowest-load window. VALID = one step, keeps up, no errors/timeouts,
#          >= 1 query (main_util.py gate, within_slo by p95). all-HWcc: INVALID STOPs the block. page MSI / Megalon:
#          recorded with within_slo (block continues)
#   slo-r1, slo-r2, slo-r3   full MOT1 §3.3 SLO searches (PROFILE=main: warm-up 10 s, steps 3 s + 15 s, bisect 5%,
#          confirm 3 x 30 s with step-down, fill 0.7/0.8/0.9, overload 1.05/1.1/1.2), loadgen seed SEED + round
#   fixed  60 s at L = 0.5 x all-HWcc slo-r1 confirm mean (no SLO abort: the whole window is measured); breakdown.csv
#          must have the system's coherence columns (check_breakdown.py)
# System order: all-HWcc first (its gate sets the block's SLO and its slo-r1 gives every system's L),
#   then page MSI and Megalon in an order shuffled with seed = the block owner (recorded in order.txt).
# /dev/dax0.0: comsys for all-HWcc / Megalon, root:root 600 before page MSI (p-popcorn-shm.sh precheck; its teardown
# restores it). Holds workspaces/MEASUREMENT.lock; Host gate before every measurement; stops at the first MAIN STOP.
# On every exit (finish, not interruptible): stop this block's servers (session dirs and a running --preload-only via its pid file),
# tear down page MSI if loaded without "teardown PASS" (instr-on retry), /dev/dax0.0 back to root:root 600
# UNCONDITIONALLY on both VMs ("ROLLBACK FAIL" if a stat line is not root:root 600 or a recsys-server survived), unlock.
# A measurement whose stats key/file is missing stops the block with "STATS MISSING <key>" (session.sh rc 5).
# BLOCK=v1 (reports/RECSYS-V1-packet.md): validation block instead of the H1 measurements: per system one lifetime
#   with the warm-up and one fixed-load window at V1_RATE (1) query/s for V1_WINDOW_S (130 s, >= 2 rounds of T = 60 s),
#   then v1_check.py (FAIL stops) and check_breakdown.py; systems hw pop mg mgoff (mgoff = Megalon with
#   MEGALON_COH_TIMERS=0, same load, for the timer on/off comparison); no SLO search, no gate, no fixed-L window.
set -uo pipefail
E=${1:?evidence dir}
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/recsys G=$P/CXL_SWMC/experiments/vectordb/host-gate.sh
: "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}" "${D:?}" "${VM_PLAIN:?}" "${VM_MEG:?}" "${MEG_BUILD:?}" "${LOADGEN:?}"
: "${PLAIN_BUILD:?}" "${EKKO:?}"
MB=$MEG_BUILD SEED=${SEED:-20261016} ROUNDS=${ROUNDS:-3} FIXED=${FIXED:-1} XT=${XT:-28800}
BLOCK=${BLOCK:-main} V1_RATE=${V1_RATE:-1} V1_WINDOW_S=${V1_WINDOW_S:-130}
case $BLOCK in main|v1) ;; *) echo "SEQUENCE STOP: BLOCK must be main or v1"; exit 2;; esac
MEGALON_BASE=${MEGALON_BASE:-$P/builds/megalon/75}
UPD_FILE=${UPD_FILE:-updates-day23-0-2M.smp} QRY_FILE=${QRY_FILE:-queries-day23-89137318-1M.smp}
T_MS=60000 SLO_PCT=95 SLO_MS=100
case $EKKO in
  avg) PUBLISH_FRAC=0.000513333333; EKKO_RULE="Ekko OSDI'22 average: 3.08% of rows per hour -> 0.0308/60 per T = 60 s";;
  peak) PUBLISH_FRAC=0.0043; EKKO_RULE="Ekko OSDI'22 peak: 4.3% of rows per 10 min -> 0.043/10 per T = 60 s";;
  *) echo "SEQUENCE STOP: EKKO must be avg or peak"; exit 2;;
esac
export SLO_MS SLO_RULE="DeepRecSys ISCA'20: query p${SLO_PCT} <= ${SLO_MS} ms (MOT1 v6, user 2026-10-16)"
HOST_PLAIN=$PLAIN_BUILD/bin/recsys-server
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
OWNER="RECSYS-$BLOCK-$(basename "$E")"
[[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || { echo "SEQUENCE STOP: bad RECV_MODE"; exit 2; }
[[ $ROUNDS =~ ^[1-9]$ ]] || { echo "SEQUENCE STOP: bad ROUNDS"; exit 2; }
# SYSTEMS (subset of "hw pop mg", default all): a rerun of some systems (the SLO is fixed; L for the fixed window
# comes from L_FROM). SLO_MS_FROM (v5) is not used: refused if set.
[ -z "${SLO_MS_FROM:-}" ] || { echo "SEQUENCE STOP: SLO_MS_FROM is a v5 option (v6 SLO is fixed)"; exit 2; }
for s in ${SYSTEMS:-hw pop mg}; do case $s in hw|pop|mg) ;; mgoff) [ $BLOCK = v1 ] || { echo "SEQUENCE STOP: mgoff only with BLOCK=v1"; exit 2; };; *) echo "SEQUENCE STOP: bad SYSTEMS entry $s"; exit 2;; esac; done
if [ $BLOCK = main ] && [[ " ${SYSTEMS:-hw pop mg} " != *" hw "* ]]; then
  [ "${FIXED:-1}" = 0 ] || [ -f "${L_FROM:-}" ] || { echo "SEQUENCE STOP: SYSTEMS without hw and FIXED=1 needs L_FROM=<fixed-load-L.txt>"; exit 2; }
fi
case $FIXED in 0|1) ;; *) echo "SEQUENCE STOP: bad FIXED"; exit 2;; esac
grep -q "^megalon_build=$MEGALON_BASE$" $MB/manifest.txt || { echo "SEQUENCE STOP: $MB is not on $MEGALON_BASE"; exit 2; }
[ -x "$HOST_PLAIN" ] && [ -x "$PLAIN_BUILD/bin/recsys-rate" ] || { echo "SEQUENCE STOP: $PLAIN_BUILD is not a v6 recsys build"; exit 2; }
# Popcorn deploy bundle (v6: build >= 10, swmc_acct per-thread accounting; path and packet hash from the Popcorn
# agent's verified bundle): POP_BUILD, POP_BUNDLE_SHA (sha256 of C8/packet.sha256). Build-8 bundles are refused.
POP_BUILD=${POP_BUILD:-10} POP_BUNDLE_SHA=${POP_BUNDLE_SHA:-626f6a0eb265553aaa6efb2d67c185497121e77b8ab0ece2243a461bd4f291c6}
# default: Popcorn build 10, builds/popcorn_new/10/deploy-v1 (release 6.14.0-famfs-de-stijl+-ds-popcorn-new-10;
# sha256 of its packet.sha256 recorded 2026-10-16)
[[ $POP_BUILD =~ ^[0-9]+$ ]] && [ "$POP_BUILD" -ge 10 ] || { echo "SEQUENCE STOP: POP_BUILD must be >= 10 (Fig 2 needs swmc_acct)"; exit 2; }
[ -d "$C8" ] && [ ! -e $C8/SUPERSEDED.txt ] \
  && [ "$(sha256sum < $C8/packet.sha256 | cut -d' ' -f1)" = "$POP_BUNDLE_SHA" ] \
  && (cd $C8 && sha256sum -c --quiet packet.sha256) || { echo "SEQUENCE STOP: C8 is not the verified Popcorn build-$POP_BUILD bundle"; exit 2; }
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
bash $G lock "$OWNER" || { echo "SEQUENCE STOP: lock"; exit 2; }
SA="--nodes 2 --row-div 1 --serve-threads 14 --update-threads 4 --load-threads 8 --start-timeout-ms $((XT * 1000 / 2)) --publish-frac $PUBLISH_FRAC
 --verify-rows 1 --proc-sysfs /sys/kernel/swmc/instr --proc-sysfs /sys/kernel/cxl_shm/instr
 --proc-sysfs /sys/kernel/swmc/page_coherence --proc-kthread cxl_recv"
SA=$(echo $SA)
export LOADGEN PROFILE=main RUN_KIND=measurement STATS_OP=10 READY_TIMEOUT=$((XT / 2)) IDLE_WAIT_S=2400  # idle: an overrunning T = 60 s round may take > 10 min (Megalon)
PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-pop INIT_STATE=shared)
CHOWNED=0
stop_servers() {  # this block's servers only: every session dir's guest run dir + the preload pid dir
  local ip g
  for ip in "${IPS[@]}"; do
    for g in $(sed -n "s/^GRUN='\(.*\)'$/\1/p" "$E"/*/session.env 2>/dev/null) $(cat "$E"/preload-*.dir 2>/dev/null); do
      $SSH comsys@$ip "for k in 0 1; do [ -e $g/node\$k.pid ] && $VM_PLAIN/bin/recsys-node.sh stop $g \$k; done; true" < /dev/null 2>&1 \
        | sed "s|^|$ip $g |" >> "$E/rollback.out"
    done
    $SSH comsys@$ip 'echo procs=$(pgrep -c -x recsys-server)' < /dev/null 2>&1 | sed "s/^/$ip /" >> "$E/rollback.out"
  done
}
servers_gone() { local ip; for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip 'pgrep -c -x recsys-server' < /dev/null)" = 0 ] || return 1; done; }
shm_cleanup() {  # page MSI loaded (load attempted) and no "teardown PASS"
  local r=$E/shm-pop
  [ -f "$r/load-vm0.txt" ] || return 0
  grep -q "teardown PASS" "$r/steps.log" 2>/dev/null && return 0
  echo "$(date -Is) cleanup teardown $r" >> "$E/cleanup.out"
  if ! env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1; then
    if grep -q "instr_enabled=1 missing" "$r/steps.log" 2>/dev/null; then
      env "${PS[@]}" bash $C8/p-popcorn-shm.sh instr-on >> "$E/cleanup.out" 2>&1 \
        && env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown >> "$E/cleanup.out" 2>&1
    fi
  fi
  grep -q "teardown PASS" "$r/steps.log" 2>/dev/null || echo "CLEANUP FAILED: $r (manual: P-popcorn packet §6)" | tee -a "$E/cleanup.out"
}
dax_root_all() {  # both VMs, always; fresh per-check file per VM; DAXOK=1 only if every stat line is root:root 600
  local ip f=$E/dax-root-$(date +%s%N).out
  DAXOK=1
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown root:root /dev/dax0.0 && sudo -n chmod 600 /dev/dax0.0; echo stat=$(stat -c "%U:%G %a" /dev/dax0.0)' \
      < /dev/null 2>&1 | sed "s/^/$ip /" | tee -a "$E/rollback.out" > "$f.$ip"
    [ "$(grep -o 'stat=.*' "$f.$ip")" = "stat=root:root 600" ] || DAXOK=0
  done
}
finish() {
  trap '' INT TERM HUP  # the rollback itself is not interruptible
  stop_servers; shm_cleanup
  local procs_ok=1
  servers_gone || procs_ok=0
  [ $procs_ok = 1 ] || echo "$(date -Is) ROLLBACK FAIL: a recsys-server process survived on a VM (procs != 0; see $E/rollback.out)" | tee -a "$E/rollback.out"
  dax_root_all
  [ $DAXOK = 1 ] && echo "$(date -Is) rollback: dax0.0 root:root 600 on both VMs" | tee -a "$E/rollback.out" \
    || echo "$(date -Is) ROLLBACK FAIL: dax0.0 not root:root 600 on every VM (see $E/rollback.out)" | tee -a "$E/rollback.out"
  bash $G unlock "$OWNER"
}
trap finish EXIT
trap 'echo "$(date -Is) SEQUENCE STOP: interrupted"; exit 130' INT TERM HUP
stop() { echo "$(date -Is) MAIN STOP $*"; exit 1; }
dax_comsys() {  # before an all-HWcc / Megalon session
  local ip
  if [ $CHOWNED = 1 ]; then  # already chowned by this block: fresh stat on both VMs before the next lifetime
    for ip in "${IPS[@]}"; do
      $SSH comsys@$ip 'stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/dax-stat-$ip-$(date +%s%N).out" 2>&1
      grep -qx "comsys:root 600" "$(ls -t "$E"/dax-stat-$ip-*.out | head -1)" || stop "dax0.0 on $ip is not comsys:root 600"
    done
    return 0
  fi
  for ip in "${IPS[@]}"; do
    $SSH comsys@$ip 'sudo -n chown comsys /dev/dax0.0 && stat -c "%U:%G %a" /dev/dax0.0' < /dev/null > "$E/chown-$ip-$(date +%s).out" 2>&1
    CHOWNED=1
    grep -qx "comsys:root 600" "$(ls -t "$E"/chown-$ip-*.out | head -1)" || stop "chown $ip"
  done
}
dax_root() {  # before the page MSI lifetime (no server of ours runs then)
  servers_gone || stop "a recsys-server runs before page MSI"
  [ $CHOWNED = 1 ] || return 0
  dax_root_all; CHOWNED=0
  [ $DAXOK = 1 ] || stop "dax0.0 not back to root:root 600 before page MSI"
}
shuffle() { python3 -c 'import random,sys; v=sys.argv[2:]; random.Random(sys.argv[1]).shuffle(v); print(" ".join(v))' "$OWNER" "$@"; }
confirm_half() { python3 $X/main_util.py half "$1"; }        # 0.5 x confirm mean of an SLO search without a note
gatechk() { python3 $X/main_util.py gate "$1" "$SLO_MS" "$SLO_PCT"; }  # validity + within the SLO (p95)
precheck() {
  local i f h files="${VM_PLAIN#/home/comsys/}/bin/recsys-server ${VM_PLAIN#/home/comsys/}/bin/recsys-node.sh ${VM_PLAIN#/home/comsys/}/cfg/cxl_region.yaml ${VM_MEG#/home/comsys/}/bin/recsys-server ${VM_MEG#/home/comsys/}/bin/recsys-node.sh ${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so ${VM_MEG#/home/comsys/}/lib/libmegalon.so ${VM_MEG#/home/comsys/}/cfg/megalon.yaml ${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml"
  for i in 0 1; do
    $SSH comsys@${IPS[$i]} "EXPECT_K=$K8 MEM_MIN=60 INSTALL_FILES='$files' bash -s" < $X/precheck.sh > "$E/precheck-${IPS[$i]}.out" 2>&1
    grep -q "^PRECHECK PASS" "$E/precheck-${IPS[$i]}.out" || stop "precheck ${IPS[$i]}"
    for f in "${VM_PLAIN#/home/comsys/}/bin/recsys-server $HOST_PLAIN" "${VM_MEG#/home/comsys/}/bin/recsys-server $MB/bin/recsys-server" \
             "${VM_MEG#/home/comsys/}/lib/libmegalon-objapi.so $MB/lib/libmegalon-objapi.so" "${VM_MEG#/home/comsys/}/lib/libmegalon.so $MB/lib/libmegalon.so" \
             "${VM_MEG#/home/comsys/}/cfg/megalon.yaml $P/CXL_SWMC/systems/megalon/recsys-2vm.yaml" \
             "${VM_PLAIN#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" "${VM_MEG#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml" \
             "${VM_PLAIN#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh" "${VM_MEG#/home/comsys/}/bin/recsys-node.sh $P/CXL_SWMC/scripts/guest/recsys-node.sh"; do
      set -- $f
      grep -q "^$(sha256sum "$2" | cut -d' ' -f1)  /home/comsys/$1\$" "$E/precheck-${IPS[$i]}.out" || stop "${IPS[$i]} /home/comsys/$1 != $2"
    done
  done
  (cd "$D" && sha256sum -c --quiet <(grep -E '^[0-9a-f]{64}  ' MANIFEST.txt)) > "$E/inputs-check.out" 2>&1 || stop "inputs differ from $D/MANIFEST.txt"
  for f in "$UPD_FILE" "$QRY_FILE" dist_quantile.txt; do  # the inputs this block uses: listed and sha256-verified
    h=$(sed -n "s/^\([0-9a-f]\{64\}\)  $f\$/\1/p" "$D/MANIFEST.txt")
    [ -n "$h" ] || stop "$f not in $D/MANIFEST.txt"
    [ "$(sha256sum "$D/$f" | cut -d' ' -f1)" = "$h" ] || stop "$D/$f sha256 != MANIFEST"
  done
}
measure() {  # session dir, name, loadgen args... -> rc of session.sh measure
  local S=$1 n=$2; shift 2
  bash $G check "$E/gate-$(basename "$S")-$n.txt" || stop "host gate before $(basename "$S")/$n"
  bash $X/session.sh measure "$S" "$n" -- "$@" > "$S.$n.out" 2>&1
  local rc=$?
  tail -2 "$S.$n.out" | sed "s|^|  $(basename "$S")/$n: |"
  [ $rc = 5 ] && stop "$(basename "$S")/$n: $(grep -m1 '^STATS MISSING' "$S.$n.out") (session.sh rc 5)"
  return $rc
}
pop_setup() {  # P-popcorn-deploy §6a cycle with build POP_BUILD (init_state=shared), as pilot-run.sh, once per lifetime
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh precheck || stop "shm precheck"
  local ip m i t
  for ph in load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do  # the server's region config must equal the module parameters' one
    [ "$($SSH comsys@$ip "test -f $VM_PLAIN/cfg/cxl_region.yaml && test -f $GT8/cxl_region.yaml && sha256sum $VM_PLAIN/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || stop "region config missing or different on $ip"
  done
  t=$(date +%s)  # node 0 writes the initial tables through a plain mapping before coherence is enabled (no HWcc access)
  local PD=$VM_PLAIN/runs/preload-main-$(date +%s)
  echo "$PD" > "$E/preload-pop.dir"
  $SSH comsys@${IPS[0]} "mkdir -p $PD && CXL_REGION_CONFIG=$VM_PLAIN/cfg/cxl_region.yaml setsid -w sh -c 'echo \$\$ > $PD/node0.pid; exec timeout $XT $VM_PLAIN/bin/recsys-server --node 0 --preload-only $SA --publish-ms $T_MS'" \
    < /dev/null > "$E/preload-pop.log" 2>&1
  echo "preload_wall_s=$(( $(date +%s) - t ))" >> "$E/preload-pop.log"
  { grep -q "PRELOAD DONE" "$E/preload-pop.log" && servers_gone; } || stop "preload"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable || stop "enable gate"
  for ip in "${IPS[@]}"; do
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    i=$($SSH comsys@$ip "cat /sys/kernel/swmc/instr/enabled" < /dev/null)
    echo "$ip recv_mode=$m instr_enabled=$i" >> "$E/recv-mode-pop.txt"
    [ "$m" = "$RECV_MODE" ] || stop "recv_mode on $ip = $m"
    [ "$i" = 1 ] || stop "instr enabled on $ip = $i"
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status || stop "status pre"
}
system() {  # one server lifetime: hw | pop | mg
  local s=$1 S=$E/$1 SE r rc g L t0
  t0=$(date +%s)
  echo "$(date -Is) system $s start"
  case $s in
    hw) dax_comsys; SE=(SYSTEM=all-HWcc V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=$XT");;
    mg) dax_comsys; SE=(SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:XTIMEOUT=$XT" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    mgoff) dax_comsys; SE=(SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MB/bin/recsys-server "SERVER_ARGS=--backend megalon $SA"
                        "NODE_ENV=ENV:RACKOBJ_CONFIG=$VM_MEG/cfg/megalon.yaml ENV:MEGALON_COH_TIMERS=0 ENV:XTIMEOUT=$XT" "NODE0_ENV=ENV:MEGALON_REINIT=1");;
    pop) dax_root; pop_setup
         SE=(SYSTEM=Popcorn-$RECV_MODE V=$VM_PLAIN HOST_SERVER=$HOST_PLAIN "SERVER_ARGS=$SA" NODE0_ARGS=--preloaded "NODE_ENV=ENV:XTIMEOUT=$XT");;
  esac
  servers_gone || stop "a recsys-server runs before $s"
  env "${SE[@]}" T_MS=$T_MS bash $X/session.sh start "$S" > "$S.start.out" 2>&1 || { tail -3 "$S.start.out"; stop "$s session start"; }
  tail -1 "$S.start.out"
  echo "$s prepare_wall_s=$(( $(date +%s) - t0 )) (incl. page MSI shm load + preload)" >> "$E/load-times.txt"
  sed "s/^/$s /" "$S/load-times.txt" >> "$E/load-times.txt"
  # 1) warm-up (unmeasured): 1 query/s with the updater for 70 s (>= one T = 60 s publication round)
  measure "$S" warmup "${LGC[@]}" --opt seed=$((SEED + 100)) --seed $((SEED + 100)) --mode fixed --rates 1 \
    --warmup-s 10 --step-warmup-s 0 --step-measure-s 70 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s warm-up rc $rc"
  if [ $BLOCK = v1 ]; then  # validation window (reports/RECSYS-V1-packet.md §3)
    measure "$S" val "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates "$V1_RATE" \
      --step-warmup-s 5 --step-measure-s "$V1_WINDOW_S" --drain-s 10
    rc=$?
    [ $rc = 0 ] || stop "$s val rc $rc"
    python3 $X/v1_check.py "$S/val" $s | tee "$S/val/v1-check.txt" | tee -a "$E/v1-checks.txt"
    grep -q "^V1CHECK PASS" "$S/val/v1-check.txt" || stop "$s: $(cat "$S/val/v1-check.txt")"
    python3 $X/check_breakdown.py "$S/val" | tee "$S/val/breakdown-check.txt" | grep -q "^BREAKDOWN PASS" || stop "$s val: $(cat "$S/val/breakdown-check.txt")"
  else
  # 2) lowest load: 1 query/s, 60 s, no SLO abort
  measure "$S" gate "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates 1 \
    --step-warmup-s 3 --step-measure-s 60 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s gate measurement rc $rc"
  g=$(gatechk "$S/gate/loadgen/steps.jsonl")
  echo "$s gate 1 query/s: $g" | tee -a "$E/gate.txt"
  if [ $s = hw ]; then
    case "$g" in VALID*) ;; *) stop "all-HWcc lowest-load window invalid ($g)";; esac
    { echo "slo_ms=$SLO_MS pct=$SLO_PCT rule=$SLO_RULE"; echo "all-HWcc lowest-load window: $g"; } | tee "$E/slo.txt"
  else
    case "$g" in VALID*) ;; *) echo "MAIN NOTE $s lowest-load window invalid (recorded; the block continues): $g";; esac
  fi
  [ -n "$SLO_MS" ] || stop "no block SLO"
  # 3) SLO searches (block SLO)
  for r in $(seq 1 $ROUNDS); do
    measure "$S" slo-r$r "${LGC[@]}" --opt seed=$((SEED + r)) --seed $((SEED + r)) --slo query:$SLO_PCT:$SLO_MS --raw \
      --mode slo --start 1 --factor 1.5 --precision 0.05 --max-steps 20
    rc=$?
    grep -q 'workload_finish":"ok' "$S/slo-r$r/loadgen/summary.json" 2>/dev/null || stop "$s slo-r$r: loadgen workload finish (rc $rc)"
    if [ $rc = 1 ]; then
      note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$S/slo-r$r/loadgen/summary.json" 2>/dev/null)
      [ -n "$note" ] || stop "$s slo-r$r: loadgen rc 1 without a note"
      echo "MAIN NOTE $s slo-r$r: $note"
    elif [ $rc != 0 ]; then stop "$s slo-r$r rc $rc"; fi
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); c=s.get("confirm",{}); print(sys.argv[2], "note=%r" % s.get("note",""), "confirm_x_mean=%s sd=%s" % (c.get("x_mean"), c.get("x_sd")))' \
      "$S/slo-r$r/loadgen/summary.json" "$s slo-r$r" | tee -a "$E/slo-results.txt"
    if [ $s = hw ] && [ $r = 1 ] && [ "$FIXED" = 1 ]; then
      L=$(confirm_half "$S/slo-r1/loadgen/summary.json") || stop "no all-HWcc slo-r1 confirm result for L"
      echo "L = 0.5 x all-HWcc slo-r1 confirm mean (this block, Popcorn build $POP_BUILD, T = 60 s) = $L query/s" > "$E/fixed-load-L.txt"
    fi
  done
  # 4) fixed load L, 60 s, whole window (no SLO abort); FIXED=0 skips it (user 2026-10-16: the breakdown is taken
  #    from the SLO-search steps at the highest rate all systems ran; every step has its own stats window)
  if [ "$FIXED" = 1 ]; then
  L=$(sed -n 's/.* = \([0-9.]*\) query\/s$/\1/p' "$E/fixed-load-L.txt")
  [ -n "$L" ] || stop "no L"
  measure "$S" fixed "${LGC[@]}" --opt seed=$SEED --seed $SEED --raw --mode fixed --rates "$L" \
    --step-warmup-s 5 --step-measure-s 60 --drain-s 10
  rc=$?
  [ $rc = 0 ] || stop "$s fixed rc $rc"
  python3 $X/check_breakdown.py "$S/fixed" | tee "$S/fixed/breakdown-check.txt" | grep -q "^BREAKDOWN PASS" || stop "$s fixed: $(cat "$S/fixed/breakdown-check.txt")"
  else
  [ -s "$S/slo-r1/stats-steps.csv" ] || stop "$s slo-r1: no per-step stats (stats-steps.csv)"
  fi
  fi  # BLOCK
  bash $X/session.sh stop "$S" > "$S.stop.out" 2>&1 || { tail -5 "$S.stop.out"; stop "$s session stop / final checks"; }
  tail -1 "$S.stop.out"
  if [ $s = pop ]; then
    env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status
    servers_gone || stop "servers left (page MSI teardown not attempted)"
    env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown || stop "shm teardown"
    grep -q "teardown PASS" "$E/shm-pop/steps.log" || stop "no teardown PASS"
  fi
  servers_gone || stop "servers left after $s"
  echo "$(date -Is) MAIN $s DONE ($(( $(date +%s) - t0 )) s)"
}
echo "$(date -Is) block $OWNER start (git $(git -C $P/CXL_SWMC rev-parse --short HEAD)) K8=$K8 RECV_MODE=$RECV_MODE MEG_BUILD=$MB VM_PLAIN=$VM_PLAIN VM_MEG=$VM_MEG D=$D SEED=$SEED ROUNDS=$ROUNDS FIXED=$FIXED XT=$XT"
precheck
# update rate for the Ekko operating point (Host compute, after the host-gate lock and the
# input sha256 check in precheck): samples per T so that one round publishes PUBLISH_FRAC of all rows
RATEF=$E/sequence-update-rate.txt
nice -n 19 numactl --cpunodebind=1 --membind=1 "$PLAIN_BUILD/bin/recsys-rate" --samples "$D/$UPD_FILE" --frac $PUBLISH_FRAC \
  --t-ms $T_MS --windows 20 > "$RATEF" || stop "recsys-rate"
UPD_RATE=$(sed -n 's/^rate_samples_per_s=//p' "$RATEF")
awk -v x="$UPD_RATE" 'BEGIN{exit !(x > 0)}' || stop "bad update rate $UPD_RATE"
if [ -n "${V1_EXPECT_RATE:-}" ]; then  # the packet's expected rate (Host calibration, builds/recsys-inputs/1/rate-frac*.txt)
  awk -v x="$UPD_RATE" -v y="$V1_EXPECT_RATE" 'BEGIN{exit !(x >= 0.98 * y && x <= 1.02 * y)}' \
    || stop "update rate $UPD_RATE differs from the expected $V1_EXPECT_RATE by more than 2%"
fi
echo "EKKO=$EKKO publish_frac=$PUBLISH_FRAC update_rate=$UPD_RATE samples/s ($EKKO_RULE; $RATEF)"
LGC=(--opt samples=$D/$UPD_FILE --opt queries=$D/$QRY_FILE --opt wrap=1
     --opt quantiles=$D/dist_quantile.txt --fixed update=$UPD_RATE --mix query=1 --x-stream query)
if [ $BLOCK = main ] && [[ " ${SYSTEMS:-hw pop mg} " != *" hw "* ]]; then
  echo "slo_ms=$SLO_MS pct=$SLO_PCT rule=$SLO_RULE (fixed; no all-HWcc in this block)" | tee "$E/slo.txt"
  [ -z "${L_FROM:-}" ] || { cp "$L_FROM" "$E/fixed-load-L.txt" && echo "L imported from $L_FROM: $(cat "$E/fixed-load-L.txt")"; }
fi
if [ $BLOCK = v1 ]; then ORDER="hw pop mg mgoff"; else ORDER="hw $(shuffle pop mg)"; fi
echo "system order: $ORDER (all-HWcc first; page MSI / Megalon shuffled with seed $OWNER)" | tee "$E/order.txt"
if [ -n "${SYSTEMS:-}" ]; then  # subset rerun: keep the seeded order, drop the others
  O2=""; for s in $ORDER; do [[ " $SYSTEMS " == *" $s "* ]] && O2="$O2 $s"; done; ORDER=${O2# }
  echo "SYSTEMS=\"$SYSTEMS\" -> run: $ORDER" | tee -a "$E/order.txt"
fi
for s in $ORDER; do system $s; done
echo "$(date -Is) SEQUENCE DONE $OWNER"
