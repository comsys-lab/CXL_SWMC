#!/bin/bash
# One KV pilot run (reports/M5-pilot-kv.md, MOT1 v5 pilots): Host gate, system setup, run.sh, post checks.
# 4M keys, 1 KiB values, Zipfian 0.99, requests of BATCH mixed ops (each op a put with probability PUT_RATIO),
# SLO per request mixed p99 <= 1 ms.
# usage: pilot-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Megalon | Popcorn), PUT_RATIO (0 | 0.05 | 0.5), KIND (functional | pslo | slo | pfix |
#   ptrace); slo = the full MOT1 v5 §3.3 SLO search (main runs, reports/KV-main-packet.md: 10 s warm-up, steps 3 s +
#   15 s, adaptive ramp from 500 req/s, bisect to 5 %, confirm 3 x 30 s with up to two -5 % step-downs, fill 0.7/0.8/0.9
#   x result, overload 1.05/1.1/1.2 x first fail; every measured step has a stats snapshot pair); fix = one fixed-load
#   window at RATE (10 s run warm-up, 5 s step warm-up, 30 s measured, stats snapshots) with NO SLO abort: loadgen gets
#   --slo mixed:99:600000 so only the saturation (outstanding) abort can end the window early; p99 is recorded and the
#   1 ms SLO is judged here (fix-result.txt: slo_1ms_pass), an aborted window is a NOTE with its reason; KIND=pfix|ptrace: RATE (requests/s = L). ptrace = a pfix window with TRACE=1 (put/get logs for the
#   Figure 2c classification only; never used for throughput/latency comparisons). pfix forces TRACE=0.
#   SYS=Popcorn: C8 (build-8 deploy bundle dir), K8 (release), GT8 (guest tools dir), RECV_MODE (poll | idle | sleep)
# optional: KEYS (4000000), BATCH (16), SEED (20261016), GATE=0 (skip the Host gate: functional runs only),
#   VM_PLAIN (/home/comsys/kv3), VM_MEG (/home/comsys/kvm3), PLAIN_BUILD (builds/kv/3), MEG_BUILD (builds/kv-megalon/3),
#   LOADGEN_BUILD (builds/kv-loadgen/3).
# Page MSI (user decision A, 2026-10-16): cxl_shm is loaded and coherence ENABLED before kv-server starts, so node 0's
# initial load and every warm-up read run under coherence (no --preload-only: the store's index replicas are
# process-local). init_state=shared, as for the other workloads' page MSI runs.
# Prints "PILOTRUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE, 1 for STOP (the sequence stops).
set -uo pipefail
NAME=$1 E=$2
P=/home/comsys/sungsu/destijl-control
X=$P/CXL_SWMC/experiments/kv
: "${SYS:?}" "${PUT_RATIO:?}" "${KIND:?}"
KEYS=${KEYS:-4000000} BATCH=${BATCH:-16} SEED=${SEED:-20261016}
TRACE=0; [ "$KIND" = ptrace ] && TRACE=1
VM_PLAIN=${VM_PLAIN:-/home/comsys/kv3} VM_MEG=${VM_MEG:-/home/comsys/kvm3}
PLAIN_BUILD=${PLAIN_BUILD:-$P/builds/kv/3} MEG_BUILD=${MEG_BUILD:-$P/builds/kv-megalon/3}
LOADGEN_BUILD=${LOADGEN_BUILD:-$P/builds/kv-loadgen/3}
stop() { echo "PILOTRUN $NAME STOP $*"; exit 1; }
[ -d "$E" ] || stop "missing evidence dir $E"
[ -e "$E/$NAME" ] && stop "$E/$NAME exists"
[[ $PUT_RATIO =~ ^(0|0\.05|0\.2|0\.5)$ ]] || stop "bad PUT_RATIO"
[[ $BATCH =~ ^(16|32|64)$ ]] || stop "bad BATCH"
[[ $KEYS =~ ^[1-9][0-9]*$ ]] || stop "bad KEYS"
SA="--nodes 2 --keys $KEYS --threads 14 --start-timeout-ms 5400000"
export LOADGEN=$LOADGEN_BUILD/loadgen READY_TIMEOUT=5400 RUN_KIND=measurement STATS_OP=10 TRACE
[ "$KIND" = functional ] && RUN_KIND=functional
export RUN_KIND
case "$SYS" in
  all-HWcc) export SYSTEM=all-HWcc V=$VM_PLAIN HOST_SERVER=$PLAIN_BUILD/bin/kv-server SERVER_ARGS="$SA --backend plain";;
  Megalon)  export SYSTEM=Megalon V=$VM_MEG HOST_SERVER=$MEG_BUILD/bin/kv-server SERVER_ARGS="$SA --backend megalon";;
  Popcorn)  : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
            [[ $RECV_MODE =~ ^(poll|idle|sleep)$ ]] || stop "bad RECV_MODE"
            export SYSTEM=Popcorn-$RECV_MODE V=$VM_PLAIN HOST_SERVER=$PLAIN_BUILD/bin/kv-server SERVER_ARGS="$SA --backend plain";;
  *) stop "bad SYS";;
esac
export NODE_ENV="ENV:XTIMEOUT=14400"
SLO_ARG=mixed:99:1; [ "$KIND" = fix ] && SLO_ARG=mixed:99:600000  # fix: no SLO abort (judged after the run)
LG=(--opt keys=$KEYS --opt batch=$BATCH --opt put_ratio=$PUT_RATIO --opt seed=$SEED --seed "$SEED" --mix mixed=1
    --slo $SLO_ARG --x-stream mixed)
case "$KIND" in
  functional) LG+=(--mode fixed --rates 200,2000 --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  pslo) LG+=(--raw --mode slo --start 500 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 2
             --step-measure-s 8 --confirm-s 15 --confirm-reps 1 --fill none --overload none);;
  slo) LG+=(--raw --mode slo --start 500 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3
            --step-measure-s 15 --drain-s 5 --confirm-s 30 --confirm-reps 3 --fill 0.7,0.8,0.9 --overload 1.05,1.1,1.2);;
  pfix|ptrace|fix) : "${RATE:?}"; LG+=(--raw --mode fixed --rates "$RATE" --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  *) stop "bad KIND";;
esac
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
servers_gone() { for ip in "${IPS[@]}"; do [ "$($SSH comsys@$ip 'pgrep -c -x kv-server' < /dev/null)" = 0 ] || return 1; done; }
echo "$(date -Is) $NAME: SYS=$SYS PUT_RATIO=$PUT_RATIO KIND=$KIND RATE=${RATE:-} BATCH=$BATCH KEYS=$KEYS TRACE=$TRACE RECV_MODE=${RECV_MODE:-} SEED=$SEED"
servers_gone || stop "a kv-server is running before the run"
if [ "${GATE:-1}" = 1 ]; then bash $P/CXL_SWMC/experiments/vectordb/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"; fi
T0=$(date +%s)
if [ "$SYS" = Popcorn ]; then  # P-popcorn-deploy §6a cycle with build 8; enable BEFORE the server (load under coherence)
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
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
  grep -q "kv-server: stopping" $L || stop "node$k: no clean stop"
  for kv in misses=0 short_reads=0 bad_requests=0; do grep -q "^$kv\$" $L || stop "node$k: $kv violated"; done
  # Megalon: no record reclaim at all (sizing keeps every loaded key under the watermark; reports/M5-pilot-kv.md §1)
  [ "$SYS" = Megalon ] && { grep -q "^megalon.wmeta_reclaim=0\$" $L || stop "node$k: Megalon record reclaim (record pressure)"; }
done
for kv in torn=0 wrong_key=0 bad_writer=0 future=0 stale=0 misses=0 get_errors=0 put_errors=0; do
  grep -q "^$kv\$" $R/loadgen/kv.txt || stop "value check: $kv violated"
done
[ "$TRACE" = 1 ] && { grep -q "KVLOG CHECK PASS" $R/kvlog-check.txt || stop "trace log check"; }
{ echo "# load times $NAME (s)"; echo "run_wall_s=$(( $(date +%s) - T0 ))"
  grep -h "loaded .* keys\|warm-up read\|megalon counters\|slot scan\|SCR used\|READY node" $R/node*.log
  grep -h "^start=\|^end=" $R/manifest.txt; } > $R/load-times.txt
grep -q "workload_finish\":\"ok" $R/loadgen/summary.json || stop "loadgen workload finish"
if [ $RC != 0 ]; then
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' $R/loadgen/summary.json 2>/dev/null)
  [[ $KIND =~ ^p?slo$ ]] && [ -n "$note" ] && { echo "PILOTRUN $NAME NOTE $note"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
[ "$KIND" = functional ] && ! grep -q '"pass":true' $R/loadgen/steps.jsonl && stop "functional step not PASS"
# every run: a non-empty per-step stats table (stats snapshots of every measured step; verifier LOW-1)
[ -s $R/stats-steps.csv ] && [ "$(wc -l < $R/stats-steps.csv)" -ge 2 ] || stop "no stats-steps.csv rows"
if [ "$KIND" = fix ]; then
  python3 - $R/loadgen/steps.jsonl > $R/fix-result.txt <<'PY' || stop "fixed window result"
import json, sys
st = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
st = [s for s in st if s["phase"] == "fixed"]
assert len(st) == 1, "expected one fixed step"
s = st[0]; m = s["streams"]["mixed"]
print("offered_x=%s\nachieved_x=%s\np50_ms=%s\np99_ms=%s\nmax_ms=%s\nerrors=%s\ntimeouts=%s\naborted=%s\nreason=%s" % (
    s["offered_x"], m["achieved"], m["p50_ms"], m["p99_ms"], m["max_ms"], m["errors"], m["timeouts"],
    str(s["aborted"]).lower(), s["reason"]))
print("slo_1ms_pass=%s" % str((not s["aborted"]) and m["p99_ms"] <= 1.0).lower())
PY
  tr '\n' ' ' < $R/fix-result.txt; echo
  grep -q "^aborted=true" $R/fix-result.txt && { echo "PILOTRUN $NAME NOTE fixed window aborted: $(sed -n 's/^reason=//p' $R/fix-result.txt)"; exit 0; }
fi
echo "PILOTRUN $NAME OK"
