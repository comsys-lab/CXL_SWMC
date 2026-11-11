#!/bin/bash
# Build the socialgraph graph image: verify the input against its SHA256SUMS, run sg-image-gen from the output dir,
# then write OUT/manifest.json = input + generator build + image sha256 + the generator's gen.json.
# usage: make_image.sh <sg-image-gen> <edges.txt.gz> <SHA256SUMS> <out dir> [generator args...]
# (run through scripts/ctl/build-wrap.sh; the out dir must be new or empty)
set -euo pipefail
GEN=$(readlink -f "$1"); IN=$(readlink -f "$2"); SUMS=$(readlink -f "$3"); OUT=$4; shift 4
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
[ -z "$(ls -A "$OUT")" ] || { echo "make_image: $OUT not empty" >&2; exit 1; }
IN_SHA=$(sha256sum "$IN" | cut -d' ' -f1)
WANT=$(awk -v f="$(basename "$IN")" '$2 == f || $2 == "*"f {print $1}' "$SUMS")
[ -n "$WANT" ] && [ "$WANT" = "$IN_SHA" ] || { echo "make_image: sha256 mismatch ($IN_SHA vs '$WANT')" >&2; exit 1; }
GEN_SHA=$(sha256sum "$GEN" | cut -d' ' -f1)
GEN_MANIFEST=$(dirname "$(dirname "$GEN")")/manifest.txt
SRC=$(sed -n 's/^source_commit=\([0-9a-f]*\) dirty=\([0-9]*\).*/\1 (dirty files \2)/p' "$GEN_MANIFEST" 2>/dev/null || true)
DIFF=$(grep -m1 '^source_dirty_diff_sha256=' "$GEN_MANIFEST" 2>/dev/null | cut -d= -f2 || true)
cd "$OUT"
/usr/bin/time -v "$GEN" --input "$IN" --out-dir "$OUT" "$@" 2> gen.log || { tail -5 gen.log >&2; exit 1; }
IMG_SHA=$(sha256sum graph.img | cut -d' ' -f1)
IMG_BYTES=$(stat -c %s graph.img)
{ echo "{"
  echo "  \"what\": \"socialgraph graph image (workloads/socialgraph/server/layout.h)\","
  echo "  \"date\": \"$(date -Is)\","
  echo "  \"input\": \"$IN\", \"input_sha256\": \"$IN_SHA\", \"input_sha256sums\": \"$SUMS\","
  echo "  \"generator\": \"$GEN\", \"generator_sha256\": \"$GEN_SHA\", \"generator_args\": \"$*\","
  echo "  \"generator_source_commit\": \"${SRC:-unknown}\", \"generator_source_dirty_diff_sha256\": \"$DIFF\","
  echo "  \"image\": \"graph.img\", \"image_bytes\": $IMG_BYTES, \"image_sha256\": \"$IMG_SHA\","
  echo "  \"gen\":"
  sed 's/^/  /' gen.json
  echo "}"; } > manifest.json
echo "image $OUT/graph.img $IMG_BYTES bytes sha256 $IMG_SHA"
