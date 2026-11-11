#!/bin/bash
# Build the socialgraph binaries into OUT/bin and write OUT/manifest.txt:
#   sg-server (plain-mmap backend; -DCXL_REGION_DESTIJL + libdestijl as vdb-server, De Stijl T via CXL_DESTIJL_T_US),
#   sg-image-gen (Host tool), sg-client (Host test client), sg-layout-test, sg-seqlock-stress (Host tests).
# usage: build.sh <out dir>      (run through scripts/ctl/build-wrap.sh)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); WL=$(cd "$HERE/.." && pwd); ROOT=$(cd "$WL/../.." && pwd)
mkdir -p "$OUT/bin" "$OUT/obj"
INC=(-I"$WL" -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common" -I"$ROOT/systems/megalon/shim"
     -I"$ROOT/systems/popcorn_new/include")
FLAGS=(-std=c++17 -O2 -g -pthread -Wall -Wextra -Werror "${INC[@]}")
DSL=$ROOT/systems/destijl/lib
cc -O2 -g -Wall -Wextra -Werror -std=gnu11 -I"$DSL" -c "$DSL/de_stijl.c" -o "$OUT/obj/de_stijl.o"
ar rcs "$OUT/obj/libdestijl.a" "$OUT/obj/de_stijl.o"
# sg-server includes vectordb opcoh.h (-> shm_hnsw.h): same vector flags as vdb-server (guests run vdb-server builds)
c++ "${FLAGS[@]}" -mavx2 -mfma -fopenmp-simd -DCXL_REGION_DESTIJL -I"$DSL" "$HERE/server.cc" -o "$OUT/bin/sg-server" -L"$OUT/obj" -ldestijl
c++ "${FLAGS[@]}" "$WL/tools/sg_image_gen.cc" -o "$OUT/bin/sg-image-gen" -lz
c++ "${FLAGS[@]}" "$WL/tools/sg_client.cc" -o "$OUT/bin/sg-client"
c++ "${FLAGS[@]}" "$WL/tests/layout_test.cc" -o "$OUT/bin/sg-layout-test"
c++ "${FLAGS[@]}" "$WL/tests/seqlock_stress.cc" -o "$OUT/bin/sg-seqlock-stress"
SRCS=("$WL" "$ROOT/systems/common" "$ROOT/experiments/loadgen/frame.h" "$ROOT/workloads/vectordb/server/opcoh.h"
      "$ROOT/workloads/vectordb/server/qcoh.h" "$ROOT/workloads/vectordb/server/shm_hnsw.h" "$ROOT/workloads/vectordb/server/layout.h"
      "$ROOT/workloads/vectordb/proto.h" "$ROOT/systems/megalon/shim" "$ROOT/systems/popcorn_new/include" "$DSL")
{ echo "# socialgraph build (CXL_SWMC/workloads/socialgraph/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- "${SRCS[@]}" | wc -l)"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain -- "${SRCS[@]}" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$HERE" diff HEAD -- "${SRCS[@]}" | sha256sum | cut -c1-64)"
  echo "cxx=$(c++ --version | head -1)"
  echo "zlib=$(grep -m1 '#define ZLIB_VERSION' /usr/include/zlib.h | awk '{print $3}')"
  echo "libdestijl=$DSL/de_stijl.c sha256=$(sha256sum < "$DSL/de_stijl.c" | cut -c1-64) (sg-server: -DCXL_REGION_DESTIJL)"
  (cd "$OUT" && find bin -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
