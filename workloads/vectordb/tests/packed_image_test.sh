#!/bin/bash
# Host test of the packed init image (experiment megalon-page-granularity; server.cc ImageStream, build_index arg 12):
#  1. vdb-build-index writes the same index twice (same seed: deterministic), per-chunk files and packed; per segment
#     the packed files must equal the concatenation of the per-chunk files (seg-<s>-v<g>.bin / -l<g>.bin in g order).
#  2. vdb-server --preload-only (plain backend: plain mapping of a scratch FILE as the device, no HWcc, no coherence)
#     copies each image into its own device file; the two device files must be identical.
# Never points at /dev/dax*. usage: packed_image_test.sh <vdb build dir> <pool_a.fbin> <scratch dir (must not exist)>
# env: CHUNK (4096), SEGMENTS (4), ROWS (0 = all), VEC_FORMAT (sq8), DEVICE_SIZE (1 GiB), CPUS (16-31)
set -euo pipefail
B=$(cd "$1" && pwd) A=$2 S=$3
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
CHUNK=${CHUNK:-4096} SEG=${SEGMENTS:-4} ROWS=${ROWS:-0} VF=${VEC_FORMAT:-sq8} DEVSZ=${DEVICE_SIZE:-1073741824} CPUS=${CPUS:-16-31}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S"
NA=$(python3 -c "import numpy as np,sys; print(np.fromfile(sys.argv[1],dtype=np.int32,count=1)[0])" "$A")
[ "$ROWS" = 0 ] || NA=$ROWS
MAXIDS=$((NA + NA / 5))
for f in chunks packed; do
  taskset -c "$CPUS" "$B/bin/vdb-build-index" "$A" "$S/init-$f" "$SEG" "$MAXIDS" 16 128 "$ROWS" 8 20261015 "$CHUNK" "$VF" "$f" > "$S/index-$f.log" 2>&1
done
man() { grep -v -e '^image packed$' -e '^input=' "$1" | sed 's/ train_s=.*//'; }  # train_s: wall time
cmp <(man "$S/init-packed/manifest.txt") <(man "$S/init-chunks/manifest.txt")
cmp "$S/init-packed/segments.txt" "$S/init-chunks/segments.txt"
RC=0
while read -r s count epl ucur; do
  N=$(sed -n 's/^per_chunk=\([0-9]*\) .*/\1/p' "$S/init-chunks/manifest.txt")
  G=$(( (count + N - 1) / N ))
  for k in v l; do
    if ! cmp <(for ((g = 0; g < G; g++)); do cat "$S/init-chunks/seg-$s-$k$g.bin"; done) "$S/init-packed/seg-$s-$k.bin"; then
      echo "segment $s $k: packed != per-chunk"; RC=1
    fi
  done
  echo "segment $s: $count records, $G groups, packed == per-chunk"
done < "$S/init-chunks/segments.txt"
PARAMS="--backend plain --nodes 2 --segments $SEG --chunk-bytes $CHUNK --max-ids $MAXIDS --max-writes 200000 --max-deletes 200000 --dlog-chunk 256"
[ "$VF" = fp32 ] || PARAMS="$PARAMS --vec-format $VF"
for f in chunks packed; do
  truncate -s "$DEVSZ" "$S/dev-$f.img"
  sed -e "s|^device: .*|device: $S/dev-$f.img|" -e "s|^device_size: .*|device_size: $DEVSZ|" "$ROOT/config/cxl_region.yaml" > "$S/region-$f.yaml"
  # shellcheck disable=SC2086
  CXL_REGION_CONFIG=$S/region-$f.yaml taskset -c "$CPUS" "$B/bin/vdb-server" --node 0 $PARAMS --init-dir "$S/init-$f" --preload-only > "$S/preload-$f.log" 2>&1
  grep -h "PRELOAD DONE" "$S/preload-$f.log"
done
if cmp "$S/dev-chunks.img" "$S/dev-packed.img"; then echo "device images identical"; else echo "device images differ"; RC=1; fi
[ $RC = 0 ] && echo "PACKED_IMAGE_TEST PASS" || echo "PACKED_IMAGE_TEST FAIL"
exit $RC
