#!/bin/bash
# Host functional smoke test of vdb-server (plain backend) + loadgen (vectordb plugin) with stats snapshots.
# Two server processes share a scratch FILE as the "device" (a regular file is HW coherent: this checks the
# workload, update path, E1 and the measurement plumbing, not a coherence protocol). Never points at /dev/dax*.
# usage: host_smoke.sh <vdb build dir (bin/vdb-server)> <loadgen binary> <data dir> <scratch dir (must not exist)>
#   data dir: pool_a.fbin (initial records), pool_b.fbin, queries.fbin, writes.bin (gen_writes.py --mode update,
#             --pool-a = rows of pool_a.fbin); index built with <build>/bin/vdb-build-index into the scratch dir.
# env: CPUS (default 16-31: Host node1), SEGMENTS (4), CHUNK (1048576), RATES (100,300), MIX (update=1,search=19),
#      INDEX_BUILDER (default <build>/bin/vdb-build-index), DEVICE_SIZE (bytes, default 2 GiB),
#      BACKEND (plain | megalon: <build> from build-megalon.sh; Megalon config from systems/megalon/vectordb-2vm.yaml
#      with object_arena_size ARENA (default 512MB); node 0 MEGALON_REINIT=1), TRACE (1 = --trace-dir <scratch>,
#      default 1; 0 = none). At the end the HWcc trace lines (wsec, objseq) are read from the device file: they must
#      stay 0 with TRACE=0 or with the plain backend.
set -euo pipefail
B=$(cd "$1" && pwd) LG=$2 D=$(cd "$3" && pwd) S=$4
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
TRACE=${TRACE:-1} BACKEND=${BACKEND:-plain} DEVSZ=${DEVICE_SIZE:-2147483648} CPUS=${CPUS:-16-31} SEG=${SEGMENTS:-4} CHUNK=${CHUNK:-1048576} RATES=${RATES:-100,300} MIX=${MIX:-update=1,search=19}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S"
NA=$(python3 -c "import numpy as np,sys; print(np.fromfile(sys.argv[1],dtype=np.int32,count=1)[0])" "$D/pool_a.fbin")
NB=$(python3 -c "import numpy as np,sys; print(np.fromfile(sys.argv[1],dtype=np.int32,count=1)[0])" "$D/pool_b.fbin")
MAXIDS=$((NA + NB))
PARAMS="--backend $BACKEND --nodes 2 --segments $SEG --chunk-bytes $CHUNK --max-ids $MAXIDS --max-writes 200000 --max-deletes 200000 --dlog-chunk 256"
taskset -c "$CPUS" "${INDEX_BUILDER:-$B/bin/vdb-build-index}" "$D/pool_a.fbin" "$S/init" "$SEG" "$MAXIDS" 16 128 0 8 20261015 "$CHUNK" > "$S/index.log" 2>&1
truncate -s "$DEVSZ" "$S/device.img"
sed -e "s|^device: .*|device: $S/device.img|" -e "s|^device_size: .*|device_size: $DEVSZ|" "$ROOT/config/cxl_region.yaml" > "$S/region.yaml"
sed -e "s|^object_arena_size: .*|object_arena_size: ${ARENA:-512MB}|" "$ROOT/systems/megalon/vectordb-2vm.yaml" > "$S/megalon.yaml"
# shellcheck disable=SC2086
APP=$("$B/bin/vdb-server" $PARAMS --print-app-bytes)
RID=0x$(printf '%x' $(( (RANDOM << 16 | RANDOM) | 1 )))
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
for k in 0 1; do
  EXTRA=""; [ "$k" = 0 ] && EXTRA="--init-dir $S/init"
  XE=(); [ "$BACKEND" = megalon ] && XE=(RACKOBJ_CONFIG="$S/megalon.yaml") && [ "$k" = 0 ] && XE+=(MEGALON_REINIT=1)
  # shellcheck disable=SC2086
  env ${XE[@]+"${XE[@]}"} CXL_REGION_CONFIG=$S/region.yaml CXL_APP_HWCC_BYTES=$APP taskset -c "$CPUS" "$B/bin/vdb-server" --node $k --run-id "$RID" \
    $PARAMS --port $((19300 + k)) --search-threads 4 $([ "$TRACE" = 1 ] && echo --trace-dir "$S") $EXTRA > "$S/node$k.log" 2>&1 &
  PIDS+=($!)
done
for k in 0 1; do
  for _ in $(seq 300); do grep -q "vdb-server: READY" "$S/node$k.log" && break; grep -q FATAL "$S/node$k.log" && { cat "$S/node$k.log"; exit 1; }; sleep 1; done
  grep -q "vdb-server: READY" "$S/node$k.log" || { echo "node$k not READY"; exit 1; }
done
set +e
taskset -c "$CPUS" "$LG" --workload vectordb --target 127.0.0.1:19300,127.0.0.1:19301 --out "$S/loadgen" --stats-op 10 \
  --opt data="$D" --opt writes="$D/writes.bin" --mode fixed --rates "$RATES" --mix "$MIX" --warmup-s 2 \
  --step-warmup-s 1 --step-measure-s 5 --drain-s 2 --raw > "$S/loadgen.log" 2>&1
LGRC=$?
set -e
for p in "${PIDS[@]}"; do kill -TERM "$p"; done
wait || true
PIDS=()
python3 "$ROOT/experiments/loadgen/stats_delta.py" "$S/loadgen" --out "$S/stats-steps.csv"
python3 "$ROOT/experiments/loadgen/export_csv.py" --out "$S/steps.csv" "$S/loadgen=host-smoke"
echo "loadgen rc=$LGRC"; cat "$S/loadgen/vectordb.txt"
for k in 0 1; do sed -n '/vdb-server: stopping/,$p' "$S/node$k.log" | grep -E "^(node|P|elements|updates|inserts|deletes|searches|timeouts|bad_records)=" | tr '\n' ' '; echo; done
# HWcc trace lines in the device file (offsets from the server log)
python3 - "$S" "$BACKEND" "$TRACE" <<'PY'
import re, sys, numpy as np
S, be, tr = sys.argv[1:]
m = re.search(r"wsec at device offset (\d+), objseq at (\d+) \((\d+) objects\)", open(S + "/node0.log").read())
w, o, n = map(int, m.groups())
dev = np.memmap(S + "/device.img", dtype=np.uint64, mode="r")
wsec, objseq = int(dev[w // 8]), dev[o // 8:o // 8 + n]
print(f"hwcc trace lines: wsec={wsec} objseq nonzero={int((objseq != 0).sum())}/{n} max={int(objseq.max())}")
expect_on = be == "megalon" and tr == "1"
if (wsec != 0 or objseq.any()) != expect_on:
    sys.exit("hwcc trace lines: unexpected (" + ("should be written" if expect_on else "must stay 0") + ")")
PY
exit $LGRC
