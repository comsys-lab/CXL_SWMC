#!/bin/bash
# Build vdb-server and vdb-build-index (no external libraries) into OUT/bin; write OUT/manifest.txt.
# usage: build.sh <out dir>      (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
mkdir -p "$OUT/bin" "$OUT/obj"
FLAGS=(-std=c++17 -O3 -g -mavx2 -mfma -fopenmp-simd -pthread -Wall -Wextra
       -I"$HERE/.." -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common"
       -I"$ROOT/systems/megalon/shim" -I"$ROOT/systems/popcorn_new/include")
# libdestijl (systems/destijl/lib; de_stijl_set_staleness only): vdb-server applies $CXL_DESTIJL_T_US with CXL_SYSTEM=ds
# (cxl_region.h region_apply_staleness); a no-op for every other system
DSL=$ROOT/systems/destijl/lib
cc -O2 -g -Wall -Wextra -Werror -std=gnu11 -I"$DSL" -c "$DSL/de_stijl.c" -o "$OUT/obj/de_stijl.o"
ar rcs "$OUT/obj/libdestijl.a" "$OUT/obj/de_stijl.o"
c++ "${FLAGS[@]}" -DCXL_REGION_DESTIJL -I"$DSL" "$HERE/server.cc" -o "$OUT/bin/vdb-server" -L"$OUT/obj" -ldestijl
c++ "${FLAGS[@]}" "$HERE/../tools/build_index.cc" -o "$OUT/bin/vdb-build-index"
c++ "${FLAGS[@]}" "$HERE/../tools/search_index.cc" -o "$OUT/bin/vdb-search-index"   # Host check tool (not installed on guests)
c++ "${FLAGS[@]}" "$HERE/../tools/relayout_c4k.cc" -o "$OUT/bin/vdb-relayout-c4k"   # Host tool: 4 KiB-page packed image
{ echo "# vdb-server build (CXL_SWMC/workloads/vectordb/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" "$ROOT/systems/megalon/shim" "$ROOT/systems/popcorn_new/include" "$DSL" | wc -l)"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" "$ROOT/systems/megalon/shim" "$ROOT/systems/popcorn_new/include" "$DSL" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$HERE" diff HEAD -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" "$ROOT/systems/megalon/shim" "$ROOT/systems/popcorn_new/include" "$DSL" | sha256sum | cut -c1-64)"
  echo "cxx=$(c++ --version | head -1)"
  echo "libdestijl=$DSL/de_stijl.c sha256=$(sha256sum < "$DSL/de_stijl.c" | cut -c1-64) (vdb-server: -DCXL_REGION_DESTIJL)"
  (cd "$OUT" && find bin -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
