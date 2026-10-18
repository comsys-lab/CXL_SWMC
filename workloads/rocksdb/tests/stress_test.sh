#!/bin/bash
# Host stress test of the rocksdb workload's memory reuse (verifier MED-2, 2026-10-18): tiny pools so freed arena
# blocks, file extents and directory slots are reused within the run, tiny MANIFEST limit so MANIFESTs roll, and
# update-only phases (no gets, so no reader epochs while compactions delete files) between mixed phases. A file
# or memtable freed while a remote view still used it shows up as a remote error, a bad value or a stale read.
# Touches no /dev/dax*, no VM.
# Negative control: a rocksdb-server compiled with -DRDB_NEGATIVE_NO_PIN (the remote view drops its pin, i.e. the
# HIGH-1 bug) must FAIL here (observed 2026-10-18: remote0.errors=57, "truncated block read" of reclaimed SSTs).
# usage: stress_test.sh <work dir (new)> <rocksdb build dir> <loadgen build dir> [keys (100000)]
#        env: CPUS0 / CPUS1 / CPUSL, RATE (6000), PHASE_S (12), ROUNDS (3)
set -uo pipefail
WD=$1; B=$(cd "$2" && pwd); LG=$(cd "$3" && pwd); N=${4:-100000}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd)
C0=${CPUS0:-18-20,50-52}; C1=${CPUS1:-21-23,53-55}; CL=${CPUSL:-18-23,50-55}  # Host sys partition
CTL=$W/../lmdb/tools/lmdb_ctl.py
mkdir "$WD" || exit 2; WD=$(cd "$WD" && pwd); cd "$WD"
RESULT=0
fail() { echo "STEP FAIL: $*"; RESULT=1; }
rid() { printf '0x%x' $(( $(date +%s%N) & 0xffffffffff | 1 )); }
truncate -s 4G region.img
cat > region.yaml <<EOF
device: $WD/region.img
map_va: 0x600000000000
device_size: 4294967296
align: 2097152
hwcc_offset: 0
hwcc_size: 268435456
msg_ring: [268300288, 135168]
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
ARENA=12; EXT=200; FILES=160
SP=(--keys $N --arena-blocks $ARENA --file-extents $EXT --max-files $FILES --max-ext 8 --epoch-slots 32)
export CXL_APP_HWCC_BYTES=$("$B/bin/rocksdb-server" --print-app-bytes "${SP[@]}")
echo "keys=$N arena_blocks=$ARENA file_extents=$EXT max_files=$FILES max_ext=8 app_bytes=$CXL_APP_HWCC_BYTES"
P=(--nodes 2 --run-id "$(rid)" --region "$WD/region.yaml" --threads 4 --write-buffer-mb 2 --target-file-mb 4
   --max-manifest-kb 64 --prepare-threads 2 "${SP[@]}")
taskset -c "$C0" "$B/bin/rocksdb-server" --node 0 --port 17300 --local-dir "$WD/local0" "${P[@]}" > srv0.log 2>&1 &
taskset -c "$C1" "$B/bin/rocksdb-server" --node 1 --port 17301 --local-dir "$WD/local1" "${P[@]}" > srv1.log 2>&1 &
for _ in $(seq 600); do grep -q READY srv0.log && grep -q READY srv1.log && break
  grep -q FATAL srv0.log srv1.log && break; sleep 0.5; done
grep -h "rocksdb-server: \(IMAGE\|READY\|FATAL\)" srv0.log srv1.log
if ! grep -q READY srv0.log || ! grep -q READY srv1.log; then
  fail "servers not READY"; tail -5 srv0.log srv1.log; kill %1 %2 2>/dev/null; echo "STRESS TEST FAIL"; exit 1
fi
lg() {  # <tag> <mix> [update_ratio]
  taskset -c "$CL" "$LG/loadgen" --workload rocksdb --target 127.0.0.1:17300,127.0.0.1:17301 --out "lg-$1" \
    --opt keys=$N --opt update_ratio=${3:-0.5} --mode fixed --rates ${RATE:-6000} --mix "$2" --warmup-s 0 \
    --step-warmup-s 0 --step-measure-s ${PHASE_S:-12} --drain-s 3 > "lg-$1.log" 2>&1 || fail "loadgen $1"
  echo "$1: $(grep -E '^(gets_ok|updates_ok|not_found|errors|bad_values|stale_reads)=' "lg-$1/rocksdb.txt" | tr '\n' ' ')"
}
for r in $(seq ${ROUNDS:-3}); do
  lg "upd$r" update=1        # writes only: compactions delete files while no get holds an epoch
  lg "mix$r" mixed=1 0.5     # gets over every node's memtables and (reused) SSTs
done
for port in 17300 17301; do
  python3 -I "$CTL" 127.0.0.1:$port verify --expect verify.bad_values=0 verify.misordered=0 verify.end=ok \
    > verify.$port.txt || fail "verify $port"
  tr '\n' ' ' < verify.$port.txt; echo
  python3 -I "$CTL" 127.0.0.1:$port stats > stats.$port.txt || fail "stats $port"
done
python3 -I - "$ARENA" "$EXT" "$FILES" stats.17300.txt stats.17301.txt <<'PY' || fail "stress stats check"
import re, sys
arena, ext, files = map(int, sys.argv[1:4]); bad = []
for f in sys.argv[4:]:
    s = dict(l.split("=", 1) for l in open(f).read().splitlines() if "=" in l)
    g = lambda k: int(s.get(k, "0"))
    r = [k.split(".")[0] for k in s if k.startswith("remote") and k.endswith(".gets")][0]
    pools = dict(kv.split("=") for kv in s["pools"].split())
    print(f, " ".join(f"{k}={s.get(k)}" for k in ("remote_errors", "get_retries", "gc.dropped", r + ".catchups",
          r + ".sync_catchups", "fs.created", "fs.deleted", "fs.manifests")), s["pools"])
    for k in ("remote_errors", "get_errors", "update_errors", r + ".errors", r + ".catchup_errors"):
        if g(k): bad.append(f"{f}: {k}={g(k)}")
    if int(pools["blocks_used_total"]) <= arena: bad.append(f"{f}: arena blocks not reused")
    if int(pools["extents_used_total"]) <= ext: bad.append(f"{f}: file extents not reused")
    if g("fs.created") <= files: bad.append(f"{f}: directory slots not reused")
    if g("fs.manifests") < 2: bad.append(f"{f}: no MANIFEST rollover")
print("stress stats:", "OK" if not bad else "BAD " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY
kill %1 %2 2>/dev/null; wait
rm -f region.img
echo "STRESS TEST $([ $RESULT = 0 ] && echo PASS || echo FAIL)"
exit $RESULT
