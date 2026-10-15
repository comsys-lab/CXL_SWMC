#!/bin/bash
# Build the vectordb server for the Megalon backend (DESIGN.md §12) into OUT: bin/vdb-server, bin/vdb-build-index
# (same sources and flags as build.sh), lib/libvdb-megalon.so (megalon_shim.cc linked against libmegalon) and the
# Megalon ship libraries copied from MEGALON_BUILD/ship/lib; RUNPATH $ORIGIN/../lib (bin) and $ORIGIN (lib).
# vdb-server loads lib/libvdb-megalon.so only for --backend megalon; --backend plain behaves as the build.sh binary.
# usage: build-megalon.sh <out dir> <megalon build dir, e.g. builds/megalon/68>
#        (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
MSRC=$ROOT/systems/megalon/src
[ -f "$MB/manifest.txt" ] && [ -f "$MB/ship/lib/libmegalon.so" ] || { echo "not a Megalon build: $MB" >&2; exit 1; }
want=$(sed -n 's/^sha256\[lib\/libmegalon.so\]=//p' "$MB/manifest.txt")
[ "$(sha256sum "$MB/ship/lib/libmegalon.so" | cut -d' ' -f1)" = "$want" ] || { echo "libmegalon.so != its manifest" >&2; exit 1; }
mkdir -p "$OUT/bin" "$OUT/lib"
cp -p "$MB"/ship/lib/* "$OUT/lib/"
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DIRTY=$(git -C "$HERE" status --porcelain -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" | wc -l)
INFO="vdb-megalon commit=${COMMIT:0:12} dirty=$DIRTY megalon=$(sed -n 's/^build_id=//p' "$MB/manifest.txt")/$(sed -n 's/^flavor=//p' "$MB/manifest.txt")/$(sed -n 's/^wmeta_layout=//p' "$MB/manifest.txt")"
FLAGS=(-std=c++17 -O3 -g -mavx2 -mfma -fopenmp-simd -pthread -Wall -Wextra
       -I"$HERE/.." -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common")
c++ "${FLAGS[@]}" "$HERE/server.cc" -o "$OUT/bin/vdb-server" -Wl,--enable-new-dtags,-rpath,'$ORIGIN/../lib'
c++ "${FLAGS[@]}" "$HERE/../tools/build_index.cc" -o "$OUT/bin/vdb-build-index"
c++ -std=c++17 -O2 -g -fPIC -shared -Wall -Wextra -I"$HERE" -I"$MSRC/include" -DVDB_SHIM_INFO="\"$INFO\"" \
    "$HERE/megalon_shim.cc" -o "$OUT/lib/libvdb-megalon.so" -L"$OUT/lib" -lmegalon -Wl,--enable-new-dtags,-rpath,'$ORIGIN',--no-undefined,--no-as-needed
# every NEEDED of the shim must resolve inside lib/ or be a system library
LD_LIBRARY_PATH= ldd "$OUT/lib/libvdb-megalon.so" | grep -q "not found" && { ldd "$OUT/lib/libvdb-megalon.so"; exit 1; }
{ echo "# vdb-server Megalon build (CXL_SWMC/workloads/vectordb/server/build-megalon.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$COMMIT dirty=$DIRTY"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$HERE" diff HEAD -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" | sha256sum | cut -c1-64)"
  echo "shim_info=$INFO"
  echo "megalon_build=$MB"
  grep -E '^(source_commit|source_dirty_diff_sha256|build_id|flavor|wmeta_layout|cmake_effective)=' "$MB/manifest.txt" | sed 's/^/megalon./'
  echo "megalon.manifest_sha256=$(sha256sum "$MB/manifest.txt" | cut -d' ' -f1)"
  echo "cxx=$(c++ --version | head -1)"
  (cd "$OUT" && find bin lib -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  for f in bin/vdb-server lib/libvdb-megalon.so; do echo "runpath[$f]=$(readelf -d "$OUT/$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"; done
  echo "glibc_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/libvdb-megalon.so "$OUT"/lib/libmegalon.so | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/libvdb-megalon.so "$OUT"/lib/libmegalon.so | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
