#!/bin/bash
# Host functional test of sg-server (plain-mmap backend) with a regular FILE as the "device" (HW coherent: this checks
# the server, record protocol and plumbing, not a coherence protocol). Never points at /dev/dax*. Steps:
#   1. synthetic graph (2,000 nodes; node 1 = hub with 300 links -> inline + 2 overflow blocks) -> sg-image-gen
#   2. sg-server --copy-image (node 0) into the device file, then --verify --image (header, hash, record bytes)
#   3. two sg-server processes (nodes 0 and 1, one HWcc app range) + sg-client selftest: every request type, writes
#      through one server visible through the other, pool-block allocation by both writers; staleness logs written
#   4. tools/sg_stale_join.py on the run's logs (format / join smoke; HW coherent, so no stale read expected)
#   5. sg-seqlock-stress: writer process vs reader process on a copy of the image, SECONDS (default 5)
#   6. tests/stale_join_test.py (synthetic logs)
# usage: host_test.sh <build dir (bin/sg-*)> <scratch dir (must not exist)>
# env: CPUS (default 16-31: Host node 1), SECONDS_STRESS (5), PORT0 (19400)
set -euo pipefail
B=$(cd "$1" && pwd) S=$2
HERE=$(cd "$(dirname "$0")" && pwd); WL=$(cd "$HERE/.." && pwd); ROOT=$(cd "$WL/../.." && pwd)
CPUS=${CPUS:-16-31} P0=${PORT0:-19400} SECS=${SECONDS_STRESS:-5}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S/img" "$S/run"
S=$(cd "$S" && pwd)
# 1. synthetic graph
awk 'BEGIN { srand(20261111);
  for (k = 2; k <= 301; k++) print 1, k;          # hub: 300 links
  for (k = 400; k <= 529; k++) print 2, k;        # 130 links
  for (i = 3; i <= 2000; i++) for (j = 0; j < 4; j++) { v = 3 + int(rand() * 1998); if (v != i) print i, v } }' > "$S/edges.txt"
# (random edges avoid nodes 1 and 2, so the hub list is exactly 2..301 and the selftest id2s 1500.. are new links)
taskset -c "$CPUS" "$B/bin/sg-image-gen" --input "$S/edges.txt" --out-dir "$S/img" --node-slack 64 --ovf-pool 64 > "$S/gen.log" 2>&1
IMG=$S/img/graph.img
DEVSZ=1073741824
truncate -s "$DEVSZ" "$S/device.img"
sed -e "s|^device: .*|device: $S/device.img|" -e "s|^device_size: .*|device_size: $DEVSZ|" "$ROOT/config/cxl_region.yaml" > "$S/region.yaml"
NODES=2
APP=$("$B/bin/sg-server" --nodes $NODES --print-app-bytes)
export CXL_REGION_CONFIG=$S/region.yaml CXL_APP_HWCC_BYTES=$APP SG_OPCOH_FAKE=1
# 2. copy + verify
taskset -c "$CPUS" "$B/bin/sg-server" --copy-image "$IMG" > "$S/copy.log" 2>&1
grep -q "COPY DONE" "$S/copy.log" || { cat "$S/copy.log"; exit 1; }
taskset -c "$CPUS" "$B/bin/sg-server" --verify --image "$IMG" > "$S/verify.log" 2>&1 || { cat "$S/verify.log"; exit 1; }
grep -q "VERIFY PASS" "$S/verify.log" || { cat "$S/verify.log"; exit 1; }
# a corrupted record must fail the verify (scratch copy of the device file)
cp --sparse=always "$S/device.img" "$S/device-bad.img"
python3 -I - "$S/device-bad.img" "$IMG" <<'PY'
import struct, sys
dev, img = sys.argv[1], sys.argv[2]
h = open(img, "rb").read(4096)
nodes_off = struct.unpack_from("<Q", h, 64)[0]  # ImageHeader.nodes_off
with open(dev, "r+b") as f:  # swcc starts at 256 MiB (config/cxl_region.yaml, align 2 MiB)
    f.seek(268435456 + nodes_off + 128 * 0 + 40)  # data of node slot 0
    f.write(b"\xff\xfe\xfd")
PY
sed -e "s|^device: .*|device: $S/device-bad.img|" "$S/region.yaml" > "$S/region-bad.yaml"
if CXL_REGION_CONFIG=$S/region-bad.yaml taskset -c "$CPUS" "$B/bin/sg-server" --verify --image "$IMG" > "$S/verify-bad.log" 2>&1; then
  echo "FAIL: verify passed on a corrupted record"; exit 1
fi
grep -q "VERIFY FAIL" "$S/verify-bad.log" || { cat "$S/verify-bad.log"; exit 1; }
rm -f "$S/device-bad.img"
echo "copy + verify PASS (corruption detected)"
# 3. two servers + client selftest
RID=0x$(printf '%x' $(( (RANDOM << 16 | RANDOM) | 1 )))
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
for k in 0 1; do
  taskset -c "$CPUS" "$B/bin/sg-server" --node $k --nodes $NODES --run-id "$RID" --port $((P0 + k)) --query-threads 3 \
    --stale-dir "$S/run" --stale-every 1 --flush-ms 200 > "$S/node$k.log" 2>&1 &
  PIDS+=($!)
done
for k in 0 1; do
  for _ in $(seq 120); do grep -q "sg-server: READY" "$S/node$k.log" && break; grep -q FATAL "$S/node$k.log" && { cat "$S/node$k.log"; exit 1; }; sleep 0.5; done
  grep -q "sg-server: READY" "$S/node$k.log" || { echo "node$k not READY"; cat "$S/node$k.log"; exit 1; }
done
taskset -c "$CPUS" "$B/bin/sg-client" selftest 127.0.0.1:$P0 127.0.0.1:$((P0 + 1)) 1 1500 | tee "$S/selftest.log"
grep -q "selftest PASS" "$S/selftest.log"
"$B/bin/sg-client" stats 127.0.0.1:$P0 > "$S/stats0.txt"
"$B/bin/sg-client" stats 127.0.0.1:$((P0 + 1)) > "$S/stats1.txt"
cleanup
PIDS=()
grep -q "sg-server: stopping" "$S/node0.log" && grep -q "sg-server: stopping" "$S/node1.log"
# 4. staleness logs of the run
python3 -I "$WL/tools/sg_stale_join.py" --dir "$S/run" --json "$S/stale.json" > "$S/stale.out"
python3 -I - "$S/stale.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["reads"] > 100 and s["commits"] >= 300 and s["nodes"] == [0, 1] and s["commit_order_errors"] == 0, s
print(f"run staleness logs: {s['reads']} sampled reads, {s['commits']} commits, stale {s['stale']} (HW coherent file)")
PY
# 5. seqlock stress on a copy of the image
cp "$IMG" "$S/stress.img"
taskset -c "$CPUS" "$B/bin/sg-seqlock-stress" "$S/stress.img" "$SECS" 3 | tee "$S/stress.log"
grep -q "seqlock stress PASS" "$S/stress.log"
# 6. stale join unit test
python3 -I "$HERE/stale_join_test.py" "$S/join" | tail -1 | tee "$S/join.log"
grep -q "stale join test PASS" "$S/join.log"
echo "host_test PASS"
