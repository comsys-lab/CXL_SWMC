#!/bin/bash
# Host functional test of recsys (no CXL device, no VM): a /dev/shm file stands in for the device through a copy of
# the region config; two recsys-server processes = node 0 (updater) and node 1 (serving), both on Host NUMA node 1;
# loadgen drives updates (node 0) and queries (node 1) over loopback.
# A file region is physically coherent: this checks API use, layout, seqlock and torn-row detection, not a protocol.
# usage: host_test.sh <build dir> <loadgen build dir> <work dir (new)> [plain|megalon] [publish_ms] [extra server args]
# env: STEP_S (5, measured seconds per step), PRELOAD (1: --preload-only then --preloaded, plain only), PORT (27100), ROW_DIV (200), UPD_RATE (2000), Q_RATES (5,10), MEGALON_CFG (template), MEGALON_SCR (logical_scr_size, 64MB), CPUS0/CPUS1/CPUSL,
#      UPD_SMP / QRY_SMP (v2 samples files, e.g. real MLPerf day 23 from tools/mlperf_npz_to_samples.py; default: synthetic),
#      SLO (loadgen --slo, default query:95:100), PUBLISH_FRAC (--publish-frac, reported only)
# Checks: loadgen ok, torn_rows 0, no misses, queries and rows written > 0, Fig 2 op counters (op.query.n = queries,
# op.row_update.n = rows_written, t_ns > 0), false_retries <= seq_retries; megalon (row objects): objects = rows,
# probes = lookups, no stripe-table use (seq_retries, seq_spins, lock_spins 0).
set -euo pipefail
B=$(cd "$1" && pwd); LG=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}; T=${5:-0}; shift $(( $# < 5 ? $# : 5 )); EXTRA=("$@")
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd)
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
PORT=${PORT:-27100} ROW_DIV=${ROW_DIV:-200} UPD_RATE=${UPD_RATE:-2000} Q_RATES=${Q_RATES:-5,10}
CPUS0=${CPUS0:-16-21} CPUS1=${CPUS1:-22-29,54-61} CPUSL=${CPUSL:-30-31}
IMG=/dev/shm/recsys-test-$$.img
SA=(--nodes 2 --row-div "$ROW_DIV" --publish-ms "$T" --publish-frac "${PUBLISH_FRAC:-0}" --serve-threads 12 --update-threads 4 --verify-rows 1 "${EXTRA[@]}")
read -r swcc_need <<< "$("$B/bin/recsys-server" "${SA[@]}" --print-layout | sed -n 's/.* swcc_bytes=\([0-9]*\).*/\1/p')"
APP=$("$B/bin/recsys-server" "${SA[@]}" --print-app-bytes)
HW=$((256 << 20)) AL=$((2 << 20))
LOGB=$((64 << 20))
ARENA=$(( (swcc_need + AL - 1) / AL * AL ))
DEV=$(( HW + ARENA + LOGB + 8 * AL ))
cat > "$WD/region.yaml" <<EOF
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
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; rm -f "$IMG"; }
PIDS=(); trap cleanup EXIT
if [ -n "${UPD_SMP:-}" ]; then ln -s "$(readlink -f "$UPD_SMP")" "$WD/updates.smp"
else "$B/bin/recsys-gen-samples" --out "$WD/updates.smp" --n 400000 --seed 1 --dist zipf > /dev/null; fi
if [ -n "${QRY_SMP:-}" ]; then ln -s "$(readlink -f "$QRY_SMP")" "$WD/queries.smp"
else "$B/bin/recsys-gen-samples" --out "$WD/queries.smp" --n 100000 --seed 2 --dist zipf > /dev/null; fi
RID=0x$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')
NE=()
if [ "$BACKEND" = megalon ]; then
  sed -e "s/^object_arena_size:.*/object_arena_size: $ARENA/" -e "s|^region_config:.*|region_config: \"$WD/region.yaml\"|" \
      -e "s/^logical_scr_size:.*/logical_scr_size: ${MEGALON_SCR:-64MB}/" "${MEGALON_CFG:-$W/tests/megalon-host.yaml}" > "$WD/megalon.yaml"
  NE=(RACKOBJ_CONFIG="$WD/megalon.yaml")
fi
N0=()  # node 0 only args
if [ "${PRELOAD:-0}" = 1 ]; then  # Popcorn init_state=shared path: tables written through a plain mapping first
  env CXL_REGION_CONFIG="$WD/region.yaml" numactl --physcpubind="$CPUS0" --membind=1 "$B/bin/recsys-server" --node 0 \
    --preload-only "${SA[@]}" > "$WD/preload.log" 2>&1 || { cat "$WD/preload.log"; exit 1; }
  N0=(--preloaded)
fi
start() {  # node cpus extra-env...
  local k=$1 c=$2; shift 2
  local XA=(); [ "$k" = 0 ] && XA=("${N0[@]}")
  env CXL_REGION_CONFIG="$WD/region.yaml" CXL_APP_HWCC_BYTES="$APP" "${NE[@]}" "$@" \
    numactl --physcpubind="$c" --membind=1 "$B/bin/recsys-server" --node "$k" --run-id "$RID" --port $((PORT + k)) \
    --backend "$BACKEND" "${SA[@]}" "${XA[@]}" > "$WD/node$k.log" 2>&1 &
  PIDS+=($!)
}
if [ "$BACKEND" = megalon ]; then start 0 "$CPUS0" MEGALON_REINIT=1; else start 0 "$CPUS0"; fi
start 1 "$CPUS1"
for k in 0 1; do
  for _ in $(seq 900); do grep -q "READY" "$WD/node$k.log" && break; grep -q FATAL "$WD/node$k.log" && { cat "$WD/node$k.log"; exit 1; }; sleep 1; done
  grep -q READY "$WD/node$k.log" || { echo "node$k not ready"; tail "$WD/node$k.log"; exit 1; }
done
grep -h "initial tables\|warm-up\|created" "$WD"/node*.log
set +e
numactl --physcpubind="$CPUSL" --membind=1 "$LG/loadgen" --workload recsys --target 127.0.0.1:$PORT,127.0.0.1:$((PORT + 1)) \
  --out "$WD/lg" --opt samples="$WD/updates.smp" --opt queries="$WD/queries.smp" \
  --opt quantiles="$W/tools/dist_quantile.txt" --mode fixed --fixed update="$UPD_RATE" --mix query=1 --rates "$Q_RATES" \
  --slo "${SLO:-query:95:100}" \
  --warmup-s 2 --step-warmup-s 1 --step-measure-s "${STEP_S:-5}" --drain-s 5 --stats-op 10 > "$WD/loadgen.log" 2>&1
LGRC=$?
set -e
kill -TERM "${PIDS[@]}"; wait 2>/dev/null || true; PIDS=()
tail -5 "$WD/loadgen.log"
cat "$WD/lg/recsys.txt"
s() { sed -n "s/^$2=//p" "$WD/node$1.log" | tail -1; }
echo "node0: samples=$(s 0 samples) rows_written=$(s 0 rows_written) flushes=$(s 0 flushes) flush_overruns=$(s 0 flush_overruns) published_seq=$(s 0 published_seq) lock_spins=$(s 0 lock_spins) update_misses=$(s 0 update_misses)"
echo "node0: publish_rounds=$(s 0 publish_rounds) round_rows=$(s 0 round_rows) rows_per_round_target=$(s 0 rows_per_round_target) update_rate_sustained=$(s 0 update_rate_sustained) update_queue_max=$(s 0 update_queue_max) op.row_update n=$(s 0 op.row_update.n) t_ns=$(s 0 op.row_update.t_ns) c_ns=$(s 0 op.row_update.c_ns)"
echo "node1: queries=$(s 1 queries) lookups=$(s 1 lookups) probes=$(s 1 probes) seq_retries=$(s 1 seq_retries) false_retries=$(s 1 false_retries) seq_spins=$(s 1 seq_spins) misses=$(s 1 misses) torn_rows=$(s 1 torn_rows)"
echo "node1: op.query n=$(s 1 op.query.n) t_ns=$(s 1 op.query.t_ns) c_ns=$(s 1 op.query.c_ns) $(sed -n 's/^op.coh_src=//p' "$WD/node1.log" | tail -1)"
[ "$BACKEND" = megalon ] && grep -h "^megalon\.\(read_sections\|read_retry_incoherent\|write_sections\|switch_rw\|flushes\|replay_flushes\)=" "$WD/node0.log" "$WD/node1.log" | tr '\n' ' ' && echo
FAIL=0
[ "$LGRC" = 0 ] || { echo "loadgen rc=$LGRC"; FAIL=1; }
[ "$(s 1 torn_rows)" = 0 ] && [ "$(s 1 misses)" = 0 ] && [ "$(s 0 update_misses)" = 0 ] || FAIL=1
[ "$(s 1 queries)" -gt 0 ] && [ "$(s 0 rows_written)" -gt 0 ] || FAIL=1
[ "$(s 1 op.query.n)" = "$(s 1 queries)" ] && [ "$(s 1 op.query.t_ns)" -gt 0 ] || { echo "op.query counters wrong"; FAIL=1; }
[ "$(s 0 op.row_update.n)" = "$(s 0 rows_written)" ] && [ "$(s 0 op.row_update.t_ns)" -gt 0 ] || { echo "op.row_update counters wrong"; FAIL=1; }
[ "$(s 1 false_retries)" -le "$(s 1 seq_retries)" ] || { echo "false_retries > seq_retries"; FAIL=1; }
if [ "$BACKEND" = megalon ]; then  # Megalon-native: one object per row, one section per lookup, no stripe table
  ROWS=$(sed -n 's/.*initial tables: \([0-9]*\) rows as [0-9]* row objects.*/\1/p' "$WD/node0.log" | tail -1)
  OBJS=$(sed -n 's/.*created \([0-9]*\) objects.*/\1/p' "$WD/node0.log" | tail -1)
  [ -n "$ROWS" ] && [ "$OBJS" = "$ROWS" ] || { echo "objects ($OBJS) != rows ($ROWS)"; FAIL=1; }
  [ "$(s 1 probes)" = "$(s 1 lookups)" ] || { echo "probes != lookups (Megalon-native: one section per lookup)"; FAIL=1; }
  [ "$(s 1 seq_retries)" = 0 ] && [ "$(s 1 seq_spins)" = 0 ] && [ "$(s 0 lock_spins)" = 0 ] || { echo "stripe table used on megalon"; FAIL=1; }
fi
[ "$FAIL" = 0 ] && echo "HOST TEST PASS ($BACKEND, T=${T} ms) -> $WD" || { echo "HOST TEST FAIL -> $WD"; exit 1; }
