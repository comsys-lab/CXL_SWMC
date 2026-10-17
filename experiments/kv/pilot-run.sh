#!/bin/bash
# One KV pilot run (reports/M5-pilot-kv.md, MOT1 v5 pilots): Host gate, system setup, run.sh, post checks.
# 4M keys, 1 KiB values, Zipfian 0.99, requests of BATCH mixed ops (each op a put with probability PUT_RATIO),
# SLO per request mixed p99 <= 1 ms.
# usage: pilot-run.sh <name> <evidence dir>
# env (required): SYS (all-HWcc | Megalon | Popcorn), PUT_RATIO (0 | 0.05 | 0.2 | 0.5 | 0.8; MOT1 v6 H1 mixes get/put
#   95/5 = 0.05, 50/50 = 0.5, 20/80 = 0.8), KIND (functional | pslo | slo | pfix |
#   ptrace); slo = the full MOT1 v5 §3.3 SLO search (main runs, reports/KV-main-packet.md: 10 s warm-up, steps 3 s +
#   15 s, adaptive ramp from 500 req/s, bisect to 5 %, confirm 3 x 30 s with up to two -5 % step-downs, fill 0.7/0.8/0.9
#   x result, overload 1.05/1.1/1.2 x first fail; every measured step has a stats snapshot pair); fix = one fixed-load
#   window at RATE (10 s run warm-up, 5 s step warm-up, 30 s measured, stats snapshots) with NO SLO abort: loadgen gets
#   --slo mixed:99:600000 so only the saturation (outstanding) abort can end the window early; p99 is recorded and the
#   1 ms SLO is judged here (fix-result.txt: slo_1ms_pass), an aborted window is a NOTE with its reason; KIND=pfix|ptrace: RATE (requests/s = L). ptrace = a pfix window with TRACE=1 (put/get logs for the
#   Figure 2c classification only; never used for throughput/latency comparisons). pfix forces TRACE=0.
#   fix2 = H1 fixed phase: one server lifetime with two fixed windows at RATES=<L2>,<L1> (fix's window: 10 s run warm-up,
#   5 s step warm-up, 30 s measured; no SLO abort; per-step table ladder-result.txt; an aborted window is a NOTE).
#   ladder = fixed-rate steps at RATES (comma list, run in that order; 10 s warm-up, 3 s + 15 s per step, no SLO abort);
#   used for the low-rate latency (CPU idle) check, reports/KV-idle-check.md.
#   SYS=Popcorn: C8 (build-8 deploy bundle dir), K8 (release), GT8 (guest tools dir), RECV_MODE (poll | idle | sleep)
# optional: KEYS (4000000), BATCH (16), SEED (20261016), GATE=0 (skip the Host gate; refused unless KIND=functional),
#   VM_PLAIN (/home/comsys/kv3), VM_MEG (/home/comsys/kvm3), PLAIN_BUILD (builds/kv/3), MEG_BUILD (builds/kv-megalon/3),
#   LOADGEN_BUILD (builds/kv-loadgen/3).
# Page MSI (user decision A, 2026-10-16): cxl_shm is loaded and coherence ENABLED before kv-server starts, so node 0's
# initial load and every warm-up read run under coherence (no --preload-only: the store's index replicas are
# process-local). init_state=shared, as for the other workloads' page MSI runs.
# Prints "PILOTRUN <name> OK|NOTE|STOP <reason>"; exit 0 for OK/NOTE, 1 for STOP (the sequence stops).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # never write __pycache__ (harness snapshots live in recovery/); every python3 call also has -B
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
[[ $PUT_RATIO =~ ^(0|0\.05|0\.2|0\.5|0\.8)$ ]] || stop "bad PUT_RATIO"
[[ $BATCH =~ ^(16|32|64)$ ]] || stop "bad BATCH"
[[ $KEYS =~ ^[1-9][0-9]*$ ]] || stop "bad KEYS"
SA="--nodes 2 --keys $KEYS --threads 14 --start-timeout-ms 5400000"
export LOADGEN=$LOADGEN_BUILD/loadgen READY_TIMEOUT=${READY_TIMEOUT:-5400} RUN_KIND=measurement STATS_OP=10 TRACE
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
# COH_TIMERS=0|1 (optional, Megalon only): MEGALON_COH_TIMERS for both nodes (instrumentation overhead check; the
#   value is recorded in the run manifest via node_env)
[ -z "${COH_TIMERS:-}" ] || { [[ $COH_TIMERS =~ ^[01]$ ]] && [ "$SYS" = Megalon ]; } || stop "COH_TIMERS=0|1 is for SYS=Megalon only"
export NODE_ENV="ENV:XTIMEOUT=14400${COH_TIMERS:+ ENV:MEGALON_COH_TIMERS=$COH_TIMERS}"
SLO_ARG=mixed:99:1; [[ $KIND =~ ^(fix|fix2|ladder)$ ]] && SLO_ARG=mixed:99:600000  # fix, ladder: no SLO abort (judged after the run)
LG=(--opt keys=$KEYS --opt batch=$BATCH --opt put_ratio=$PUT_RATIO --opt seed=$SEED --seed "$SEED" --mix mixed=1
    --slo $SLO_ARG --x-stream mixed)
case "$KIND" in
  functional) LG+=(--mode fixed --rates 200,2000 --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  pslo) LG+=(--raw --mode slo --start 500 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 2
             --step-measure-s 8 --confirm-s 15 --confirm-reps 1 --fill none --overload none);;
  slo) LG+=(--raw --mode slo --start 500 --factor 1.5 --precision 0.05 --max-steps 25 --warmup-s 10 --step-warmup-s 3
            --step-measure-s 15 --drain-s 5 --confirm-s 30 --confirm-reps 3 --fill 0.7,0.8,0.9 --overload 1.05,1.1,1.2);;
  ladder) [[ ${RATES:?} =~ ^[0-9]+(,[0-9]+)*$ ]] || stop "bad RATES"  # fixed-rate steps in the given order (idle-latency check)
          LG+=(--raw --mode fixed --rates "$RATES" --warmup-s 10 --step-warmup-s 3 --step-measure-s 15 --drain-s 5);;
  fix2) [[ ${RATES:?} =~ ^[0-9]+,[0-9]+$ ]] || stop "fix2 needs RATES=<L2>,<L1> (integers)"  # H1 fixed phase: one lifetime, L2 then L1
        LG+=(--raw --mode fixed --rates "$RATES" --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  pfix|ptrace|fix) : "${RATE:?}"; LG+=(--raw --mode fixed --rates "$RATE" --warmup-s 10 --step-warmup-s 5 --step-measure-s 30 --drain-s 10);;
  *) stop "bad KIND";;
esac
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
IPS=(192.168.122.100 192.168.122.101)
# no kv-server of ours (command-line word bin/kv-server, not the process name: Megalon renames the main thread
# "megalon-lib" while it initialises) and /dev/dax0.0 unused (sudo -n fuser output empty; fail-closed) on both VMs;
# before and after each run and before the Popcorn cxl_shm load and teardown. [r] keeps the regex off the remote shell.
PAT='(^|[ /])bin/kv-serve[r]( |$)'
servers_gone() {
  local ip out
  for ip in "${IPS[@]}"; do
    out=$($SSH comsys@$ip "echo procs=\$(pgrep -c -u comsys -f '$PAT') fuser=[\$(sudo -n fuser /dev/dax0.0 2>&1 | tr -d ' \n')]" < /dev/null 2>&1)
    [ "$out" = "procs=0 fuser=[]" ] || { echo "$ip: $out" >&2; return 1; }
  done
}
echo "$(date -Is) $NAME: SYS=$SYS PUT_RATIO=$PUT_RATIO KIND=$KIND RATE=${RATE:-} BATCH=$BATCH KEYS=$KEYS TRACE=$TRACE RECV_MODE=${RECV_MODE:-} SEED=$SEED"
servers_gone || stop "a kv-server is running before the run"
[[ ${GATE:-1} =~ ^[01]$ ]] || stop "bad GATE"
# GATE=0 skips the whole Host gate (incl. the measure-env check): functional runs only
[ "${GATE:-1}" = 1 ] || [ "$KIND" = functional ] || stop "GATE=0 is allowed only with KIND=functional (KIND=$KIND)"
if [ "${GATE:-1}" = 1 ]; then bash $P/CXL_SWMC/experiments/vectordb/host-gate.sh check "$E/gate-$NAME.txt" || stop "host gate"; fi
T0=$(date +%s) RECLAIM_NOTE=
if [ "$SYS" = Popcorn ]; then  # P-popcorn-deploy §6a cycle with build 8; enable BEFORE the server (load under coherence)
  PS=(K=$K8 GT=$GT8 C=$C8 R=$E/shm-$NAME INIT_STATE=shared)
  servers_gone || stop "kv-server or /dev/dax0.0 user before the cxl_shm load"
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
  # Megalon: no record reclaim at all (sizing keeps every loaded key under the watermark; reports/M5-pilot-kv.md §1).
  # An input/sizing check (user principle 2026-10-17): STOP in fixed/ladder/functional runs; in SLO runs (slo, pslo) a
  # NOTE past the knee, with the steps whose stats-steps.csv megalon.wmeta_reclaim delta is > 0 (value / not-found /
  # error checks stay STOP everywhere)
  if [ "$SYS" = Megalon ] && ! grep -q "^megalon.wmeta_reclaim=0\$" $L; then
    [[ $KIND =~ ^p?slo$ ]] || stop "node$k: Megalon record reclaim (record pressure)"
    RECLAIM_NOTE="${RECLAIM_NOTE:+$RECLAIM_NOTE; }Megalon record reclaim > 0 (node$k; steps $(python3 -I -B -c 'import csv,sys
print(",".join(sorted({r["step"] for r in csv.DictReader(open(sys.argv[1])) if float(r.get("megalon.wmeta_reclaim") or 0) > 0}, key=int)) or "unattributed")' $R/stats-steps.csv 2>/dev/null || echo unattributed))"
  fi
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
  note=$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' $R/loadgen/summary.json 2>/dev/null)
  [[ $KIND =~ ^p?slo$ ]] && [ -n "$note" ] && { echo "PILOTRUN $NAME NOTE $note${RECLAIM_NOTE:+; $RECLAIM_NOTE}"; exit 0; }
  stop "run.sh rc $RC ($note)"
fi
[ "$KIND" = functional ] && ! grep -q '"pass":true' $R/loadgen/steps.jsonl && stop "functional step not PASS"
# every run: a non-empty per-step stats table (stats snapshots of every measured step; verifier LOW-1)
[ -s $R/stats-steps.csv ] && [ "$(wc -l < $R/stats-steps.csv)" -ge 2 ] || stop "no stats-steps.csv rows"
# MOT1 v6 Fig 2: per-operation split per step (run.sh writes opsplit.csv; servers without opt.* keys fail here)
[ -s $R/opsplit.csv ] && [ "$(wc -l < $R/opsplit.csv)" -ge 2 ] || stop "no opsplit.csv rows"
if [ "$KIND" = fix ]; then
  python3 -B - $R/loadgen/steps.jsonl > $R/fix-result.txt <<'PY' || stop "fixed window result"
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
if [[ $KIND =~ ^(ladder|fix2)$ ]]; then  # per-step table; an aborted step is a NOTE (fixed mode does not fail on it)
  python3 -B - $R/loadgen/steps.jsonl > $R/ladder-result.txt <<'PY' || stop "ladder result"
import json, sys
st = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
st = [s for s in st if s["phase"] == "fixed"]
print("step offered_x achieved p50_ms p90_ms p99_ms max_ms done aborted reason")
for s in st:
    m = s["streams"]["mixed"]
    print(s["step"], s["offered_x"], m["achieved"], m["p50_ms"], m.get("p90_ms"), m["p99_ms"], m["max_ms"], m.get("done"),
          str(s["aborted"]).lower(), (s["reason"] or "-").replace(" ", "_"))
PY
  cat $R/ladder-result.txt
  awk 'NR>1 && $9=="true"' $R/ladder-result.txt | grep -q . && { echo "PILOTRUN $NAME NOTE $KIND step aborted"; exit 0; }
fi
[ -n "${RECLAIM_NOTE:-}" ] && { echo "PILOTRUN $NAME NOTE $RECLAIM_NOTE"; exit 0; }
echo "PILOTRUN $NAME OK"
