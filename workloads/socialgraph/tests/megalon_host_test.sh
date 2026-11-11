#!/bin/bash
# Host functional test of sg-server --backend megalon (megalon_backend.h): two sg-server processes = two Megalon nodes
# on one regular FILE as the device (Megalon's two-process single-file mode, as systems/megalon/shim/shimtest.cc and
# tools/objtest-run.sh). Never points at /dev/dax*. Per layout (record; chunk with 4096 B chunks, so that adjacency
# blocks are split by chunk boundaries: stress also on the largest split list; chunk with 32 MiB):
#   node 0 (MEGALON_REINIT=1) creates the objects and loads IMAGE, node 1 attaches; sg-client selftest (every request
#   type, writes through one server visible through the other, pool blocks) and sg-client stress (writer on node 0
#   updates an overflow-block link + a node, reader on node 1 checks every snapshot) for STRESS_S seconds; per-node
#   RSS / RssAnon after READY (node<k>.mem).
# usage: megalon_host_test.sh <sg-megalon build dir> <socialgraph build dir (sg-image-gen)> <scratch dir (must not exist)>
# env: CPUS (taskset list, default 18-23,50-55), LAYOUTS ("record chunk:8192 chunk:33554432"), IMAGE (default: the
#      synthetic graph of tests/host_test.sh), MEG_CFG (Megalon yaml, default systems/megalon/socialgraph-2vm.yaml),
#      ARENA (object_arena_size, default 1GB), DEVSZ (device file bytes, default 2415919104), STRESS_S (5),
#      SELFTEST (1; 0 = skip selftest and stress: init + DRAM only), PORT0 (19500), DEVDIR (device file dir, default
#      the scratch dir), READY_S (seconds to wait for READY, default 300)
set -euo pipefail
B=$(cd "$1" && pwd) G=$(cd "$2" && pwd) S=$3
HERE=$(cd "$(dirname "$0")" && pwd); WL=$(cd "$HERE/.." && pwd); ROOT=$(cd "$WL/../.." && pwd)
CPUS=${CPUS:-18-23,50-55} P0=${PORT0:-19500} SECS=${STRESS_S:-5} DEVSZ=${DEVSZ:-2415919104} READY_S=${READY_S:-300}
LAYOUTS=${LAYOUTS:-"record chunk:4096 chunk:33554432"}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S"
S=$(cd "$S" && pwd)
DEVDIR=${DEVDIR:-$S}
RUN=(taskset -c "$CPUS" nice -n 19 ionice -c3 numactl --membind=1)
IMG=${IMAGE:-}
if [ -z "$IMG" ]; then  # synthetic graph (tests/host_test.sh): node 1 = hub with 300 links (inline + 2 overflow blocks)
  mkdir -p "$S/img"
  awk 'BEGIN { srand(20261111);
    for (k = 2; k <= 301; k++) print 1, k;
    for (k = 400; k <= 529; k++) print 2, k;
    for (i = 3; i <= 2000; i++) for (j = 0; j < 4; j++) { v = 3 + int(rand() * 1998); if (v != i) print i, v } }' > "$S/edges.txt"
  "${RUN[@]}" "$G/bin/sg-image-gen" --input "$S/edges.txt" --out-dir "$S/img" --node-slack 64 --ovf-pool 64 > "$S/gen.log" 2>&1
  IMG=$S/img/graph.img
fi
APP=$("$B/bin/sg-server" --nodes 2 --print-app-bytes)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
k=0
for spec in $LAYOUTS; do
  L=${spec%%:*}; CB=33554432; [ "$spec" != "$L" ] && CB=${spec#*:}
  T=$S/$L-$CB; mkdir -p "$T/stale"
  DEV=$DEVDIR/device-$L-$CB.img
  rm -f "$DEV"; truncate -s "$DEVSZ" "$DEV"
  sed -e "s|^device: .*|device: $DEV|" -e "s|^device_size: .*|device_size: $DEVSZ|" "$ROOT/config/cxl_region-ring2m.yaml" > "$T/region.yaml"
  sed -e "s|^object_arena_size: .*|object_arena_size: ${ARENA:-1GB}|" "${MEG_CFG:-$ROOT/systems/megalon/socialgraph-2vm.yaml}" > "$T/megalon.yaml"
  "${RUN[@]}" "$B/bin/sg-server" --print-megalon-objects --image "$IMG" --object-layout "$L" --chunk-bytes "$CB" > "$T/objects.txt"
  RID=0x$(printf '%x' $(( (RANDOM << 16 | RANDOM) | 1 )))
  PA=$((P0 + 2 * k)) PB=$((P0 + 2 * k + 1)); k=$((k + 1))
  COMMON=(--nodes 2 --run-id "$RID" --region "$T/region.yaml" --backend megalon --object-layout "$L" --chunk-bytes "$CB"
          --query-threads 3 --stale-dir "$T/stale" --stale-every 1 --flush-ms 200)
  PIDS=()
  env RACKOBJ_CONFIG="$T/megalon.yaml" CXL_APP_HWCC_BYTES="$APP" MEGALON_REINIT=1 SG_OPCOH_FAKE=1 \
    "${RUN[@]}" "$B/bin/sg-server" --node 0 --port $PA --image "$IMG" "${COMMON[@]}" > "$T/node0.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 600); do grep -q "READY published" "$T/node0.log" && break; grep -q FATAL "$T/node0.log" && break; sleep 0.1; done
  env RACKOBJ_CONFIG="$T/megalon.yaml" CXL_APP_HWCC_BYTES="$APP" SG_OPCOH_FAKE=1 \
    "${RUN[@]}" "$B/bin/sg-server" --node 1 --port $PB "${COMMON[@]}" > "$T/node1.log" 2>&1 &
  PIDS+=($!)
  for n in 0 1; do
    for _ in $(seq $((READY_S * 2))); do grep -q "sg-server: READY" "$T/node$n.log" && break; grep -q FATAL "$T/node$n.log" && { tail -20 "$T/node$n.log"; exit 1; }; sleep 0.5; done
    grep -q "sg-server: READY" "$T/node$n.log" || { echo "node$n not READY ($L $CB)"; tail -20 "$T/node$n.log"; exit 1; }
  done
  for n in 0 1; do grep -E "^(VmHWM|VmRSS|RssAnon|RssFile|RssShmem)" "/proc/${PIDS[$n]}/status" > "$T/node$n.mem"; done
  if [ "${SELFTEST:-1}" = 1 ]; then
    "${RUN[@]}" "$B/bin/sg-client" selftest 127.0.0.1:$PA 127.0.0.1:$PB 1 1500 > "$T/selftest.log" 2>&1 || { cat "$T/selftest.log"; exit 1; }
    "${RUN[@]}" "$B/bin/sg-client" stress 127.0.0.1:$PA 127.0.0.1:$PB 1 3 "$SECS" > "$T/stress.log" 2>&1 || { cat "$T/stress.log"; exit 1; }
    if [ "$L" = chunk ]; then  # the highest-degree list whose primary block is split by a chunk boundary, if any
      SPLIT=$(python3 -I - "$IMG" "$CB" <<'PY'
import struct, sys
img, cb = sys.argv[1], int(sys.argv[2])
with open(img, "rb") as f:
    h = f.read(4096)
    id_base, n_orig = struct.unpack_from("<QQ", h, 16)
    ai_off, ai_bytes = struct.unpack_from("<QQ", h, 48)
    adj_bytes = struct.unpack_from("<Q", h, 88)[0]
    f.seek(ai_off)
    ai = struct.unpack("<%dQ" % n_orig, f.read(8 * n_orig))
best = None
for s in range(n_orig):
    a, e = ai[s], ai[s + 1] if s + 1 < n_orig else adj_bytes
    if a // cb != (e - 1) // cb and (best is None or e - a > best[0]):
        best = (e - a, s)
print(best[1] + id_base if best and best[0] >= 64 + 4 * 32 else 0)
PY
)
      if [ "$SPLIT" != 0 ]; then
        # (the selftest needs the hub's free id2 range; the stress writes / reads the split block itself)
        "${RUN[@]}" "$B/bin/sg-client" stress 127.0.0.1:$PA 127.0.0.1:$PB "$SPLIT" 4 "$SECS" > "$T/stress-split.log" 2>&1 || { cat "$T/stress-split.log"; exit 1; }
        echo "split list id1 $SPLIT: $(tail -1 "$T/stress-split.log")" | tee -a "$S/summary.txt"
      fi
    fi
  fi
  "$B/bin/sg-client" stats 127.0.0.1:$PA > "$T/stats0.txt"
  "$B/bin/sg-client" stats 127.0.0.1:$PB > "$T/stats1.txt"
  cleanup; PIDS=()
  rm -f "$DEV"
  printf '%s chunk_bytes=%s: %s | %s | %s | node0 %s | node1 %s\n' "$L" "$CB" "$(cut -d' ' -f3,4 "$T/objects.txt")" \
    "$(tail -1 "$T/selftest.log" 2>/dev/null)" "$(tail -1 "$T/stress.log" 2>/dev/null)" \
    "$(tr '\n' ' ' < "$T/node0.mem" | tr -s ' ')" "$(tr '\n' ' ' < "$T/node1.mem" | tr -s ' ')" | tee -a "$S/summary.txt"
done
echo "megalon_host_test PASS"
