#!/bin/bash
# One RocksDB run (reports/ROCKSDB-V1-packet.md; H2 all-HWcc vs Popcorn, H3 Popcorn on N = 2/4/8 VMs): Host gate,
# Popcorn cycle (as experiments/lmdb/pilot-run.sh), run.sh, post checks.
# YCSB keys (24 B), value 1,000 B (+ 8 B stamp stored), ScrambledZipfian 0.99; request = one get or one update
# (mixed stream: update with probability UPDATE_RATIO); SLO per request mixed p99 < 1 ms (as kv/lmdb).
# usage: pilot-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Popcorn), UPDATE_RATIO (0.05 | 0.5 | 0.8), KIND:
#   functional  fixed RATES (total, default 200,1000), 30 s windows, LOG=1 recommended (check_log)
#   slo         SLO search with the KV/LMDB H1 loadgen arguments (precision 0.02, confirm 0.01, max 6 confirm probes,
#               step-down 0.05; fill 0.7,0.8,0.9; overload 1.05,1.1,1.2)
#   fix         PER_VM_RATES=r1[,r2..] (requests/s per VM; total = N x r): fixed 30 s windows after 10 s warm-up, no SLO
#               abort (judged after); H3: every N at the same per-VM rate (= the 2-VM Popcorn L2)
#   SYS=Popcorn: C8 (deploy bundle dir with p-popcorn-shm.sh), K8 (release), GT8 (guest tools dir), RECV_MODE
#   (poll | idle | sleep); cxl_shm loaded and coherence ENABLED (init_state=shared) before the servers start, so the
#   image build runs under coherence. LOCK_OWNER: the calling block's measurement lock.
# optional: NODES ("192.168.122.100 192.168.122.101"; N = count; p-popcorn-shm.sh must cover the same VMs), KEYS
#   (54000000), THREADS (server request workers per node, 4), PREPARE_THREADS (4), FILE_EXTENTS (0 = rest of share),
#   SEED (20261018), LOG (0), GATE (1), V (/home/comsys/rocksdb3), BUILD (builds/rocksdb/3), LOADGEN_BUILD
#   (builds/rocksdb-loadgen/1), STOP_EXTENTS_FREE / STOP_BLOCKS_FREE (run.sh), SERVER_CPUS, READY_TIMEOUT (7200).
# Prints "PILOTRUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE, 1 for STOP.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
NAME=$1 E=$2
P=/home/comsys/sungsu/destijl-control
X=$P/CXL_SWMC/experiments/rocksdb
: "${SYS:?}" "${UPDATE_RATIO:?}" "${KIND:?}"
read -r -a IPS <<< "${NODES:-192.168.122.100 192.168.122.101}"
N=${#IPS[@]}
KEYS=${KEYS:-54000000} THREADS=${THREADS:-4} PREPARE_THREADS=${PREPARE_THREADS:-4} FILE_EXTENTS=${FILE_EXTENTS:-0}
SEED=${SEED:-20261018} LOG=${LOG:-0}
V=${V:-/home/comsys/rocksdb3} BUILD=${BUILD:-$P/builds/rocksdb/3} LOADGEN_BUILD=${LOADGEN_BUILD:-$P/builds/rocksdb-loadgen/1}
stop() { echo "PILOTRUN $NAME STOP $*"; exit 1; }
[ -d "$E" ] || stop "missing evidence dir $E"
[ -e "$E/$NAME" ] && stop "$E/$NAME exists"
[[ $UPDATE_RATIO =~ ^(0\.05|0\.5|0\.8)$ ]] || stop "bad UPDATE_RATIO"
[[ $KEYS =~ ^[1-9][0-9]*$ ]] && [[ $THREADS =~ ^[1-9][0-9]*$ ]] || stop "bad KEYS/THREADS"
[[ $LOG =~ ^[01]$ ]] && [[ ${GATE:-1} =~ ^[01]$ ]] || stop "bad LOG/GATE"
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed only with KIND=functional"
[ "$N" -ge 2 ] && [ "$N" -le 8 ] || stop "NODES must list 2..8 VMs"
SA="--nodes $N --keys $KEYS --threads $THREADS --prepare-threads $PREPARE_THREADS --start-timeout-ms 7200000"
[ "$FILE_EXTENTS" = 0 ] || SA="$SA --file-extents $FILE_EXTENTS"
export LOADGEN=$LOADGEN_BUILD/loadgen READY_TIMEOUT=${READY_TIMEOUT:-7200} STATS_OP=10 V NODES="${IPS[*]}"
export HOST_SERVER=$BUILD/bin/rocksdb-server SERVER_ARGS="$SA --backend plain"
RUN_KIND=${RUN_KIND:-measurement}; [ "$KIND" = functional ] && RUN_KIND=functional
export RUN_KIND
case "$SYS" in
  all-HWcc) export SYSTEM=all-HWcc;;
  Popcorn)  : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
            [[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || stop "bad RECV_MODE"
            export SYSTEM=Popcorn-$RECV_MODE;;
  *) stop "bad SYS";;
esac
LG=(--opt keys=$KEYS --opt update_ratio=$UPDATE_RATIO --opt seed=$SEED --seed "$SEED" --opt log=$LOG --mix mixed=1
    --x-stream mixed)
case "$KIND" in
  functional) unset PER_VM_RATES; LG+=(--slo mixed:99:600000 --mode fixed --rates "${RATES:-200,1000}" --warmup-s 10 --step-warmup-s 5
                   --step-measure-s 30 --drain-s 10);;
  slo) unset PER_VM_RATES; LG+=(--slo mixed:99:1 --raw --mode slo --start 500 --factor 1.5 --precision 0.02 --confirm-precision 0.01
            --max-confirm-probes 6 --confirm-step-down 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3
            --step-measure-s 15 --drain-s 5 --confirm-s 30 --confirm-reps 3 --fill 0.7,0.8,0.9 --overload 1.05,1.1,1.2);;
  fix) [[ ${PER_VM_RATES:?fix needs PER_VM_RATES} =~ ^[0-9]+(\.[0-9]+)?(,[0-9]+(\.[0-9]+)?)*$ ]] || stop "bad PER_VM_RATES"
       export PER_VM_RATES  # run.sh adds --mode fixed --rates N x r
       LG+=(--slo mixed:99:600000 --raw --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  *) stop "bad KIND";;
esac
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
PAT='(^|[ /])bin/rocksdb-serve[r]( |$)'
servers_gone() {  # no rocksdb-server of ours and /dev/dax0.0 unused on every VM (fail-closed)
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "echo procs=\$(pgrep -c -u comsys -f '$PAT') fuser=[\$(sudo -n fuser /dev/dax0.0 2>&1 | tr -d ' \n')]" < /dev/null 2>&1)
    [ "$out" = "procs=0 fuser=[]" ] || { echo "$ip: $out" >&2; return 1; }
  done
}
echo "$(date -Is) $NAME: SYS=$SYS N=$N UPDATE_RATIO=$UPDATE_RATIO KIND=$KIND PER_VM_RATES=${PER_VM_RATES:-} KEYS=$KEYS LOG=$LOG SEED=$SEED"
servers_gone || stop "a rocksdb-server is running before the run"
LOCKF=$P/workspaces/MEASUREMENT.lock
grep -q "^owner=${LOCK_OWNER:?LOCK_OWNER = owner of the measurement lock held by the calling block} " "$LOCKF" 2>/dev/null \
  || stop "measurement lock not held by $LOCK_OWNER ($(cat "$LOCKF" 2>/dev/null))"
if [ "${GATE:-1}" = 1 ]; then
  if [ "${H1_MEASURE_RUN:-0}" = 1 ]; then
    : "${MEASURE_PART_DIR:?H1_MEASURE_RUN=1 needs MEASURE_PART_DIR}"
    bash $P/CXL_SWMC/experiments/h1/h1-gate.sh check "$E/gate-$NAME.txt" || stop "h1 gate"
  else
    bash $P/CXL_SWMC/experiments/vectordb/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"
  fi
fi
T0=$(date +%s)
if [ "$SYS" = Popcorn ]; then  # as experiments/lmdb/pilot-run.sh: enable BEFORE the servers
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
  servers_gone || stop "rocksdb process or /dev/dax0.0 user before the cxl_shm load"
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
{ echo "# load times $NAME (s)"; echo "run_wall_s=$(( $(date +%s) - T0 ))"; grep -h "^node[0-9]* .*IMAGE" $R/manifest.txt
  grep -h "^start=\|^end=" $R/manifest.txt; } > $R/load-times.txt
grep -q "^check: PASS$" $R/check.txt 2>/dev/null || stop "server checks (check.txt): $(grep '^FAIL' $R/check.txt 2>/dev/null | head -3 | tr '\n' ';')"
for kv in not_found=0 errors=0 bad_values=0 stale_reads=0; do grep -q "^$kv\$" $R/loadgen/rocksdb.txt || stop "value check: $kv violated"; done
grep -q "workload_finish\":\"ok" $R/loadgen/summary.json || stop "loadgen workload finish"
if [ $RC != 0 ]; then
  note=$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' $R/loadgen/summary.json 2>/dev/null)
  [ "$KIND" = slo ] && [[ "$note" == *"confirm failed at three rates"* ]] && { echo "PILOTRUN $NAME NOTE $note"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
[ "$LOG" = 1 ] && { grep -q "^check_log rc=0$" $R/check-log.txt || stop "check_log"; }
[ -s $R/stats-steps.csv ] && [ "$(wc -l < $R/stats-steps.csv)" -ge 2 ] || stop "no stats-steps.csv rows"
if [[ $KIND =~ ^(fix|functional)$ ]]; then  # per-step table; an aborted fixed step is a NOTE
  python3 -B - $R/loadgen/steps.jsonl "$N" > $R/ladder-result.txt <<'EOP' || stop "fixed steps result"
import json, sys
n = int(sys.argv[2])
st = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
st = [s for s in st if s["phase"] == "fixed"]
print("step offered_x per_vm_x achieved p50_ms p90_ms p99_ms max_ms done aborted reason")
for s in st:
    m = s["streams"]["mixed"]
    print(s["step"], s["offered_x"], round(s["offered_x"] / n, 3), m["achieved"], m["p50_ms"], m.get("p90_ms"), m["p99_ms"],
          m["max_ms"], m.get("done"), str(s["aborted"]).lower(), (s["reason"] or "-").replace(" ", "_"))
EOP
  cat $R/ladder-result.txt
  awk 'NR>1 && $10=="true"' $R/ladder-result.txt | grep -q . && { echo "PILOTRUN $NAME NOTE $KIND step aborted"; exit 0; }
fi
echo "PILOTRUN $NAME OK"
