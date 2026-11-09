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
#        env: CPUS0 / CPUS1 / CPUSL (node0 / node1 / loadgen CPU lists), RATES, STEP_S, UPDATE_RATIO, WBMB,
#             BACKEND=megalon (the build must carry lib/libmegalon-objapi.so; MEG_EXTENTS file extents per node),
#             REGION_GB (sparse region file size, 8; 96 with MEG_EXTENTS=45000 = the VM object count, eval run2),
#             READY_S (server READY wait in s, 600; the full-size 27M keys/node image needs longer),
#             megalon-record: MEG_MEM_OBJ / MEG_FILE_OBJ (object bytes, e.g. 1152 / 4096), MEG_YAML (Megalon config, default
#             config/megalon-2vm.yaml; MEG_KEEP_ARENA=1 keeps its object_arena_size), ARENA_BLOCKS (256), REGION_BYTES
#             (exact region size, overrides REGION_GB), RING2M=1 (msg_ring of config/cxl_region-ring2m.yaml)
set -uo pipefail
WD=$1; B=$(cd "$2" && pwd); LG=$(cd "$3" && pwd); N=${4:-200000}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd)
C0=${CPUS0:-18-20,50-52}; C1=${CPUS1:-21-23,53-55}; CL=${CPUSL:-18-23,50-55}  # Host sys partition (measure.slice CPUs are exclusive)
CTL=$W/../lmdb/tools/lmdb_ctl.py  # same stats (10) / verify (11) ops
mkdir "$WD" || exit 2; WD=$(cd "$WD" && pwd); cd "$WD"
RESULT=0
fail() { echo "STEP FAIL: $*"; RESULT=1; }
rid() { printf '0x%x' $(( $(date +%s%N) & 0xffffffffff | 1 )); }
RGB=${REGION_GB:-8}; [[ $RGB =~ ^[1-9][0-9]*$ ]] || { echo "bad REGION_GB"; exit 2; }
RBYTES=${REGION_BYTES:-$(( RGB << 30 ))}; [[ $RBYTES =~ ^[1-9][0-9]*$ ]] || { echo "bad REGION_BYTES"; exit 2; }
RING="[268300288, 135168]"; [ "${RING2M:-0}" = 1 ] && RING="[266338304, 2097152]"
truncate -s "$RBYTES" region.img
cat > region.yaml <<EOF
# Host test region: copy of CXL_SWMC/config/cxl_region.yaml with a sparse file standing in for the device
device: $WD/region.img
map_va: 0x600000000000
device_size: $RBYTES
align: 2097152
hwcc_offset: 0
hwcc_size: 268435456
msg_ring: $RING
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
BACKEND=${BACKEND:-plain}
AB=${ARENA_BLOCKS:-256}
SP=(--keys $N --arena-blocks $AB)
BE=(); ENV0=(); XOBJ=0
if [ "$BACKEND" = megalon ]; then
  EXT=${MEG_EXTENTS:-1024}
  SP+=(--file-extents $EXT --backend megalon)
  MY=${MEG_YAML:-$W/config/megalon-2vm.yaml}
  if [ "${MEG_KEEP_ARENA:-0}" = 1 ]; then cp "$MY" megalon.yaml
  else sed -e "s/^object_arena_size: .*/object_arena_size: $(( (2 * (AB + EXT) + 64) / 1024 + 1 ))GB/" "$MY" > megalon.yaml; fi
  export RACKOBJ_CONFIG=$WD/megalon.yaml
  ENV0=(MEGALON_REINIT=1)
  [ -z "${MEG_MEM_OBJ:-}" ] || SP+=(--mg-mem-object-bytes "$MEG_MEM_OBJ")
  [ -z "${MEG_FILE_OBJ:-}" ] || SP+=(--mg-file-object-bytes "$MEG_FILE_OBJ")
  [ -z "${MEG_MEM_OBJ:-}${MEG_FILE_OBJ:-}" ] || \
    XOBJ=$(( 2 * (AB * (1048576 / ${MEG_MEM_OBJ:-1048576}) + EXT * (1048576 / ${MEG_FILE_OBJ:-1048576})) ))
fi
export EXPECT_OBJECTS=$XOBJ
export CXL_APP_HWCC_BYTES=$("$B/bin/rocksdb-server" --print-app-bytes "${SP[@]}")
echo "keys=$N app_bytes=$CXL_APP_HWCC_BYTES build=$B loadgen=$LG"
grep -E '^(source|rocksdb_version|patch|sha256)' "$B/manifest.txt"

R=$(rid)
P=(--nodes 2 --run-id "$R" --region "$WD/region.yaml" --threads 4 --write-buffer-mb ${WBMB:-4} --prepare-threads 2 "${SP[@]}")
env "${ENV0[@]}" taskset -c "$C0" "$B/bin/rocksdb-server" --node 0 --port 17200 --local-dir "$WD/local0" "${P[@]}" > srv0.log 2>&1 &
SRV0=$!
taskset -c "$C1" "$B/bin/rocksdb-server" --node 1 --port 17201 --local-dir "$WD/local1" "${P[@]}" > srv1.log 2>&1 &
SRV1=$!
for _ in $(seq $(( ${READY_S:-600} * 2 ))); do grep -q READY srv0.log && grep -q READY srv1.log && break
  grep -q FATAL srv0.log srv1.log && break; sleep 0.5; done
grep -h "rocksdb-server: \(node\|IMAGE\|primary\|READY\|FATAL\)" srv0.log srv1.log
if ! grep -q READY srv0.log || ! grep -q READY srv1.log; then
  fail "servers not READY"; tail -5 srv0.log srv1.log; kill $SRV0 $SRV1 2>/dev/null
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
import os, sys
bad = []
for f in sys.argv[1:]:
    s = dict(l.split("=", 1) for l in open(f).read().splitlines() if "=" in l)
    g = lambda k: int(s.get(k, "0"))
    r = [k.split(".")[0] for k in s if k.startswith("remote") and k.endswith(".gets")][0]
    print(f, " ".join(f"{k}={s.get(k)}" for k in ("gets", "updates", "remote_errors", "desc_installs", "gc.checked",
          "gc.dropped", r + ".gets", r + ".mem_hits", r + ".sst_hits", r + ".catchups", r + ".sync_catchups",
          r + ".catchup_errors", "rocksdb.num-files-at-level0", "rocksdb.total-sst-files-size", "pools")))
    for k in ("remote_errors", "get_errors", "update_errors", "get_retry_limit", r + ".errors", r + ".catchup_errors"):
        if g(k): bad.append(f"{f}: {k}={g(k)}")
    for k in ("desc_installs", r + ".mem_hits", r + ".sst_hits", r + ".catchups", "gc.checked"):
        if not g(k): bad.append(f"{f}: {k}=0 (path not exercised)")
    if "rdb.arena_slot_allocs" in s:  # megalon-record: no entry across a slot, objects, sections, record counters
        print(f, " ".join(f"{k}={s.get(k)}" for k in ("rdb.objects", "megalon.created", "rdb.arena_slot_allocs", "rdb.arena_slot_cross",
              "rdb.arena_slot_max_bytes", "rdb.mem_read_cross_slot", "rdb.mem_write_sections", "rdb.mem_read_sections",
              "rdb.file_write_sections", "rdb.file_read_sections", "rdb.read_retries", "rdb.mem_read_tail_clamps",
              "megalon.record_slots", "megalon.reclaim_count", "megalon.allocate_count", "megalon.records_in_use")))
        for k in ("rdb.arena_slot_cross", "rdb.mem_read_cross_slot"):
            if g(k): bad.append(f"{f}: {k}={g(k)}")
        for k in ("rdb.arena_slot_allocs", "rdb.mem_write_sections", "rdb.mem_read_sections", "rdb.file_write_sections",
                  "rdb.file_read_sections", "megalon.record_slots", "megalon.allocate_count"):
            if not g(k): bad.append(f"{f}: {k}=0 (path not exercised)")
        if g("rdb.arena_slot_max_bytes") > g("rdb.mem_object_bytes"): bad.append(f"{f}: an allocation exceeds the slot")
        want = int(os.environ.get("EXPECT_OBJECTS", "0"))
        if want and (g("rdb.objects") != want or g("megalon.created") != want):
            bad.append(f"{f}: objects {g('rdb.objects')} / created {g('megalon.created')} != {want}")
print("stats:", "OK" if not bad else "BAD " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY

echo "== 4 opsplit"
python3 -I "$W/../kv/tools/opsplit.py" lg --system $([ "$BACKEND" = megalon ] && echo Megalon || echo all-HWcc) --out opsplit.csv || fail opsplit
python3 -I - opsplit.csv <<'PY' || fail "opsplit check"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]))); bad = []
for o in ("get", "update"):
    rs = [r for r in rows if r["op"] == o and int(r["ops[measured]"]) > 0]
    if not rs or any(float(r["T_us_per_op[measured]"]) <= 0 for r in rs): bad.append(f"{o}: no rows with ops > 0 and T > 0")
for r in rows:
    c, t = float(r["C_us_per_op[derived]"]), float(r["T_us_per_op[measured]"])
    if c < 0: bad.append(f"{r['step']} {r['op']}: C {c} < 0")
    if c > t * 1.0001 + 0.01:  # Megalon sampled C may exceed T: WARN only (as workloads/lmdb/tests/host_test.sh)
        (print(f"WARN {r['step']} {r['op']}: sampled C {c} > T {t}") if r["c_source"] == "megalon"
         else bad.append(f"{r['step']} {r['op']}: C {c} > T {t}"))
print("opsplit:", "OK" if not bad else "BAD " + "; ".join(bad),
      " ".join(f"{r['step']}:{r['op']}:n={r['ops[measured]']}:T={r['T_us_per_op[measured]']}us" for r in rows))
sys.exit(1 if bad else 0)
PY
kill $SRV0 $SRV1 2>/dev/null; sleep 2
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
