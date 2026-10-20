#!/bin/bash
# Build the vectordb server for the Megalon backend (DESIGN.md §12) into OUT: bin/vdb-server, bin/vdb-build-index
# (same sources and flags as build.sh), lib/libmegalon-objapi.so (the shared object-API shim systems/megalon/shim,
# built by its build-shim.sh against MEGALON_BUILD) and the Megalon ship libraries; RUNPATH $ORIGIN/../lib (bin) and
# $ORIGIN (lib). vdb-server loads lib/libmegalon-objapi.so only for --backend megalon; --backend plain behaves as the
# build.sh binary. Since vdb build 10 (earlier builds: lib/libvdb-megalon.so from megalon_shim.cc, kept for lmdb).
# usage: build-megalon.sh <out dir> <megalon build dir, e.g. builds/megalon/70>
#        (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
SHIM=$ROOT/systems/megalon/shim
SRCS=("$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" "$SHIM" "$ROOT/systems/popcorn_new/include")
mkdir -p "$OUT/bin" "$OUT/lib"
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DIRTY=$(git -C "$HERE" status --porcelain -- "${SRCS[@]}" | wc -l)
PREFIX="vdb-megalon commit=${COMMIT:0:12} dirty=$DIRTY"
if nm -D "$MB/ship/lib/libmegalon.so" | grep GetObjectThreadCoh > /dev/null; then  # no grep -q: SIGPIPE + pipefail
  SHIM_KIND=shared
  INFO=$(bash "$SHIM/build-shim.sh" "$OUT" "$MB" "$PREFIX" | tail -1)
else  # Megalon <= 70: fallback shim (thread_coh nullptr) against rackobj.h of the build's own source commit
  SHIM_KIND=fallback
  [ -f "$MB/manifest.txt" ] && [ -f "$MB/ship/lib/libmegalon.so" ] || { echo "not a Megalon build: $MB" >&2; exit 1; }
  want=$(sed -n 's/^sha256\[lib\/libmegalon.so\]=//p' "$MB/manifest.txt")
  [ "$(sha256sum "$MB/ship/lib/libmegalon.so" | cut -d' ' -f1)" = "$want" ] || { echo "libmegalon.so != its manifest" >&2; exit 1; }
  MC=$(sed -n 's/^source_commit=//p' "$MB/manifest.txt" | cut -d' ' -f1)
  mkdir -p "$OUT/fallback-include"
  git -C "$ROOT/systems/megalon/src" show "$MC:include/rackobj.h" > "$OUT/fallback-include/rackobj.h"
  cp -p "$MB"/ship/lib/* "$OUT/lib/"
  INFO="$PREFIX shim=fallback-no-thread-coh megalon=$(sed -n 's/^build_id=//p' "$MB/manifest.txt")/$(sed -n 's/^flavor=//p' "$MB/manifest.txt")/$(sed -n 's/^wmeta_layout=//p' "$MB/manifest.txt")"
  c++ -std=c++17 -O2 -g -fPIC -shared -Wall -Wextra -I"$SHIM" -I"$OUT/fallback-include" -DMSHIM_INFO="\"$INFO\"" \
      "$HERE/megalon_objapi_fallback.cc" -o "$OUT/lib/libmegalon-objapi.so" -L"$OUT/lib" -lmegalon \
      -Wl,--enable-new-dtags,-rpath,'$ORIGIN',--no-undefined,--no-as-needed
  LD_LIBRARY_PATH= ldd "$OUT/lib/libmegalon-objapi.so" | grep -q "not found" && { ldd "$OUT/lib/libmegalon-objapi.so"; exit 1; }
fi
FLAGS=(-std=c++17 -O3 -g -mavx2 -mfma -fopenmp-simd -pthread -Wall -Wextra
       -I"$HERE/.." -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common"
       -I"$SHIM" -I"$ROOT/systems/popcorn_new/include")
c++ "${FLAGS[@]}" "$HERE/server.cc" -o "$OUT/bin/vdb-server" -Wl,--enable-new-dtags,-rpath,'$ORIGIN/../lib'
c++ "${FLAGS[@]}" "$HERE/../tools/build_index.cc" -o "$OUT/bin/vdb-build-index"
{ echo "# vdb-server Megalon build (CXL_SWMC/workloads/vectordb/server/build-megalon.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$COMMIT dirty=$DIRTY"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain -- "${SRCS[@]}" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$HERE" diff HEAD -- "${SRCS[@]}" | sha256sum | cut -c1-64)"
  echo "shim_info=$INFO"; echo "shim_kind=$SHIM_KIND"
  [ "$SHIM_KIND" = shared ] || echo "fallback_rackobj_h=$MC:include/rackobj.h sha256=$(sha256sum "$OUT/fallback-include/rackobj.h" | cut -d' ' -f1)"
  echo "megalon_build=$MB"
  grep -E '^(source_commit|source_dirty_diff_sha256|build_id|flavor|wmeta_layout|cmake_effective|megalon_nodes)=' "$MB/manifest.txt" | sed 's/^/megalon./'
  echo "megalon.manifest_sha256=$(sha256sum "$MB/manifest.txt" | cut -d' ' -f1)"
  echo "cxx=$(c++ --version | head -1)"
  (cd "$OUT" && find bin lib -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  for f in bin/vdb-server lib/libmegalon-objapi.so; do echo "runpath[$f]=$(readelf -d "$OUT/$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"; done
  echo "glibc_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/libmegalon-objapi.so "$OUT"/lib/libmegalon.so | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/libmegalon-objapi.so "$OUT"/lib/libmegalon.so | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
