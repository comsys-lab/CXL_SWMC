#!/bin/bash
# Host timing of Megalon whole-object flushes (tools/mg_flush_time.cc): 2 processes = 2 nodes on a file region.
# usage: mg_flush_time.sh <recsys-megalon build dir> <work dir (new)> <object bytes> [rounds (3)] [rows/round (1000)] [pause ms (2000)]
# env: IMG_DIR (/dev/shm), CPUS0 / CPUS1 (numactl --physcpubind per node), MEGALON_CFG (template, tests/megalon-host.yaml)
set -euo pipefail
B=$(cd "$1" && pwd); WD=$2; BYTES=$3; R=${4:-3}; K=${5:-1000}; PAUSE=${6:-2000}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd)
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
IMG=${IMG_DIR:-/dev/shm}/recsys-flush-$$.img
HW=$((256 << 20)) AL=$((2 << 20)) LOGB=$((64 << 20))
ARENA=$(( (BYTES + 64 + AL - 1) / AL * AL + AL ))
DEV=$(( HW + ARENA + LOGB + 8 * AL ))
cat > "$WD/region.yaml" <<EOR
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
EOR
sed -e "s/^object_arena_size:.*/object_arena_size: $ARENA/" -e "s|^region_config:.*|region_config: \"$WD/region.yaml\"|" \
    "${MEGALON_CFG:-$W/tests/megalon-host.yaml}" > "$WD/megalon.yaml"
truncate -s "$DEV" "$IMG"
PIDS=(); cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; rm -f "$IMG"; }
trap cleanup EXIT
RID=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
for k in 0 1; do
  c=CPUS$k
  X=(); [ "$k" = 0 ] && X=(MEGALON_REINIT=1)
  env CXL_REGION_CONFIG="$WD/region.yaml" RACKOBJ_CONFIG="$WD/megalon.yaml" MEGALON_NODE_ID=$k MEGALON_RUN_ID=$((RID + 1)) "${X[@]}" \
    numactl --physcpubind="${!c:-20-23}" --membind=1 "$B/bin/mg-flush-time" "$B/lib/libmegalon-objapi.so" "$BYTES" "$R" "$K" "$PAUSE" \
    > "$WD/node$k.log" 2>&1 &
  PIDS+=($!)
done
RC=0
for i in 0 1; do wait "${PIDS[$i]}" || RC=$?; done
PIDS=()
grep -h "^node" "$WD"/node0.log "$WD"/node1.log | grep -v "slow read" || true
grep -c "slow read" "$WD/node1.log" | sed 's/^/node1 slow-read lines: /'
[ "$RC" = 0 ] && echo "FLUSH TIME DONE -> $WD" || { echo "FLUSH TIME FAIL rc=$RC -> $WD"; exit 1; }
