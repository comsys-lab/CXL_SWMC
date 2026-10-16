#!/bin/bash
# Host functional test of kv-server (no CXL device, no VM): a /dev/shm file stands in for the device through a copy of
# the region config; two kv-server processes = node 0 and node 1 on Host NUMA node 1; loadgen drives gets and puts to
# both nodes over loopback with value checks, stats snapshots (--stats-op 10) and, with TRACE=1, the put/get logs.
# A file region is physically coherent: this checks the API use, layout, value checks and tooling, not a protocol.
# Per-operation split (opsplit.h, MOT1 v6 Fig 2): tools/opsplit.py over the stats snapshots must give get and put rows
# with T > 0, and at the clean stop opt.get.ops / opt.put.ops must equal the gets / puts counters on every node.
# C on the Host: swmc_acct unsupported (no Popcorn build 9) and, until Megalon build 71, the v1 object shim -> C = 0,
# c_supported = 0. EXPECT_COH=1 requires c_supported = 1 (a v2 shim with thread_coh) and reports the KNOWN GAP when C = 0
# for every op (Megalon <= 72 does not time the KV Put/Get path); EXPECT_COH=2 (from Megalon 73) also requires C > 0.
# usage: host_test.sh <kv build dir> <loadgen build dir> <work dir (new)> [plain|megalon]
# env: KEYS (1000000), MIX (mixed=1; or get=..,put=..), PUT_RATIO (0.5, mixed stream), RATES (2000,5000 requests/s), BATCH (32), STEP_S (5), THREADS (6), LOADER (node0),
#      TRACE (0), LG_ARGS (loadgen mode args, default --mode fixed --rates $RATES), NEG (0: 1 = second generator run that must fail the value check), PORT (27300), CPUS0/CPUS1/CPUSL, KEEP_IMG (0),
#      NR_LOG_SIZE (Megalon nr_log_size, e.g. 1MB: the shared NR log wraps every 8192 entries), STUCK_MS (stuck_timeout_ms)
set -euo pipefail
B=$(cd "$1" && pwd); LG=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd)
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
[ -e "$ROOT/../workspaces/MEASUREMENT.lock" ] && { echo "MEASUREMENT.lock present"; exit 3; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
KEYS=${KEYS:-1000000} MIX=${MIX:-mixed=1} PUT_RATIO=${PUT_RATIO:-0.5} RATES=${RATES:-2000,5000} BATCH=${BATCH:-32} THREADS=${THREADS:-6}
LOADER=${LOADER:-node0} TRACE=${TRACE:-0} PORT=${PORT:-27300}
CPUS0=${CPUS0:-18-23,50-55} CPUS1=${CPUS1:-24-29,56-61} CPUSL=${CPUSL:-30-31,62-63}  # inside the Host affinity after measure-env apply (18-31,50-63)
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
    ${NR_LOG_SIZE:+-e "s/^nr_log_size:.*/nr_log_size: $NR_LOG_SIZE/"} ${STUCK_MS:+-e "s/^stuck_timeout_ms:.*/stuck_timeout_ms: $STUCK_MS/"} \
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
  for _ in $(seq 1800); do grep -q "kv-server: READY" "$WD/node$k.log" && break; grep -q FATAL "$WD/node$k.log" && { tail -20 "$WD/node$k.log"; exit 1; }
    kill -0 "${PIDS[$k]}" 2>/dev/null || { echo "node$k exited"; tail -n 20 "$WD/node$k.log"; exit 1; }; sleep 1; done
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
OSYS=all-HWcc; [ "$BACKEND" = megalon ] && OSYS=Megalon
python3 -I "$W/tools/opsplit.py" "$WD/lg" --system "$OSYS" --out "$WD/opsplit.csv"
OPSPLIT=$(python3 -I - "$WD/opsplit.csv" "$MIX" "$PUT_RATIO" "${EXPECT_COH:-0}" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
mix, pr, want_coh, want_c = sys.argv[2], float(sys.argv[3]), sys.argv[4] in ("1", "2"), sys.argv[4] == "2"
ops = {r["op"] for r in rows}
need = {"get", "put"} if (mix != "mixed=1" or 0 < pr < 1) else ({"put"} if pr == 1 else {"get"})
bad = []
for o in need:
    rs = [r for r in rows if r["op"] == o and int(r["ops[measured]"]) > 0]
    if not rs: bad.append(f"no {o} rows with ops > 0")
    elif any(float(r["T_us_per_op[measured]"]) <= 0 for r in rs): bad.append(f"{o}: T <= 0")
for r in rows:
    c, t = float(r["C_us_per_op[derived]"]), float(r["T_us_per_op[measured]"])
    if c < 0 or (int(r["ops[measured]"]) and c > t * 1.0001 + 0.01): bad.append(f"step {r['step']} {r['op']}: C {c} outside [0, T {t}]")
    if want_coh and r["c_supported"] != "1": bad.append(f"step {r['step']} {r['op']}: c_supported 0")
    if want_c and int(r["ops[measured]"]) and c <= 0: bad.append(f"step {r['step']} {r['op']}: C = 0 (Megalon KV path not timed)")
gap = want_coh and not want_c and all(float(r["C_us_per_op[derived]"]) == 0 for r in rows)
if gap: print("KNOWN GAP: Megalon C = 0 for every KV op (Megalon <= 72 times object sections only, not rackobj Put/Get; "
              "EXPECT_COH=2 requires C > 0 from Megalon 73)", file=sys.stderr)
summ = " ".join(f"{r['step']}:{r['op']}:n={r['ops[measured]']}:T={r['T_us_per_op[measured]']}us:C={r['C_us_per_op[derived]']}us:sup={r['c_supported']}" for r in rows)
print(("OK " if not bad else "BAD " + "; ".join(bad) + " | ") + summ)
PY
)
echo "opsplit: $OPSPLIT"
echo "stats snapshots: $(ls "$WD/lg/stats" | wc -l) files; stats-steps.csv rows: $(( $(wc -l < "$WD/stats-steps.csv") - 1 ))"
g() { sed -n "s/^$1=//p" "$WD/lg/kv.txt"; }
FAIL=0
[ "$LGRC" = 0 ] || { echo "loadgen rc=$LGRC"; FAIL=1; }
for k in 0 1; do [ "$(s $k misses)" = 0 ] && [ "$(s $k short_reads)" = 0 ] && [ "$(s $k bad_requests)" = 0 ] || FAIL=1; done
[ "$(g checked)" -gt 0 ] && [ "$(g remote_values)" -gt 0 ] && [ "$(g puts)" -gt 0 ] || { echo "no checked/remote values or no puts"; FAIL=1; }
[ "$(ls "$WD/lg/stats" | wc -l)" -gt 0 ] || { echo "no stats snapshots"; FAIL=1; }
[[ $OPSPLIT == OK* ]] || { echo "opsplit check failed"; FAIL=1; }
for k in 0 1; do  # every executed op counted once in the split (clean-stop stats)
  [ "$(s $k opt.get.ops)" = "$(s $k gets)" ] && [ "$(s $k opt.put.ops)" = "$(s $k puts)" ] \
    || { echo "node$k: opt.get.ops=$(s $k opt.get.ops) gets=$(s $k gets) opt.put.ops=$(s $k opt.put.ops) puts=$(s $k puts)"; FAIL=1; }
done
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
