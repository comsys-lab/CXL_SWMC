#!/bin/bash
# One LMDB run (MOT1 v6 H1, reports/MOT1-v6-redesign-draft.md §1-3): Host gate, run.sh, post checks.
# YCSB records (key 24 B, value 1,000 B, ScrambledZipfian 0.99), requests = one get or one update (mixed stream: an
# update with probability UPDATE_RATIO), SLO per request mixed p99 < 1 ms (user decision 2026-10-16).
# Mixes (MOT1 v6): get/update 95/5 = 0.05 (YCSB B), 50/50 = 0.5 (YCSB A), 20/80 = 0.8 (Twitter OSDI'20); 0 = get only.
# usage: pilot-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Megalon), UPDATE_RATIO (0 | 0.05 | 0.5 | 0.8), KIND (functional | pslo | slo | fix |
#   ladder; same loadgen schedules as experiments/kv/pilot-run.sh; fix: RATE, ladder: RATES).
#   SYS=Popcorn (plain backend, Popcorn build >= 10): C8 (deploy bundle dir with p-popcorn-shm.sh), K8 (release), GT8
#   (guest tools dir), RECV_MODE (poll | idle | sleep). As the KV pilot: cxl_shm loaded and coherence ENABLED
#   (init_state=shared) before lmdb-server starts, so node 0's image copy and every warm-up read run under coherence (no
#   --preload-only); /dev/dax0.0 must be root:root 600 before (p-popcorn-shm.sh chown/teardown own it).
# optional: RECORDS (1000000), MAX_PAGES (600000), GET_THREADS (8), READERS (32), PREPARE_THREADS (Megalon node 0: 8),
#   SEED (20261016), LOG (0; 1 = loadgen log=1 + check_log.py, functional runs), GATE=0 (skip the Host gate; refused
#   unless KIND=functional), VM_PLAIN (/home/comsys/lmdb/plain), VM_MEG (/home/comsys/lmdb/megalon), IMAGE
#   (/home/comsys/lmdb/img-$RECORDS on node 0), PLAIN_BUILD (builds/lmdb/7), MEG_BUILD (builds/lmdb-megalon/7, Megalon 75),
#   LOADGEN_BUILD (builds/lmdb-loadgen/6), RUN_KIND override. LOCK_OWNER (required): the calling block must hold the
#   measurement lock (experiments/vectordb/host-gate.sh lock <owner>); refused otherwise.
# Prints "PILOTRUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE, 1 for STOP.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # never write __pycache__ (harness snapshots live in recovery/); every python3 call also has -B
NAME=$1 E=$2
P=/home/comsys/sungsu/destijl-control
X=$P/CXL_SWMC/experiments/lmdb
: "${SYS:?}" "${UPDATE_RATIO:?}" "${KIND:?}"
RECORDS=${RECORDS:-1000000} MAX_PAGES=${MAX_PAGES:-600000} GET_THREADS=${GET_THREADS:-8} READERS=${READERS:-32}
SEED=${SEED:-20261016} LOG=${LOG:-0} PREPARE_THREADS=${PREPARE_THREADS:-8}
VM_PLAIN=${VM_PLAIN:-/home/comsys/lmdb/plain} VM_MEG=${VM_MEG:-/home/comsys/lmdb/megalon}
IMAGE=${IMAGE:-/home/comsys/lmdb/img-$RECORDS}
PLAIN_BUILD=${PLAIN_BUILD:-$P/builds/lmdb/7} MEG_BUILD=${MEG_BUILD:-$P/builds/lmdb-megalon/7}
LOADGEN_BUILD=${LOADGEN_BUILD:-$P/builds/lmdb-loadgen/6}
stop() { echo "PILOTRUN $NAME STOP $*"; exit 1; }
[ -d "$E" ] || stop "missing evidence dir $E"
[ -e "$E/$NAME" ] && stop "$E/$NAME exists"
[[ $UPDATE_RATIO =~ ^(0|0\.05|0\.5|0\.8)$ ]] || stop "bad UPDATE_RATIO"
[[ $RECORDS =~ ^[1-9][0-9]*$ ]] && [[ $MAX_PAGES =~ ^[1-9][0-9]*$ ]] || stop "bad RECORDS/MAX_PAGES"
[[ $LOG =~ ^[01]$ ]] || stop "bad LOG"
[[ ${GATE:-1} =~ ^[01]$ ]] || stop "bad GATE"
# GATE=0 skips the whole Host gate (incl. the measure-env check): functional runs only
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed only with KIND=functional (KIND=$KIND)"
SA="--nodes 2 --records $RECORDS --max-pages $MAX_PAGES --readers $READERS --get-threads $GET_THREADS --start-timeout-ms 3600000"
export LOADGEN=$LOADGEN_BUILD/loadgen READY_TIMEOUT=3600 STATS_OP=10 IMAGE
RUN_KIND=${RUN_KIND:-measurement}; [ "$KIND" = functional ] && RUN_KIND=functional
export RUN_KIND
case "$SYS" in
  all-HWcc) export SYSTEM=all-HWcc V=$VM_PLAIN HOST_SERVER=$PLAIN_BUILD/bin/lmdb-server SERVER_ARGS="$SA --backend plain";;
  Megalon)  export SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MEG_BUILD/bin/lmdb-server SERVER_ARGS="$SA --backend megalon"
            export NODE0_ARGS="--prepare-threads $PREPARE_THREADS";;
  Popcorn)  : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
            [[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || stop "bad RECV_MODE"
            export SYSTEM=Popcorn-$RECV_MODE V=$VM_PLAIN HOST_SERVER=$PLAIN_BUILD/bin/lmdb-server SERVER_ARGS="$SA --backend plain";;
  *) stop "bad SYS";;
esac
# COH_TIMERS=0|1 (optional, Megalon only): MEGALON_COH_TIMERS for both nodes (timers-off lifetime of the C_diff
#   method, user decision 2026-10-17; recorded in the run manifest via node_env)
[ -z "${COH_TIMERS:-}" ] || { [[ $COH_TIMERS =~ ^[01]$ ]] && [ "$SYS" = Megalon ]; } || stop "COH_TIMERS=0|1 is for SYS=Megalon only"
[ -z "${COH_TIMERS:-}" ] || export NODE_ENV="ENV:MEGALON_COH_TIMERS=$COH_TIMERS"
SLO_ARG=mixed:99:1; [[ $KIND =~ ^(fix|ladder)$ ]] && SLO_ARG=mixed:99:600000  # fix, ladder: no SLO abort (judged after)
LG=(--opt records=$RECORDS --opt update_ratio=$UPDATE_RATIO --opt seed=$SEED --opt log=$LOG --seed "$SEED" --mix mixed=1
    --slo $SLO_ARG --x-stream mixed)
case "$KIND" in
  functional) LG+=(--mode fixed --rates ${RATES:-200,1000} --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  pslo) LG+=(--raw --mode slo --start 500 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 2
             --step-measure-s 8 --confirm-s 15 --confirm-reps 1 --fill none --overload none);;
  slo) LG+=(--raw --mode slo --start 500 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3
            --step-measure-s 15 --drain-s 5 --confirm-s 30 --confirm-reps 3 --fill 0.7,0.8,0.9 --overload 1.05,1.1,1.2);;
  ladder) [[ ${RATES:?} =~ ^[0-9]+(,[0-9]+)*$ ]] || stop "bad RATES"
          LG+=(--raw --mode fixed --rates "$RATES" --warmup-s 10 --step-warmup-s 3 --step-measure-s 15 --drain-s 5);;
  fix) : "${RATE:?}"; LG+=(--raw --mode fixed --rates "$RATE" --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  *) stop "bad KIND";;
esac
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
# no lmdb process of ours (command line, not name: Megalon renames the main thread "megalon-lib" while it loads) and
# /dev/dax0.0 unused (sudo -n fuser output empty; fail-closed) on both VMs; used before/after each run and before the
# Popcorn cxl_shm load and teardown
PAT='(^|[ /])bin/lmdb-(serve[r]|stres[s])( |$)'
servers_gone() {
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "echo procs=\$(pgrep -c -u comsys -f '$PAT') fuser=[\$(sudo -n fuser /dev/dax0.0 2>&1 | tr -d ' \n')]" < /dev/null 2>&1)
    [ "$out" = "procs=0 fuser=[]" ] || { echo "$ip: $out" >&2; return 1; }
  done
}
echo "$(date -Is) $NAME: SYS=$SYS UPDATE_RATIO=$UPDATE_RATIO KIND=$KIND RATE=${RATE:-} RECORDS=$RECORDS MAX_PAGES=$MAX_PAGES LOG=$LOG SEED=$SEED"
servers_gone || stop "an lmdb-server is running before the run"
# the caller (f1-block.sh or a later block) holds the measurement/VM lock for the whole block (host-gate.sh lock)
LOCKF=$P/workspaces/MEASUREMENT.lock
grep -q "^owner=${LOCK_OWNER:?LOCK_OWNER = owner of the measurement lock held by the calling block} " "$LOCKF" 2>/dev/null \
  || stop "measurement lock not held by $LOCK_OWNER ($(cat "$LOCKF" 2>/dev/null))"
if [ "${GATE:-1}" = 1 ]; then bash $P/CXL_SWMC/experiments/vectordb/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"; fi
T0=$(date +%s)
if [ "$SYS" = Popcorn ]; then  # same cycle as experiments/kv/pilot-run.sh; enable BEFORE the servers
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
  servers_gone || stop "lmdb process or /dev/dax0.0 user before the cxl_shm load"
  for ph in precheck load chown; do env "${PS[@]}" bash $C8/p-popcorn-shm.sh $ph || stop "shm $ph"; done
  for ip in "${IPS[@]}"; do
    [ "$($SSH comsys@$ip "sha256sum $V/cfg/cxl_region.yaml $GT8/cxl_region.yaml | cut -d' ' -f1 | sort -u | wc -l" < /dev/null)" = 1 ] \
      || { env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown; stop "region config differs on $ip"; }
  done
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh enable || { env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown; stop "enable gate"; }
  for ip in "${IPS[@]}"; do
    m=$($SSH comsys@$ip "sudo -n sh -c 'echo $RECV_MODE > /sys/module/cxl_shm/parameters/recv_mode' && cat /sys/module/cxl_shm/parameters/recv_mode" < /dev/null)
    echo "$ip recv_mode=$m" >> "$E/recv-mode-$NAME.txt"
    [ "$m" = "$RECV_MODE" ] || { env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown; stop "recv_mode on $ip = $m"; }
  done
  env "${PS[@]}" STATUS_TAG=pre bash $C8/p-popcorn-shm.sh status || { env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown; stop "status pre"; }
fi
bash $X/run.sh "$NAME" "$E" -- "${LG[@]}"
RC=$?
if [ "$SYS" = Popcorn ]; then
  env "${PS[@]}" STATUS_TAG=post bash $C8/p-popcorn-shm.sh status
  servers_gone || stop "servers left (Popcorn teardown not attempted)"
  env "${PS[@]}" bash $C8/p-popcorn-shm.sh teardown || stop "shm teardown"
fi
servers_gone || stop "servers left"
R=$E/$NAME
[ -d "$R" ] || stop "no run dir"
for k in 0 1; do  # clean stop and the workload's own invariants
  L=$R/node$k.log
  grep -q "lmdb-server: stopping" $L || stop "node$k: no clean stop"
  for kv in get_not_found=0 get_errors=0 update_not_found=0 update_errors=0; do grep -q "^$kv\$" $L || stop "node$k: $kv violated"; done
done
for kv in not_found=0 errors=0 bad_values=0 stale_snapshots=0; do grep -q "^$kv\$" $R/loadgen/lmdb.txt || stop "value check: $kv violated"; done
{ echo "# load times $NAME (s)"; echo "run_wall_s=$(( $(date +%s) - T0 ))"
  grep -h "loaded image\|published\|warm-up read\|READY node\|opsplit" $R/node*.log; grep -h "^start=\|^end=" $R/manifest.txt; } > $R/load-times.txt
grep -q "workload_finish\":\"ok" $R/loadgen/summary.json || stop "loadgen workload finish"
if [ $RC != 0 ]; then
  note=$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' $R/loadgen/summary.json 2>/dev/null)
  [[ $KIND =~ ^p?slo$ ]] && [ -n "$note" ] && { echo "PILOTRUN $NAME NOTE $note"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
[ "$KIND" = functional ] && ! grep -q '"pass":true' $R/loadgen/steps.jsonl && stop "functional step not PASS"
[ "$LOG" = 1 ] && { grep -q "^check_log rc=0$" $R/check-log.txt || stop "check_log"; }
[ -s $R/stats-steps.csv ] && [ "$(wc -l < $R/stats-steps.csv)" -ge 2 ] || stop "no stats-steps.csv rows"
[ -s $R/opsplit.csv ] && [ "$(wc -l < $R/opsplit.csv)" -ge 2 ] || stop "no opsplit.csv rows"
echo "PILOTRUN $NAME OK"
