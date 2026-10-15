#!/bin/bash
# Host functional test of kv-server (no CXL device, no VM): a /dev/shm file stands in for the device through a copy of
# the region config; two kv-server processes = node 0 and node 1 on Host NUMA node 1; loadgen drives gets and puts to
# both nodes over loopback with value checks, stats snapshots (--stats-op 10) and, with TRACE=1, the put/get logs.
# A file region is physically coherent: this checks the API use, layout, value checks and tooling, not a protocol.
# usage: host_test.sh <kv build dir> <loadgen build dir> <work dir (new)> [plain|megalon]
# env: KEYS (1000000), MIX (mixed=1; or get=..,put=..), PUT_RATIO (0.5, mixed stream), RATES (2000,5000 requests/s), BATCH (32), STEP_S (5), THREADS (6), LOADER (node0),
#      TRACE (0), LG_ARGS (loadgen mode args, default --mode fixed --rates $RATES), NEG (0: 1 = second generator run that must fail the value check), PORT (27300), CPUS0/CPUS1/CPUSL, KEEP_IMG (0)
set -euo pipefail
B=$(cd "$1" && pwd); LG=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd)
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
[ -e "$ROOT/../workspaces/MEASUREMENT.lock" ] && { echo "MEASUREMENT.lock present"; exit 3; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
KEYS=${KEYS:-1000000} MIX=${MIX:-mixed=1} PUT_RATIO=${PUT_RATIO:-0.5} RATES=${RATES:-2000,5000} BATCH=${BATCH:-32} THREADS=${THREADS:-6}
LOADER=${LOADER:-node0} TRACE=${TRACE:-0} PORT=${PORT:-27300}
CPUS0=${CPUS0:-16-21,48-53} CPUS1=${CPUS1:-22-27,54-59} CPUSL=${CPUSL:-28-31,60-63}
IMG=${IMG:-/dev/shm/kv-test-$$.img}  # IMG + KEEP_IMG=1: reuse a region image across tests (stale-data test)
HW=$((256 << 20)) AL=$((2 << 20))
DEV=$(( (HW + KEYS * 1280 + (192 << 20) + AL - 1) / AL * AL ))  # slots + CacheNodes + NR log entries + margin
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
SA=(--nodes 2 --keys "$KEYS" --threads "$THREADS" --loader "$LOADER" --backend "$BACKEND")
APP=$("$B/bin/kv-server" "${SA[@]}" --print-app-bytes)
eval "$("$B/bin/kv-server" --print-sizes --keys "$KEYS" | grep -E '^(key_space|slots|logical_scr_size)=')"
sed -e "s/^key_space:.*/key_space: $key_space/" -e "s/^slots:.*/slots: $slots/" \
    -e "s/^logical_scr_size:.*/logical_scr_size: $logical_scr_size/" -e "s|^region_config:.*|region_config: \"$WD/region.yaml\"|" \
    "$ROOT/systems/megalon/kv-2vm.yaml" > "$WD/megalon.yaml"
truncate -s "$DEV" "$IMG"
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; [ "${KEEP_IMG:-0}" = 1 ] || rm -f "$IMG"; }
PIDS=(); trap cleanup EXIT
RID=0x$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')
XA=(); [ "$TRACE" = 1 ] && XA=(--trace-dir "$WD")
start() {  # node cpus extra-env...
  local k=$1 c=$2; shift 2
  env CXL_REGION_CONFIG="$WD/region.yaml" CXL_APP_HWCC_BYTES="$APP" RACKOBJ_CONFIG="$WD/megalon.yaml" "$@" \
    numactl --physcpubind="$c" --membind=1 "$B/bin/kv-server" --node "$k" --run-id "$RID" --port $((PORT + k)) \
    "${SA[@]}" "${XA[@]}" > "$WD/node$k.log" 2>&1 &
  PIDS+=($!)
}
T0=$(date +%s)
start 0 "$CPUS0" MEGALON_REINIT=1
start 1 "$CPUS1"
for k in 0 1; do
  for _ in $(seq 1800); do grep -q "kv-server: READY" "$WD/node$k.log" && break; grep -q FATAL "$WD/node$k.log" && { tail -20 "$WD/node$k.log"; exit 1; }; sleep 1; done
  grep -q "kv-server: READY" "$WD/node$k.log" || { echo "node$k not ready"; tail "$WD/node$k.log"; exit 1; }
done
echo "both nodes READY after $(( $(date +%s) - T0 )) s"
for k in 0 1; do echo "node$k $(grep -E '^(VmRSS|VmHWM|RssAnon|RssShmem)' /proc/${PIDS[$k]}/status | tr -s ' \t\n' ' ')"; done | tee "$WD/rss.txt"
grep -h "kv-server: \(loaded\|warm-up\|slot scan\)\|SCR footprint\|SCR used" "$WD"/node*.log | sed 's/^/  /'
set +e
numactl --physcpubind="$CPUSL" --membind=1 "$LG/loadgen" --workload kv --target 127.0.0.1:$PORT,127.0.0.1:$((PORT + 1)) \
  --out "$WD/lg" --opt keys="$KEYS" --opt batch="$BATCH" --opt put_ratio="$PUT_RATIO" --mix "$MIX" ${LG_ARGS:---mode fixed --rates $RATES} \
  --warmup-s 2 --step-warmup-s 1 --step-measure-s "${STEP_S:-5}" --drain-s 5 --stats-op 10 > "$WD/loadgen.log" 2>&1
LGRC=$?
NEGRC=skip
if [ "${NEG:-0}" = 1 ]; then  # negative check: a second generator restarts its version counts at 0, so the values the
  # first one stored look "newer than any put made" -> the value check must fail the run
  numactl --physcpubind="$CPUSL" --membind=1 "$LG/loadgen" --workload kv --target 127.0.0.1:$PORT,127.0.0.1:$((PORT + 1)) \
    --out "$WD/lg-neg" --opt keys="$KEYS" --opt batch="$BATCH" --opt put_ratio="$PUT_RATIO" --mode fixed --mix "$MIX" --rates 1000 \
    --warmup-s 1 --step-warmup-s 1 --step-measure-s 2 --drain-s 2 > "$WD/loadgen-neg.log" 2>&1
  NEGRC=$?
fi
set -e
kill -TERM "${PIDS[@]}"; wait 2>/dev/null || true; PIDS=()
tail -4 "$WD/loadgen.log"
cat "$WD/lg/kv.txt"
s() { sed -n "s/^$2=//p" "$WD/node$1.log" | tail -1; }
for k in 0 1; do echo "node$k: gets=$(s $k gets) puts=$(s $k puts) misses=$(s $k misses) short_reads=$(s $k short_reads) bad_requests=$(s $k bad_requests) trace.puts=$(s $k trace.puts) trace.gets=$(s $k trace.gets)"; done
python3 "$ROOT/experiments/loadgen/stats_delta.py" "$WD/lg" --out "$WD/stats-steps.csv" > /dev/null
echo "stats snapshots: $(ls "$WD/lg/stats" | wc -l) files; stats-steps.csv rows: $(( $(wc -l < "$WD/stats-steps.csv") - 1 ))"
g() { sed -n "s/^$1=//p" "$WD/lg/kv.txt"; }
FAIL=0
[ "$LGRC" = 0 ] || { echo "loadgen rc=$LGRC"; FAIL=1; }
for k in 0 1; do [ "$(s $k misses)" = 0 ] && [ "$(s $k short_reads)" = 0 ] && [ "$(s $k bad_requests)" = 0 ] || FAIL=1; done
[ "$(g checked)" -gt 0 ] && [ "$(g remote_values)" -gt 0 ] && [ "$(g puts)" -gt 0 ] || { echo "no checked/remote values or no puts"; FAIL=1; }
[ "$(ls "$WD/lg/stats" | wc -l)" -gt 0 ] || { echo "no stats snapshots"; FAIL=1; }
if [ "$NEGRC" != skip ]; then
  echo "negative check: loadgen rc=$NEGRC future=$(sed -n 's/^future=//p' "$WD/lg-neg/kv.txt")"
  [ "$NEGRC" != 0 ] && [ "$(sed -n 's/^future=//p' "$WD/lg-neg/kv.txt")" -gt 0 ] || { echo "negative check did not fail"; FAIL=1; }
fi
if [ "$TRACE" = 1 ]; then
  python3 "$W/tools/kvlog.py" check "$WD" | sed 's/^/  /'
  python3 "$W/tools/kvlog.py" check "$WD" > /dev/null || FAIL=1
  for k in 0 1; do [ "$(s $k trace.puts)" = "$(s $k puts)" ] || { echo "node$k: trace.puts != puts"; FAIL=1; }; done
fi
[ "$FAIL" = 0 ] && echo "HOST TEST PASS ($BACKEND, keys=$KEYS, mix=$MIX, put_ratio=$PUT_RATIO, batch=$BATCH, trace=$TRACE) -> $WD" || { echo "HOST TEST FAIL -> $WD"; exit 1; }
