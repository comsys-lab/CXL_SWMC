#!/bin/bash
# Host test of the main-run session harness (experiments/recsys/session.sh, main_util.py, check_breakdown.py) with
# SESSION_LOCAL=1: two local recsys-server processes on a /dev/shm file region (as host_test.sh), one server lifetime,
# the main block v2 sequence scaled down: warmup -> gate (1 query/s; SLO = 5 x its p99) -> slo-r1 -> slo-r2 -> fixed at 0.5 x r1 ->
# stop. Checks: update seqs continue over the lifetime (seq_base of r2 = last seq of r1, published_seq rises),
# window invariants, gate validity + SLO in the manifests, L from r1, breakdown columns, negative cases (existing name,
# measure after stop, seq_base given by the caller). No VM, no CXL device. Run pinned to Host node 1.
# usage: session_host_test.sh <server build dir> <loadgen build dir> <work dir (new)> [plain|megalon]
# env: ROW_DIV (200), T_MS (1000), PORT (27300), LG_CPUS (30-31), MG_RPO (megalon --mg-rows-per-object, 0 = one object per table); SLO = 5 x the gate p95 at percentile 95 (v6 uses p95;
# the fixed 100 ms of the main block is not reachable under Host noise, so the Host test keeps a self-derived limit)
set -uo pipefail
B=$(cd "$1" && pwd); LGB=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd); X=$ROOT/experiments/recsys
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
ROW_DIV=${ROW_DIV:-200} T_MS=${T_MS:-1000} PORT=${PORT:-27300}
export LG_CPUS=${LG_CPUS:-30-31}
IMG=/dev/shm/recsys-session-test-$$.img
SA="--nodes 2 --row-div $ROW_DIV --serve-threads 12 --update-threads 4 --load-threads 8 --verify-rows 1 --start-timeout-ms 900000"
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
SE=(SESSION_LOCAL=1 PORT=$PORT T_MS=$T_MS V=$V HOST_SERVER=$B/bin/recsys-server READY_TIMEOUT=900)
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
LGC=(--opt samples=$WD/updates.smp --opt queries=$WD/queries.smp --opt quantiles=$W/tools/dist_quantile.txt
     --fixed update=${UPD_RATE:-200} --mix query=1 --x-stream query --step-warmup-s 1 --drain-s 5)
m() { SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" "$@"; }
m warmup -- "${LGC[@]}" --mode fixed --rates 1 --warmup-s 2 --step-warmup-s 0 --step-measure-s 5; rc=$?
[ $rc = 0 ] || bad "warmup rc $rc"
m gate -- "${LGC[@]}" --raw --mode fixed --rates 1 --warmup-s 2 --step-measure-s 10; rc=$?
[ $rc = 0 ] || bad "gate rc $rc"
echo "gate: $(python3 "$X/main_util.py" gate "$S/gate/loadgen/steps.jsonl")"
python3 "$X/main_util.py" gate "$S/gate/loadgen/steps.jsonl" | grep -q '^VALID queries_done=' || bad "gate not VALID"
SLO_MS=$(python3 "$X/main_util.py" slo "$S/gate/loadgen/steps.jsonl" 5 95) || { bad "no SLO"; SLO_MS=60; }
export SLO_MS SLO_RULE="5 x gate p95 (Host test)"
echo "SLO_MS=$SLO_MS"
python3 "$X/main_util.py" gate "$S/gate/loadgen/steps.jsonl" "$SLO_MS" 95 | grep -q 'within_slo=True' || bad "gate not within its own SLO"
for r in 1 2; do
  m slo-r$r -- "${LGC[@]}" --opt seed=$((20261016 + r)) --seed $((20261016 + r)) --slo query:95:$SLO_MS --raw --mode slo \
    --start 1 --factor 1.5 --precision 0.2 --max-steps 20 --warmup-s 2 --step-measure-s 5 --confirm-s 5; rc=$?
  [ $rc = 0 ] || [ $rc = 1 ] || bad "slo-r$r rc $rc"
  grep -q 'workload_finish":"ok' "$S/slo-r$r/loadgen/summary.json" || bad "slo-r$r workload finish"
  echo "slo-r$r: $(head -c 400 "$S/slo-r$r/loadgen/summary.json")"
done
s1=$(sed -n 's/^last_update_seq=//p' "$S/slo-r1/loadgen/recsys.txt"); b2=$(sed -n 's/^seq_base=//p' "$S/slo-r2/manifest.txt")
b1=$(sed -n 's/^seq_base=//p' "$S/slo-r1/manifest.txt"); g1=$(sed -n 's/^last_update_seq=//p' "$S/gate/loadgen/recsys.txt")
echo "seq: gate last=$g1, r1 base=$b1 last=$s1, r2 base=$b2"
[ "$b1" = "$g1" ] && [ "$(sed -n "s/^slo_ms=//p" "$S/slo-r1/manifest.txt")" = "$SLO_MS" ] && [ "$b2" = "$s1" ] && [ "$s1" -gt "$b1" ] || bad "seq_base does not continue"
p1=$(sed -n 's/^published_seq=//p' "$S/slo-r1/post-t0.txt"); p2=$(sed -n 's/^published_seq=//p' "$S/slo-r2/post-t0.txt")
echo "published_seq after r1=$p1 after r2=$p2"
[ "$p2" -gt "$p1" ] && [ "$p1" -gt "$b1" ] || bad "published_seq does not rise over the lifetime"
L=""
for r in 1 2; do  # half must refuse a noted search and give 0.5 x confirm mean otherwise (the block uses all-HWcc r1)
  note=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("note",""))' "$S/slo-r$r/loadgen/summary.json")
  if [ -n "$note" ]; then python3 "$X/main_util.py" half "$S/slo-r$r/loadgen/summary.json" > /dev/null 2>&1 && bad "half accepted noted slo-r$r"
  else x=$(python3 "$X/main_util.py" half "$S/slo-r$r/loadgen/summary.json") || bad "half failed on slo-r$r"; [ -n "$L" ] || L=$x; fi
done
[ -n "$L" ] || { bad "no SLO search with a confirm result (Host noise?)"; L=2; }
echo "L=$L"
m fixed -- "${LGC[@]}" --opt seed=20261016 --seed 20261016 --raw --mode fixed --rates "$L" --warmup-s 2 --step-measure-s 10; rc=$?
[ $rc = 0 ] || bad "fixed rc $rc"
python3 "$X/check_breakdown.py" "$S/fixed" || bad "breakdown check"
head -2 "$S/fixed/breakdown.csv" | cut -c1-400
cat "$S"/*/invariants.txt | sort | uniq -c | head
# negative cases
m fixed -- "${LGC[@]}" --mode fixed --rates 1 > /dev/null 2>&1; [ $? = 3 ] || bad "existing name not refused with rc 3"
m neg-seq -- "${LGC[@]}" --opt seq_base=5 --mode fixed --rates 1 > /dev/null 2>&1; [ $? = 2 ] || bad "caller seq_base not refused"
cp -r "$S/fixed" "$WD/fixed-nocol"; sed -i '1s/serve_coherence_ms_per_query/renamed/' "$WD/fixed-nocol/breakdown.csv"
python3 "$X/check_breakdown.py" "$WD/fixed-nocol" > /dev/null && bad "check_breakdown accepts a missing column"
SESSION_LOCAL=1 bash "$X/session.sh" stop "$S"; rc=$?
[ $rc = 0 ] || bad "stop rc $rc"
m late -- "${LGC[@]}" --mode fixed --rates 1 > /dev/null 2>&1; [ $? = 3 ] || bad "measure after stop not refused"
cat "$S/final-counters.txt" | tr '\n' ' '; echo
[ $FAIL = 0 ] && echo "SESSION HOST TEST PASS ($BACKEND) -> $WD" || { echo "SESSION HOST TEST FAIL ($BACKEND) -> $WD"; exit 1; }
