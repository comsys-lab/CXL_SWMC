#!/bin/bash
# Host functional test of the shared LMDB (DESIGN.md §6). Two processes = two nodes over a sparse file standing in for
# the device (a copy of config/cxl_region.yaml with device = file, explicit device_size). Touches no /dev/dax*, no VM.
# A file region is hardware coherent, so this proves the protocol logic and the API usage, not coherence itself.
#   1 lmdb-image (N records, MDB_APPEND)
#   2 lmdb-stress plain: cross-node snapshot isolation under page reuse (both nodes write and read)
#   3 negative control: node 0's writer ignores node 1's reader slots -> the test must FAIL
#   4 lmdb-server x2 plain via --preload-only/--preloaded (Popcorn path) + loadgen (mixed stream, update_ratio
#     UPDATE_RATIO, default 0.5) with log=1, check_log.py (exact MVCC check), verify op on both nodes, stats op,
#     per-operation split (workloads/kv/tools/opsplit.py: get and update rows with T > 0, C within [0, T]; at the
#     clean stop opt.get.ops = gets + not-found + errors, opt.update.ops = updates + not-found + errors,
#     opt.update.mod_bytes = 1000 x updates). C = 0 on the Host (no swmc_acct; Megalon v1 shim until build 71;
#     EXPECT_COH=1 requires c_supported = 1 on the megalon backend)
#   5 (MEGALON_BUILD set) 2 and 4 with --backend megalon
# usage: host_test.sh <work dir (new)> <lmdb build dir> <loadgen build dir with the lmdb plugin> [records (100000)]
#        env: MEGALON_BUILD=<lmdb build with lib/> to add step 5; NEG_BUILD=<dir with bin/lmdb-stress-negative>
#        CPUS0 / CPUS1 / CPUSL (node0 / node1 / loadgen CPU lists, default Host node1: 18-23,50-55 / 24-29,56-61 / 30-31,62-63)
set -uo pipefail
WD=$1; B=$(cd "$2" && pwd); LG=$(cd "$3" && pwd); N=${4:-100000}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd)
NEG=${NEG_BUILD:+$(cd "$NEG_BUILD" && pwd)}; MB=${MEGALON_BUILD:+$(cd "$MEGALON_BUILD" && pwd)}
C0=${CPUS0:-18-23,50-55}; C1=${CPUS1:-24-29,56-61}; CL=${CPUSL:-30-31,62-63}  # Megalon: >= 6 CPUs per node (4 readers + writer + its own threads; fewer: readers descheduled, MAP_FULL)
mkdir "$WD" || exit 2; WD=$(cd "$WD" && pwd); cd "$WD"
MAXP=$(( N * 6 / 10 + 4096 ))   # ~1.8 x the image's pages: forces freelist page reuse
RESULT=0
fail() { echo "STEP FAIL: $*"; RESULT=1; }
rid() { printf '0x%x' $(( $(date +%s%N) & 0xffffffffff | 1 )); }
truncate -s 2G region.img
cat > region.yaml <<EOF
# Host test region: copy of CXL_SWMC/config/cxl_region.yaml with a sparse file standing in for the device
device: $WD/region.img
map_va: 0x600000000000
device_size: 2147483648
align: 2097152
hwcc_offset: 0
hwcc_size: 268435456
msg_ring: [268300288, 135168]
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
export CXL_APP_HWCC_BYTES=$("$B/bin/lmdb-server" --print-app-bytes --max-pages $MAXP --records $N)
echo "records=$N max_pages=$MAXP app_bytes=$CXL_APP_HWCC_BYTES build=$B loadgen=$LG"
grep -E '^(source|liblmdb|sha256)' "$B/manifest.txt"

echo "== 1 image"
taskset -c "$C0" "$B/bin/lmdb-image" --out img --records $N --batch 10000 2> image.log || fail image
tail -1 image.log

stress() {  # <tag> <bin> <extra env for node 0> <backend args>
  local tag=$1 bin=$2 env0=$3; shift 3
  local r; r=$(rid)
  local P=(--nodes 2 --run-id "$r" --region "$WD/region.yaml" --max-pages $MAXP --records $N --seconds 8
           --reader-threads 4 --read-keys 8 --hold-us 2000 --keys-per-txn 4 "$@")
  env $env0 taskset -c "$C0" "$bin" --node 0 --image img "${P[@]}" ${NODE0_EXTRA:-} > "$tag.0.out" 2> "$tag.0.err" &
  local p0=$!
  sleep 1
  taskset -c "$C1" "$bin" --node 1 "${P[@]}" > "$tag.1.out" 2> "$tag.1.err"; local r1=$?
  wait $p0; local r0=$?
  cat "$tag.0.out" "$tag.1.out"
  echo "$tag rc0=$r0 rc1=$r1"
  return $(( r0 || r1 ))
}

echo "== 2 stress plain"
stress stress-plain "$B/bin/lmdb-stress" "" --backend plain || fail "stress plain"

if [ -n "$NEG" ]; then
  echo "== 3 negative control (node 0 has no readers and its writer scans only its own slots 0:32, i.e. ignores"
  echo "   node 1's readers; node 1 keeps the full rule; must FAIL)"
  NODE0_EXTRA="--reader-threads 0" stress stress-negative "$NEG/bin/lmdb-stress-negative" "MDB_CXL_TEST_SCAN=0:32" --backend plain
  # must have run to the end on both nodes and reported a violation on at least one
  if [ "$(grep -c 'RESULT' stress-negative.0.out stress-negative.1.out | awk -F: '{s+=$2} END {print s}')" = 2 ] &&
     grep -q 'RESULT FAIL' stress-negative.0.out stress-negative.1.out; then
    echo "negative control detected the violation: OK"
  else fail "negative control did not detect a broken oldest-reader rule (or did not run)"; fi
fi

serve() {  # <tag> <bin dir> <backend> [node0 env...]: servers, loadgen (log=1), check_log, verify both nodes
  local tag=$1 bd=$2 be=$3; shift 3
  local r; r=$(rid)
  local P=(--nodes 2 --run-id "$r" --region "$WD/region.yaml" --max-pages $MAXP --records $N --get-threads 4
           --readers 8 --backend "$be")
  local pre=()
  if [ "$be" = plain ]; then
    "$bd/bin/lmdb-server" --node 0 --nodes 2 --region "$WD/region.yaml" --max-pages $MAXP --records $N --readers 8 \
      --image img --preload-only 2> "$tag.preload.log" || { fail "$tag preload"; return; }
    tail -1 "$tag.preload.log"; pre=(--preloaded)
  fi
  env "$@" taskset -c "$C0" "$bd/bin/lmdb-server" --node 0 --port 17100 --image img "${pre[@]}" "${P[@]}" > "$tag.srv0.log" 2>&1 &
  sleep 1
  taskset -c "$C1" "$bd/bin/lmdb-server" --node 1 --port 17101 "${P[@]}" > "$tag.srv1.log" 2>&1 &
  for _ in $(seq 1200); do grep -q READY "$tag.srv0.log" && grep -q READY "$tag.srv1.log" && break
    grep -q FATAL "$tag.srv0.log" "$tag.srv1.log" && break; sleep 0.5; done
  grep -h "lmdb-server: \(loaded\|published\|READY\|FATAL\)" "$tag.srv0.log" "$tag.srv1.log"
  if ! grep -q READY "$tag.srv0.log" || ! grep -q READY "$tag.srv1.log"; then
    fail "$tag servers not READY"; tail -5 "$tag.srv0.log" "$tag.srv1.log"; pkill -x lmdb-server; return; fi
  taskset -c "$CL" "$LG/loadgen" --workload lmdb --target 127.0.0.1:17100,127.0.0.1:17101 --out "$tag.lg" \
    --opt records=$N --opt log=1 --opt update_ratio=${UPDATE_RATIO:-0.5} --mode fixed --rates ${RATES:-500,2000} --mix mixed=1 --warmup-s 2 \
    --step-warmup-s 1 --step-measure-s 5 --drain-s 5 --stats-op 10 > "$tag.lg.log" 2>&1 || fail "$tag loadgen"
  tail -3 "$tag.lg.log"; cat "$tag.lg/lmdb.txt" | head -8
  python3 -I "$W/tools/check_log.py" "$tag.lg" || fail "$tag check_log"
  for port in 17100 17101; do
    "$W/tools/lmdb_ctl.py" 127.0.0.1:$port verify --expect verify.entries=$N verify.bad_values=0 verify.misordered=0 \
      verify.end=ok > "$tag.verify.$port.txt" || fail "$tag verify $port"
    tr '\n' ' ' < "$tag.verify.$port.txt"; echo
  done
  "$W/tools/lmdb_ctl.py" 127.0.0.1:17100 stats > "$tag.stats0.txt" || fail "$tag stats"
  grep -E '^(gets|updates|update_lock_ns|update_commit_ns|lmdb\.page_writes|lmdb\.oldest_lag_max|megalon\.(write_sections|flushes|switch_rw))=' "$tag.stats0.txt" | tr '\n' ' '; echo
  local osys=all-HWcc; [ "$be" = megalon ] && osys=Megalon
  python3 -I "$W/../kv/tools/opsplit.py" "$tag.lg" --system $osys --out "$tag.opsplit.csv" || fail "$tag opsplit"
  python3 -I - "$tag.opsplit.csv" "${EXPECT_COH:-0}" <<'PY' || fail "$tag opsplit check"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]))); bad = []
for o in ("get", "update"):
    rs = [r for r in rows if r["op"] == o and int(r["ops[measured]"]) > 0]
    if not rs or any(float(r["T_us_per_op[measured]"]) <= 0 for r in rs): bad.append(f"{o}: no rows with ops > 0 and T > 0")
for r in rows:
    c, t = float(r["C_us_per_op[derived]"]), float(r["T_us_per_op[measured]"])
    if c < 0: bad.append(f"{r['step']} {r['op']}: C {c} < 0")
    if c > t * 1.0001 + 0.01:  # Megalon sampled C: WARN only (user decision 2026-10-17: Fig 2 C = C_diff)
        (print(f"WARN {r['step']} {r['op']}: sampled C {c} > T {t}") if r["c_source"] == "megalon"
         else bad.append(f"{r['step']} {r['op']}: C {c} > T {t}"))
    if sys.argv[2] == "1" and r["c_supported"] != "1": bad.append(f"{r['step']} {r['op']}: c_supported 0")
print("opsplit:", "OK" if not bad else "BAD " + "; ".join(bad),
      " ".join(f"{r['step']}:{r['op']}:n={r['ops[measured]']}:T={r['T_us_per_op[measured]']}us:C={r['C_us_per_op[derived]']}us:mod={r['mod_bytes_per_op[measured]']}:sup={r['c_supported']}" for r in rows))
sys.exit(1 if bad else 0)
PY
  pkill -x lmdb-server; sleep 2
  for k in 0 1; do  # every executed operation counted once in the split (clean-stop stats)
    local L=$tag.srv$k.log
    v() { sed -n "s/^$1=//p" "$L" | tail -1; }
    grep -q "lmdb-server: stopping" "$L" || { fail "$tag node$k: no clean stop"; continue; }
    [ "$(v opt.get.ops)" = $(( $(v gets) + $(v get_not_found) + $(v get_errors) )) ] &&
    [ "$(v opt.update.ops)" = $(( $(v updates) + $(v update_not_found) + $(v update_errors) )) ] &&
    [ "$(v opt.update.mod_bytes)" = $(( 1000 * $(v updates) )) ] || fail "$tag node$k: opt counts (get $(v opt.get.ops)/$(v gets) update $(v opt.update.ops)/$(v updates) mod $(v opt.update.mod_bytes))"
  done
}

echo "== 4 servers plain (preload path) + loadgen"
serve srv-plain "$B" plain

if [ -n "$MB" ]; then
  sed -e 's/^object_arena_size: .*/object_arena_size: 1GB/' "$W/config/megalon-2vm.yaml" > megalon.yaml
  export RACKOBJ_CONFIG=$WD/megalon.yaml
  echo "== 5a stress megalon"
  stress stress-megalon "$MB/bin/lmdb-stress" "MEGALON_REINIT=1" --backend megalon || fail "stress megalon"
  echo "== 5b servers megalon + loadgen"
  RATES=${MRATES:-200,600} serve srv-megalon "$MB" megalon MEGALON_REINIT=1
fi
rm -f region.img
echo "HOST TEST $([ $RESULT = 0 ] && echo PASS || echo FAIL)"
exit $RESULT
