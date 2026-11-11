#!/bin/bash
# Build sg-server for the Megalon backend (megalon_backend.h; both object layouts, --object-layout record|chunk) into
# OUT: bin/sg-server (same source and flags as build.sh; RUNPATH $ORIGIN/../lib), bin/sg-client (Host tests),
# lib/libmegalon-objapi.so (the shared object-API shim systems/megalon/shim, built by its build-shim.sh against
# MEGALON_BUILD) and the Megalon ship libraries. sg-server loads lib/libmegalon-objapi.so only for --backend megalon.
# The node count is the Megalon build's (LOGICAL_NODE_NUM, manifest megalon_nodes): one OUT per N, e.g.
# builds/socialgraph-megalon/1-n2 against builds/megalon/78-n2 (as vdb-megalon 17-n2 / run 2).
# usage: build-megalon.sh <out dir> <megalon build dir>     (run through scripts/ctl/build-wrap.sh)
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd); WL=$(cd "$HERE/.." && pwd); ROOT=$(cd "$WL/../.." && pwd)
SHIM=$ROOT/systems/megalon/shim
DSL=$ROOT/systems/destijl/lib
SRCS=("$WL" "$ROOT/systems/common" "$ROOT/experiments/loadgen/frame.h" "$ROOT/workloads/vectordb/server/opcoh.h"
      "$ROOT/workloads/vectordb/server/qcoh.h" "$ROOT/workloads/vectordb/server/shm_hnsw.h" "$ROOT/workloads/vectordb/server/layout.h"
      "$ROOT/workloads/vectordb/proto.h" "$SHIM" "$ROOT/systems/popcorn_new/include" "$DSL")
nm -D "$MB/ship/lib/libmegalon.so" | grep GetObjectThreadCoh > /dev/null || { echo "Megalon build without the shared shim API: $MB" >&2; exit 1; }
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/obj"
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DIRTY=$(git -C "$HERE" status --porcelain -- "${SRCS[@]}" | wc -l)
INFO=$(bash "$SHIM/build-shim.sh" "$OUT" "$MB" "sg-megalon commit=${COMMIT:0:12} dirty=$DIRTY" | tail -1)
INC=(-I"$WL" -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common" -I"$SHIM" -I"$ROOT/systems/popcorn_new/include")
FLAGS=(-std=c++17 -O2 -g -pthread -Wall -Wextra -Werror "${INC[@]}")
cc -O2 -g -Wall -Wextra -Werror -std=gnu11 -I"$DSL" -c "$DSL/de_stijl.c" -o "$OUT/obj/de_stijl.o"
ar rcs "$OUT/obj/libdestijl.a" "$OUT/obj/de_stijl.o"
c++ "${FLAGS[@]}" -mavx2 -mfma -fopenmp-simd -DCXL_REGION_DESTIJL -I"$DSL" "$HERE/server.cc" -o "$OUT/bin/sg-server" \
    -L"$OUT/obj" -ldestijl -ldl -Wl,--enable-new-dtags,-rpath,'$ORIGIN/../lib'
c++ "${FLAGS[@]}" "$WL/tools/sg_client.cc" -o "$OUT/bin/sg-client"
{ echo "# sg-server Megalon build (CXL_SWMC/workloads/socialgraph/server/build-megalon.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$COMMIT dirty=$DIRTY"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain -- "${SRCS[@]}" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$HERE" diff HEAD -- "${SRCS[@]}" | sha256sum | cut -c1-64)"
  echo "shim_info=$INFO"
  echo "megalon_build=$MB"
  grep -E '^(source_commit|source_dirty_diff_sha256|build_id|flavor|wmeta_layout|cmake_effective|megalon_nodes)=' "$MB/manifest.txt" | sed 's/^/megalon./'
  echo "megalon.manifest_sha256=$(sha256sum "$MB/manifest.txt" | cut -d' ' -f1)"
  echo "cxx=$(c++ --version | head -1)"
  echo "libdestijl=$DSL/de_stijl.c sha256=$(sha256sum < "$DSL/de_stijl.c" | cut -c1-64) (sg-server: -DCXL_REGION_DESTIJL)"
  (cd "$OUT" && find bin lib -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  for f in bin/sg-server lib/libmegalon-objapi.so; do echo "runpath[$f]=$(readelf -d "$OUT/$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"; done
  echo "glibc_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/libmegalon-objapi.so "$OUT"/lib/libmegalon.so | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/libmegalon-objapi.so "$OUT"/lib/libmegalon.so | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
