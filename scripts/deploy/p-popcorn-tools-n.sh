#!/bin/bash
# N-node Popcorn bundle (popcorn-n): Host-side scripts + guest tools dir for cxl_shm with nr_nodes = 2..8 on an
# already deployed Popcorn build. Host-local only (no guest, no VM change, no sudo, no build).
#   p-popcorn-tools-n.sh <source deploy bundle dir> <region config yaml> <new out dir>
# The kernel, cxl_shm.ko (KO_SHA), faultlat and run.sh are taken unchanged from the source bundle (e.g.
# builds/popcorn_new/12/deploy-v1, verified against its packet.sha256 first); new are the region config, the
# N-node p-popcorn-guest.sh / p-popcorn-shm.sh / smoke-n.sh, and popcorn.env with
#   PARAMS      = `faultlat params --nodes 2` for the new region config (init_state=invalid; N=2 default, as before)
#   PARAMS_N<n> = the same for n = 2..8 (p-popcorn-guest.sh load ... nodes=<n>)
# Writes (refuses if <out> exists):
#   <out>/{p-popcorn-shm.sh,smoke.sh,smoke-n.sh}          Host side (= C of p-popcorn-shm.sh)
#   <out>/tools/{faultlat,run.sh,cxl_region.yaml,p-popcorn-guest.sh,popcorn.env,tools.sha256}   guest side (= GT)
#   <out>/params-layout.txt   per N: cxl_shm parameters, header bytes, slots per window, need
#   <out>/record.json, <out>/packet.sha256
set -euo pipefail
umask 022
SRC=$(readlink -f "${1:?source deploy bundle dir}"); REG=$(readlink -f "${2:?region config}"); OUT=${3:?new out dir}
SW=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
DEV_SIZE=103060340736   # observed /sys/bus/dax/devices/dax0.0/size on the guests
test ! -e "$OUT" || { echo "$OUT exists"; exit 1; }
(cd "$SRC" && sha256sum --quiet -c packet.sha256) || { echo "source bundle $SRC fails its packet.sha256"; exit 1; }
for f in faultlat run.sh popcorn.env; do test -f "$SRC/tools/$f"; done
# shellcheck source=/dev/null
K=$(. "$SRC/tools/popcorn.env"; echo "$K"); KO_SHA=$(. "$SRC/tools/popcorn.env"; echo "$KO_SHA")
[ -n "$K" ] && [[ "$KO_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "source popcorn.env lacks K/KO_SHA"; exit 1; }
mkdir -p "$OUT/tools"
cp "$SRC/tools/faultlat" "$SRC/tools/run.sh" "$OUT/tools/"
cp "$REG" "$OUT/tools/cxl_region.yaml"
cp "$SW/scripts/deploy/p-popcorn-guest.sh" "$OUT/tools/"
cp "$SW/scripts/deploy/p-popcorn-shm.sh" "$SW/workloads/faultlat/smoke.sh" "$SW/workloads/faultlat/smoke-n.sh" "$OUT/"
FL="$OUT/tools/faultlat"
par() { "$FL" params --config "$OUT/tools/cxl_region.yaml" --device-size $DEV_SIZE --nodes "$1" --init-state invalid; }
PARAMS=$(par 2)
read -r MOFF MBYTES < <(sed -n 's/.*managed_offset=\([0-9]*\) managed_size=\([0-9]*\).*/\1 \2/p' <<<"$PARAMS")
read -r ROFF RSIZE < <(sed -n 's/.*ring_offset=\([0-9]*\) ring_size=\([0-9]*\).*/\1 \2/p' <<<"$PARAMS")
{
  echo "# Popcorn guest expectations (frozen with the packet; read by p-popcorn-guest.sh). popcorn-n bundle."
  echo "K=$K"
  echo "KO_SHA=$KO_SHA"
  echo "PARAMS=\"$PARAMS\""
  for n in 2 3 4 5 6 7 8; do echo "PARAMS_N$n=\"$(par $n)\""; done
  echo "MANAGED_BASE_OFF=$MOFF"
  echo "MANAGED_BYTES=$MBYTES"
} > "$OUT/tools/popcorn.env"
# ring layout per N (same formula as cxl_shm.c cxl_hdr_bytes / nr_slots and faultlat cmd_params)
python3 -I - "$RSIZE" > "$OUT/params-layout.txt" <<'PY'
import sys
size = int(sys.argv[1])
print('N windows header_bytes need_bytes(256 slots) slots_per_window(pow2) req_capacity_per_peer')
for n in range(2, 9):
    w = n * (n - 1) * 2
    hdr = (w * 2 * 64 + 3 * n * 64 + 4095) // 4096 * 4096
    need = hdr + w * 256 * 64
    s = (size - hdr) // w // 64 if size > hdr else 0
    p = 1 << (s.bit_length() - 1) if s else 0
    assert size >= need, (n, size, need)
    print(n, w, hdr, need, p, p - 2 * 16 if p else 0)
PY
(cd "$OUT/tools" && sha256sum faultlat run.sh cxl_region.yaml p-popcorn-guest.sh popcorn.env > tools.sha256)
cat > "$OUT/record.json" <<JSON
{
  "kind": "popcorn-n bundle", "release": "$K", "cxl_shm_ko_sha256": "$KO_SHA",
  "source_bundle": "$SRC", "source_packet_sha256": "$(sha256sum "$SRC/packet.sha256" | cut -d' ' -f1)",
  "region_config": "$REG", "region_sha256": "$(sha256sum "$REG" | cut -d' ' -f1)",
  "ring_offset": $ROFF, "ring_size": $RSIZE,
  "cxl_swmc_commit": "$(git -C "$SW" rev-parse HEAD)",
  "cxl_swmc_dirty_files": $(git -C "$SW" status --porcelain -- scripts/deploy workloads/faultlat config | wc -l),
  "faultlat_sha256": "$(sha256sum "$FL" | cut -d' ' -f1)",
  "created": "$(date -Is)"
}
JSON
(cd "$OUT" && find . -type f ! -name packet.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > packet.sha256)
cat "$OUT/tools/popcorn.env" "$OUT/params-layout.txt"
echo "bundle $OUT: packet.sha256 $(sha256sum "$OUT/packet.sha256" | cut -d' ' -f1)"
