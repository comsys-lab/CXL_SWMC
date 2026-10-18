#!/bin/bash
# Host functional test of the rocksdb workload (DESIGN.md). Two processes = two nodes over a sparse file standing in
# for the device (a copy of config/cxl_region.yaml with device = file, explicit device_size). Touches no /dev/dax*,
# no VM. A file region is hardware coherent, so this proves the protocol logic and the API use, not coherence.
#   1 rocksdb-server x2 (plain): image of N keys split by key across the nodes, small memtables (--write-buffer-mb)
#     so the run flushes and compacts (descriptor gens, sync catch-ups, deferred frees, G1 drops)
#   2 loadgen mixed stream (update_ratio UPDATE_RATIO, default 0.5) at RATES: plugin checks (complete values of the
#     right key, per-key read-after-ack freshness across nodes, no not-found, no errors); tools/check_log.py on the
#     log (every value read = the exact update with its stamp, unique stamps)
#   3 verify op on both nodes (every entry of each node's DB complete and ordered), stats op, expected activity
#   4 opsplit rows (get/update with T > 0, C within [0, T]) and clean-stop counts
# usage: host_test.sh <work dir (new)> <rocksdb build dir> <loadgen build dir with the rocksdb plugin> [keys (200000)]
#        env: CPUS0 / CPUS1 / CPUSL (node0 / node1 / loadgen CPU lists), RATES, STEP_S, UPDATE_RATIO, WBMB
set -uo pipefail
WD=$1; B=$(cd "$2" && pwd); LG=$(cd "$3" && pwd); N=${4:-200000}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd)
C0=${CPUS0:-18-20,50-52}; C1=${CPUS1:-21-23,53-55}; CL=${CPUSL:-18-23,50-55}  # Host sys partition (measure.slice CPUs are exclusive)
CTL=$W/../lmdb/tools/lmdb_ctl.py  # same stats (10) / verify (11) ops
mkdir "$WD" || exit 2; WD=$(cd "$WD" && pwd); cd "$WD"
RESULT=0
fail() { echo "STEP FAIL: $*"; RESULT=1; }
rid() { printf '0x%x' $(( $(date +%s%N) & 0xffffffffff | 1 )); }
truncate -s 8G region.img
cat > region.yaml <<EOF
# Host test region: copy of CXL_SWMC/config/cxl_region.yaml with a sparse file standing in for the device
device: $WD/region.img
map_va: 0x600000000000
device_size: 8589934592
align: 2097152
hwcc_offset: 0
hwcc_size: 268435456
msg_ring: [268300288, 135168]
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
SP=(--keys $N --arena-blocks 256)
export CXL_APP_HWCC_BYTES=$("$B/bin/rocksdb-server" --print-app-bytes "${SP[@]}")
echo "keys=$N app_bytes=$CXL_APP_HWCC_BYTES build=$B loadgen=$LG"
grep -E '^(source|rocksdb_version|patch|sha256)' "$B/manifest.txt"

R=$(rid)
P=(--nodes 2 --run-id "$R" --region "$WD/region.yaml" --threads 4 --write-buffer-mb ${WBMB:-4} --prepare-threads 2 "${SP[@]}")
taskset -c "$C0" "$B/bin/rocksdb-server" --node 0 --port 17200 --local-dir "$WD/local0" "${P[@]}" > srv0.log 2>&1 &
taskset -c "$C1" "$B/bin/rocksdb-server" --node 1 --port 17201 --local-dir "$WD/local1" "${P[@]}" > srv1.log 2>&1 &
for _ in $(seq 1200); do grep -q READY srv0.log && grep -q READY srv1.log && break
  grep -q FATAL srv0.log srv1.log && break; sleep 0.5; done
grep -h "rocksdb-server: \(node\|IMAGE\|primary\|READY\|FATAL\)" srv0.log srv1.log
if ! grep -q READY srv0.log || ! grep -q READY srv1.log; then
  fail "servers not READY"; tail -5 srv0.log srv1.log; pkill -x rocksdb-server
  echo "HOST TEST FAIL"; exit 1
fi

echo "== 2 loadgen"
taskset -c "$CL" "$LG/loadgen" --workload rocksdb --target 127.0.0.1:17200,127.0.0.1:17201 --out lg \
  --opt keys=$N --opt log=1 --opt update_ratio=${UPDATE_RATIO:-0.5} --mode fixed --rates ${RATES:-4000,12000} --mix mixed=1 \
  --warmup-s 2 --step-warmup-s 1 --step-measure-s ${STEP_S:-15} --drain-s 5 --stats-op 10 > lg.log 2>&1 || fail loadgen
tail -3 lg.log; head -9 lg/rocksdb.txt
python3 -I "$W/tools/check_log.py" lg || fail check_log

echo "== 3 verify + stats"
for port in 17200 17201; do
  python3 -I "$CTL" 127.0.0.1:$port verify --expect verify.bad_values=0 verify.misordered=0 verify.end=ok \
    > verify.$port.txt || fail "verify $port"
  tr '\n' ' ' < verify.$port.txt; echo
  python3 -I "$CTL" 127.0.0.1:$port stats > stats.$port.txt || fail "stats $port"
done
python3 -I - stats.17200.txt stats.17201.txt <<'PY' || fail "stats check"
import sys
bad = []
for f in sys.argv[1:]:
    s = dict(l.split("=", 1) for l in open(f).read().splitlines() if "=" in l)
    g = lambda k: int(s.get(k, "0"))
    r = [k.split(".")[0] for k in s if k.startswith("remote") and k.endswith(".gets")][0]
    print(f, " ".join(f"{k}={s.get(k)}" for k in ("gets", "updates", "remote_errors", "desc_installs", "gc.checked",
          "gc.dropped", r + ".gets", r + ".mem_hits", r + ".sst_hits", r + ".catchups", r + ".sync_catchups",
          r + ".catchup_errors", "rocksdb.num-files-at-level0", "rocksdb.total-sst-files-size", "pools")))
    for k in ("remote_errors", "get_errors", "update_errors", r + ".errors", r + ".catchup_errors"):
        if g(k): bad.append(f"{f}: {k}={g(k)}")
    for k in ("desc_installs", r + ".mem_hits", r + ".sst_hits", r + ".catchups", "gc.checked"):
        if not g(k): bad.append(f"{f}: {k}=0 (path not exercised)")
print("stats:", "OK" if not bad else "BAD " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY

echo "== 4 opsplit"
python3 -I "$W/../kv/tools/opsplit.py" lg --system all-HWcc --out opsplit.csv || fail opsplit
python3 -I - opsplit.csv <<'PY' || fail "opsplit check"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]))); bad = []
for o in ("get", "update"):
    rs = [r for r in rows if r["op"] == o and int(r["ops[measured]"]) > 0]
    if not rs or any(float(r["T_us_per_op[measured]"]) <= 0 for r in rs): bad.append(f"{o}: no rows with ops > 0 and T > 0")
for r in rows:
    c, t = float(r["C_us_per_op[derived]"]), float(r["T_us_per_op[measured]"])
    if c < 0 or c > t * 1.0001 + 0.01: bad.append(f"{r['step']} {r['op']}: C {c} T {t}")
print("opsplit:", "OK" if not bad else "BAD " + "; ".join(bad),
      " ".join(f"{r['step']}:{r['op']}:n={r['ops[measured]']}:T={r['T_us_per_op[measured]']}us" for r in rows))
sys.exit(1 if bad else 0)
PY
pkill -x rocksdb-server; sleep 2
for k in 0 1; do
  L=srv$k.log
  v() { sed -n "s/^$1=//p" "$L" | tail -1; }
  grep -q "rocksdb-server: stopping" "$L" || { fail "node$k: no clean stop"; continue; }
  [ "$(v opt.get.ops)" = $(( $(v gets) + $(v get_not_found) + $(v get_errors) )) ] &&
  [ "$(v opt.update.ops)" = $(( $(v updates) + $(v update_errors) )) ] &&
  [ "$(v opt.update.mod_bytes)" = $(( 1000 * $(v updates) )) ] || fail "node$k: opt counts"
done
rm -f region.img
echo "HOST TEST $([ $RESULT = 0 ] && echo PASS || echo FAIL)"
exit $RESULT
