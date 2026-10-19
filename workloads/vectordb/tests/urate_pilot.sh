#!/bin/bash
# Host pilot / functional test of the update-rate path (DESIGN.md §17): two vdb-server processes (plain backend) share
# a scratch FILE as the "device" (HW coherent: checks the write path, E1, the write-path counters and writer capacity,
# never a coherence protocol; never points at /dev/dax*). Node 0 loads a prebuilt initial image (tools/build_index).
# One server lifetime, then per update rate R one loadgen invocation (fixed mode, search rate SEARCH/s, update stream
# --fixed update=R, the update stream continues across invocations via --opt w_start), then urate_check.py and
# e1_check.py per invocation and the servers' final counters.
# usage: urate_pilot.sh <vdb build dir> <loadgen binary> <data dir (pool_b/queries .fbin)> <writes.bin> <init image dir>
#                       <scratch dir (must not exist)>
# env: WRITERS (server --writer-threads, default 1), URATES ("800 1600 3200"), SEARCH (search/s, 20), MEASURE_S (20),
#      SEGMENTS (32), CHUNK (33554432), MAXIDS (2000000; must match the image), DEVICE_SIZE (8 GiB),
#      SEARCH_THREADS (4), CPUS0 / CPUS1 (server CPU sets; 18-20,50-52 / 21-23,53-55 = the node-1 CPUs user.slice may use
#      on this Host), LGCPUS (loadgen CPU set; 18-23,50-55), NA / NB
#      (pool sizes for e1_check; default from the writes manifest), PORT0 (19400),
#      SLO_URATE (optional): after the fixed invocations, one more part "slo" = loadgen --mode slo with the update stream
#      --fixed update=SLO_URATE and the knee ramp of urate-block.sh at Host scale (SLO_ARGS, default: --start 5 --factor
#      1.5 --precision 0.05 --step-warmup-s 2 --step-measure-s 6 --confirm-s 10 --confirm-reps 1 --min-step-queries 30
#      --ramp-knee 2 --ramp-knee-floor 1.5 --max-steps 30 --fill none --overload none --drain-s 60); urate_check.py judges it
#      OPCOH (optional, e.g. fake with VDB_OPCOH_FAKE=1): after the stop, opsplit.py + tests/opcoh_check.py <mode> on every
#      part with OPCOH_PARTS = all parts (closure over the lifetime); a failure fails the pilot
set -euo pipefail
B=$(cd "$1" && pwd) LG=$2 D=$(cd "$3" && pwd) WF=$4 INIT=$(cd "$5" && pwd) S=$6
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
WRITERS=${WRITERS:-1} URATES=${URATES:-800 1600 3200} SEARCH=${SEARCH:-20} MEASURE_S=${MEASURE_S:-20}
SEG=${SEGMENTS:-32} CHUNK=${CHUNK:-33554432} MAXIDS=${MAXIDS:-2000000} DEVSZ=${DEVICE_SIZE:-8589934592}
CPUS0=${CPUS0:-18-20,50-52} CPUS1=${CPUS1:-21-23,53-55} LGCPUS=${LGCPUS:-18-23,50-55} ST=${SEARCH_THREADS:-4} PORT0=${PORT0:-19400}
NA=${NA:-$(sed -n 's/^pool_a=//p' "$WF.manifest.txt")} NB=${NB:-$(sed -n 's/^pool_b=//p' "$WF.manifest.txt")}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S"
PARAMS="--nodes 2 --segments $SEG --chunk-bytes $CHUNK --M 16 --efc 128 --ef 32 --max-writes 2097152 --max-ids $MAXIDS --max-deletes 1048576 --writer-threads $WRITERS"
truncate -s "$DEVSZ" "$S/device.img"
sed -e "s|^device: .*|device: $S/device.img|" -e "s|^device_size: .*|device_size: $DEVSZ|" "$ROOT/config/cxl_region.yaml" > "$S/region.yaml"
# shellcheck disable=SC2086
APP=$("$B/bin/vdb-server" $PARAMS --print-app-bytes)
RID=0x$(printf '%x' $(( (RANDOM << 16 | RANDOM) | 1 )))
{ echo "# urate pilot $(date -Is)"; echo "build=$B $(sha256sum "$B/bin/vdb-server" | cut -c1-64)"; echo "loadgen=$LG $(sha256sum "$LG" | cut -c1-64)"
  echo "data=$D writes=$WF init=$INIT params=$PARAMS"; echo "urates=$URATES search=$SEARCH measure_s=$MEASURE_S cpus0=$CPUS0 cpus1=$CPUS1 lgcpus=$LGCPUS search_threads=$ST"
  echo "host_load=$(cut -d' ' -f1-3 /proc/loadavg)"; } > "$S/pilot.txt"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
for k in 0 1; do
  EXTRA=""; [ "$k" = 0 ] && EXTRA="--init-dir $INIT"
  C=$CPUS0; [ "$k" = 1 ] && C=$CPUS1
  # shellcheck disable=SC2086
  env CXL_REGION_CONFIG=$S/region.yaml CXL_APP_HWCC_BYTES=$APP numactl --physcpubind="$C" --membind=1 "$B/bin/vdb-server" --node $k \
    --run-id "$RID" $PARAMS --port $((PORT0 + k)) --search-threads $ST --wait-timeout-ms 60000 $EXTRA > "$S/node$k.log" 2>&1 &
  PIDS+=($!)
done
for k in 0 1; do
  for _ in $(seq 900); do grep -q "vdb-server: READY" "$S/node$k.log" && break; { grep -q FATAL "$S/node$k.log" || ! kill -0 "${PIDS[$k]}" 2>/dev/null; } && { tail -n 5 "$S/node$k.log"; exit 1; }; sleep 1; done
  grep -q "vdb-server: READY" "$S/node$k.log" || { echo "node$k not READY"; exit 1; }
done
RC=0 WS=0 i=0
for R in $URATES; do
  i=$((i + 1)); O=$S/u$R
  mkdir "$O"
  set +e
  numactl --physcpubind="$LGCPUS" --membind=1 "$LG" --workload vectordb --target 127.0.0.1:$PORT0,127.0.0.1:$((PORT0 + 1)) --out "$O/loadgen" \
    --stats-op 10 --opt data="$D" --opt writes="$WF" --opt seed=$((20261019 + i)) --seed $((20261019 + i)) --opt w_start=$WS \
    --mode fixed --rates "$SEARCH" --fixed update=$R --mix search=1 --x-stream search --slo search:99:100 --tol 0.02 \
    --warmup-s 5 --step-warmup-s 3 --step-measure-s "$MEASURE_S" --drain-s 10 --raw > "$O/loadgen.log" 2>&1
  lrc=$?
  set -e
  WS=$(sed -n 's/^next_w=//p' "$O/loadgen/vectordb.txt")
  grep -qx "write_errors=0" "$O/loadgen/vectordb.txt" || { echo "u$R: write errors"; RC=1; }
  python3 "$ROOT/experiments/vectordb/urate_check.py" "$O" --writers "$WRITERS" > "$O/urate-check.txt" 2>&1 || RC=1
  python3 "$ROOT/experiments/vectordb/e1_check.py" --writes "$WF" --na "$NA" --nb "$NB" --searches "$O/loadgen/searches.bin" \
    --out "$O/e1" --sample 300 > /dev/null 2>&1 && e1="E1 PASS ($(head -n 1 "$O/e1.e1.txt"))" || { e1="E1 FAIL"; RC=1; }
  echo "u$R loadgen_rc=$lrc next_w=$WS $(grep '^STEP' "$O/urate-check.txt" | tail -1) | $e1"
done
if [ -n "${SLO_URATE:-}" ]; then
  O=$S/slo; mkdir "$O"
  SA=${SLO_ARGS:---start 5 --factor 1.5 --precision 0.05 --step-warmup-s 2 --step-measure-s 6 --confirm-s 10 --confirm-reps 1 --min-step-queries 30 --ramp-knee 2 --ramp-knee-floor 1.5 --max-steps 30 --fill none --overload none --drain-s 60}
  set +e
  # shellcheck disable=SC2086
  numactl --physcpubind="$LGCPUS" --membind=1 "$LG" --workload vectordb --target 127.0.0.1:$PORT0,127.0.0.1:$((PORT0 + 1)) --out "$O/loadgen" \
    --stats-op 10 --opt data="$D" --opt writes="$WF" --opt seed=20261019 --seed 20261019 --opt w_start=$WS \
    --mode slo $SA --fixed update=$SLO_URATE --mix search=1 --x-stream search --slo search:99:100 --tol 0.02 --warmup-s 5 --raw > "$O/loadgen.log" 2>&1
  lrc=$?
  set -e
  WS=$(sed -n 's/^next_w=//p' "$O/loadgen/vectordb.txt")
  grep -qx "write_errors=0" "$O/loadgen/vectordb.txt" || { echo "slo: write errors"; RC=1; }
  python3 "$ROOT/experiments/vectordb/urate_check.py" "$O" --writers "$WRITERS" > "$O/urate-check.txt" 2>&1 || RC=1
  python3 "$ROOT/experiments/vectordb/e1_check.py" --writes "$WF" --na "$NA" --nb "$NB" --searches "$O/loadgen/searches.bin" \
    --out "$O/e1" --sample 300 > /dev/null 2>&1 && e1="E1 PASS" || { e1="E1 FAIL"; RC=1; }
  echo "slo u$SLO_URATE loadgen_rc=$lrc next_w=$WS $(grep '^URATECHECK' "$O/urate-check.txt") | $e1 | $(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("result", s.get("max_offered_x_pass"), "note", repr(s.get("note")), "ramp", s.get("ramp_policy"))' "$O/loadgen/summary.json")"
fi
for p in "${PIDS[@]}"; do kill -TERM "$p"; done
wait || true
PIDS=()
if [ -n "${OPCOH:-}" ]; then
  PL=""; for R in $URATES; do PL="$PL $S/u$R"; done; [ -z "${SLO_URATE:-}" ] || PL="$PL $S/slo"
  for O in $PL; do
    python3 "$ROOT/experiments/vectordb/opsplit.py" "$O" > "$O/opsplit.log" 2>&1 || { echo "${O##*/}: opsplit failed"; RC=1; }
    OPCOH_PARTS="$PL" python3 "$HERE/opcoh_check.py" "$O" "$OPCOH" > "$O/opcoh-check.txt" 2>&1
    echo "${O##*/}: $(tail -n 1 "$O/opcoh-check.txt" | cut -c1-300)"
    grep -q "^OPCOH_CHECK PASS" "$O/opcoh-check.txt" || RC=1
  done
fi
for k in 0 1; do
  sed -n '/vdb-server: stopping/,$p' "$S/node$k.log" | grep -E "^(node|P|elements|updates|inserts|deletes|searches|timeouts|bad_records|writer_threads|write_jobs_accepted|write_jobs_done|write_backlog|dlog_count\.[0-9])=" | tr '\n' ' '; echo
done | tee "$S/final.txt"
python3 - "$S/final.txt" "$WS" "$NA" <<'PY' || RC=1
import sys
lines = [dict(kv.split("=", 1) for kv in l.split()) for l in open(sys.argv[1]) if l.strip()]
ws, na = int(sys.argv[2]), int(sys.argv[3])
ups = sum(int(d["updates"]) for d in lines)
ok = ups * 2 == ws and all(d["bad_records"] == "0" and d["timeouts"] == "0" and d["write_backlog"] == "0"
                           and d["write_jobs_accepted"] == d["write_jobs_done"] == d["updates"] for d in lines)
ok = ok and all(int(d["P"]) == ws for d in lines) and all(int(d["elements"]) == na + ups for d in lines)
dl = [sum(int(d[f"dlog_count.{u}"]) for u in (0, 1)) for d in lines]
ok = ok and all(x == ups for x in dl)
print(f"final: updates {ups} (writes {ws}), P {[d['P'] for d in lines]}, elements {[d['elements'] for d in lines]}, "
      f"dlog total {dl}, bad_records/timeouts/backlog {[(d['bad_records'], d['timeouts'], d['write_backlog']) for d in lines]}: "
      + ("CONSISTENT" if ok else "INCONSISTENT"))
sys.exit(0 if ok else 1)
PY
echo "PILOT $([ $RC = 0 ] && echo PASS || echo FAIL) writers=$WRITERS -> $S"
exit $RC
