#!/bin/bash
# Build vdb-server and vdb-build-index (no external libraries) into OUT/bin; write OUT/manifest.txt.
# usage: build.sh <out dir>      (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
mkdir -p "$OUT/bin"
FLAGS=(-std=c++17 -O3 -g -mavx2 -mfma -fopenmp-simd -pthread -Wall -Wextra
       -I"$HERE/.." -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common")
c++ "${FLAGS[@]}" "$HERE/server.cc" -o "$OUT/bin/vdb-server"
c++ "${FLAGS[@]}" "$HERE/../tools/build_index.cc" -o "$OUT/bin/vdb-build-index"
{ echo "# vdb-server build (CXL_SWMC/workloads/vectordb/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" | wc -l)"
  echo "cxx=$(c++ --version | head -1)"
  (cd "$OUT" && find bin -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
