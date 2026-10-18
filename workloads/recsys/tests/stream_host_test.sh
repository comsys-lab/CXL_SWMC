#!/bin/bash
# Host test of the RecSys streaming updater (recsys-server --update-mode stream, DESIGN.md §5.1) and the BLOCK=stream
# loadgen options (--min-step-queries, --ramp-knee) through session.sh with SESSION_LOCAL=1: two local recsys-server
# processes on a /dev/shm file region, one lifetime with the main-block.sh BLOCK=stream thread split (node 0: 14 update
# threads + 1 serving thread; node 1: 1 update thread + 12 serving threads): warmup -> gate (SLO = 5 x its p95) -> slo
# (knee ramp, min queries per step) -> stream_check.py -> fixed (check_breakdown.py) -> stop. Checks: stream stats keys,
# replies on acceptance (update stream keeps up), every sample written (published_seq = last update seq after idle),
# summary ramp_policy / low_rate_violations, STREAMCHECK PASS, invariants. No VM, no CXL device. Run pinned to node 1.
# usage: stream_host_test.sh <server build dir> <loadgen build dir> <work dir (new)> [plain|megalon]
# env: ROW_DIV (200), PORT (27400), UPD_RATE (400), LG_CPUS (30-31), MG_RPO (megalon --mg-rows-per-object, 0 = one object per table); SLO = 5 x the gate p95 at percentile 95 (v6 uses p95;
# the fixed 100 ms of the main block is not reachable under Host noise, so the Host test keeps a self-derived limit)
set -uo pipefail
B=$(cd "$1" && pwd); LGB=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd); X=$ROOT/experiments/recsys
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
ROW_DIV=${ROW_DIV:-200} T_MS=0 PORT=${PORT:-27400}
export LG_CPUS=${LG_CPUS:-30-31}
IMG=/dev/shm/recsys-stream-test-$$.img
SA="--nodes 2 --row-div $ROW_DIV --serve-threads 12 --update-threads 1 --load-threads 8 --verify-rows 1 --start-timeout-ms 900000 --update-mode stream"
swcc_need=$("$B/bin/recsys-server" $SA --publish-ms $T_MS --print-layout | sed -n 's/.* swcc_bytes=\([0-9]*\).*/\1/p')
HW=$((256 << 20)) AL=$((2 << 20))
ARENA=$(( (swcc_need + AL - 1) / AL * AL ))
DEV=$(( HW + ARENA + (64 << 20) + 8 * AL ))
V=$WD/v; mkdir -p "$V/bin" "$V/cfg" "$V/lib"
cp "$B/bin/recsys-server" "$V/bin/"; cp "$ROOT/scripts/guest/recsys-node.sh" "$V/bin/"
[ -d "$B/lib" ] && cp "$B"/lib/* "$V/lib/"
cat > "$V/cfg/cxl_region.yaml" <<EOF
device: $IMG
map_va: 0x600000000000
device_size: $DEV
align: $AL
hwcc_offset: 0
hwcc_size: $HW
msg_ring: [$((HW - 135168)), 135168]
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
truncate -s "$DEV" "$IMG"
FAIL=0
bad() { echo "CHECK FAIL: $*"; FAIL=1; }
cleanup() { SESSION_LOCAL=1 bash "$X/session.sh" stop "$WD/s" > /dev/null 2>&1; rm -f "$IMG"; }
trap cleanup EXIT
"$B/bin/recsys-gen-samples" --out "$WD/updates.smp" --n 200000 --seed 1 --dist zipf > /dev/null
"$B/bin/recsys-gen-samples" --out "$WD/queries.smp" --n 100000 --seed 2 --dist zipf > /dev/null
SE=(SESSION_LOCAL=1 PORT=$PORT T_MS=$T_MS V=$V HOST_SERVER=$B/bin/recsys-server READY_TIMEOUT=900 "NODE0_ARGS=--update-threads 14 --serve-threads 1")
if [ "$BACKEND" = megalon ]; then
  sed -e "s/^object_arena_size:.*/object_arena_size: $ARENA/" -e "s/^logical_scr_size:.*/logical_scr_size: 64MB/" \
      "$W/tests/megalon-host.yaml" > "$V/cfg/megalon.yaml"
  SE+=(SYSTEM=Megalon "SERVER_ARGS=--backend megalon --mg-rows-per-object ${MG_RPO:-0} $SA" "NODE_ENV=ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml ENV:XTIMEOUT=3600"
       "NODE0_ENV=ENV:MEGALON_REINIT=1")
else
  SE+=(SYSTEM=all-HWcc "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=3600")
fi
S=$WD/s
env "${SE[@]}" bash "$X/session.sh" start "$S" || { echo "HOST TEST FAIL: session start"; exit 1; }
cat "$S/load-times.txt"
export LOADGEN=$LGB/loadgen PROFILE=pilot RUN_KIND=functional STATS_OP=10 IDLE_WAIT_S=120
R=${UPD_RATE:-400}
LGC=(--opt samples=$WD/updates.smp --opt queries=$WD/queries.smp --opt quantiles=$W/tools/dist_quantile.txt
     --fixed update=$R --mix query=1 --x-stream query --step-warmup-s 1 --drain-s 5)
m() { SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" "$@"; }
for k in 0 1; do grep -q '^update_mode=stream$' "$S/ready-t$k.txt" || bad "node$k update_mode != stream"; done
[ "$(grep -c '^update_queue\.w' "$S/ready-t0.txt")" = 14 ] || bad "node0: not 14 update_queue.w<i> keys"
[ "$(grep -c '^update_queue\.w' "$S/ready-t1.txt")" = 1 ] || bad "node1: not 1 update_queue.w<i> key"
for key in stats_mono_ns update_accepted_seq update_lag_samples update_lag_ns_sum update_lag_n update_lag_ns_max; do
  grep -q "^$key=[0-9]*$" "$S/ready-t0.txt" || bad "node0 stats key $key missing"
done
m warmup -- "${LGC[@]}" --mode fixed --rates 1 --warmup-s 2 --step-warmup-s 0 --step-measure-s 5; rc=$?
[ $rc = 0 ] || bad "warmup rc $rc"
m gate -- "${LGC[@]}" --raw --mode fixed --rates 1 --warmup-s 2 --step-measure-s 10; rc=$?
[ $rc = 0 ] || bad "gate rc $rc"
SLO_MS=$(python3 "$X/main_util.py" slo "$S/gate/loadgen/steps.jsonl" 5 95) || { bad "no SLO"; SLO_MS=60; }
export SLO_MS SLO_RULE="5 x gate p95 (Host test)"
echo "SLO_MS=$SLO_MS"
python3 "$X/stream_check.py" "$S/gate" | tail -2
python3 "$X/stream_check.py" "$S/gate" | grep -q '^STEP .* valid=True' || bad "gate step not stream-valid at $R samples/s"
m slo -- "${LGC[@]}" --opt seed=20261017 --seed 20261017 --slo query:95:$SLO_MS --raw --tol 0.02 --mode slo \
  --start 2 --factor 1.5 --precision 0.2 --max-steps 30 --warmup-s 2 --step-measure-s 5 --confirm-s 5 \
  --min-step-queries 20 --ramp-knee 2; rc=$?
[ $rc = 0 ] || [ $rc = 1 ] || bad "slo rc $rc"
grep -q 'workload_finish":"ok' "$S/slo/loadgen/summary.json" || bad "slo workload finish"
echo "slo: $(head -c 600 "$S/slo/loadgen/summary.json")"
python3 - "$S/slo/loadgen" <<'PY' || bad "slo summary / steps (ramp_policy, min-step-queries)"
import json, sys
d = sys.argv[1]
s = json.load(open(d + "/summary.json"))
st = [json.loads(l) for l in open(d + "/steps.jsonl") if l.strip()]
m = [x for x in st if x.get("measure_s", 0) > 0 and x["phase"] != "warmup"]
ok = all(x["measure_s"] >= max(5, 20 / x["offered_x"]) - 1e-9 for x in m if x["phase"] in ("ramp", "bisect"))
print("steps", [(x["phase"], x["offered_x"], x["measure_s"], x["pass"]) for x in m])
if s.get("max_offered_x_pass") is not None:
    ok &= "ramp_policy" in s and s["ramp_policy"]["knee_k"] == 2 and isinstance(s.get("low_rate_violations"), list)
man = open(d + "/manifest.txt").read()
ok &= "min_step_queries=20 ramp_knee=2" in man
sys.exit(0 if ok else 1)
PY
python3 "$X/stream_check.py" "$S/slo" > "$S/slo/stream-check.txt"; rc=$?
tail -3 "$S/slo/stream-check.txt"
[ $rc = 0 ] && grep -q '^STREAMCHECK PASS' "$S/slo/stream-check.txt" || bad "stream_check on slo: $(grep '^STREAMCHECK' "$S/slo/stream-check.txt")"
[ -s "$S/slo/stream-check.csv" ] || bad "no stream-check.csv"
m fixed -- "${LGC[@]}" --opt seed=20261016 --seed 20261016 --raw --mode fixed --rates 2 --warmup-s 2 --step-measure-s 10; rc=$?
[ $rc = 0 ] || bad "fixed rc $rc"
python3 "$X/check_breakdown.py" "$S/fixed" || bad "breakdown check"
python3 "$X/stream_check.py" "$S/fixed" | grep -q '^STEP .* valid=True' || bad "fixed step not stream-valid"
# every accepted sample was written by every worker: after the idle wait, published_seq = the last update seq
m idle-end -- "${LGC[@]}" --mode fixed --rates 1 --warmup-s 0 --step-warmup-s 0 --step-measure-s 1 --fixed update=1 > /dev/null 2>&1
last=$(sed -n 's/^last_update_seq=//p' "$S/fixed/loadgen/recsys.txt"); pub=$(sed -n 's/^published_seq=//p' "$S/idle-end/pre-t0.txt")
acc=$(sed -n 's/^update_accepted_seq=//p' "$S/idle-end/pre-t0.txt"); lag=$(sed -n 's/^update_lag_samples=//p' "$S/idle-end/pre-t0.txt")
echo "after fixed: last_update_seq=$last accepted=$acc published=$pub lag=$lag"
[ -n "$last" ] && [ "$pub" = "$last" ] && [ "$acc" = "$last" ] && [ "$lag" = 0 ] || bad "not every accepted sample written"
cat "$S"/*/invariants.txt | sort | uniq -c | head
SESSION_LOCAL=1 bash "$X/session.sh" stop "$S"; rc=$?
[ $rc = 0 ] || bad "stop rc $rc"
cat "$S/final-counters.txt" | tr '\n' ' '; echo
[ $FAIL = 0 ] && echo "STREAM HOST TEST PASS ($BACKEND) -> $WD" || { echo "STREAM HOST TEST FAIL ($BACKEND) -> $WD"; exit 1; }
