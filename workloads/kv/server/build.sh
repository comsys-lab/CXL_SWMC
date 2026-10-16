#!/bin/bash
# Build kv-server against one Megalon build into OUT: bin/kv-server, lib/libkv-megalon.so (kv_shim.cc linked against
# that build's libmegalon.so) plus the Megalon ship libraries; RUNPATH $ORIGIN/../lib (bin) and $ORIGIN (lib).
#   plain backend   (all-HWcc, page MSI): a hwcc-flavor Megalon build   -> builds/kv/<n>
#   megalon backend (Megalon):           a megalon-flavor Megalon build -> builds/kv-megalon/<n>
# Also lib/libmegalon-objapi.so (systems/megalon/shim via objapi-shim.sh; v1 fallback for Megalon <= 70): kv-server --backend megalon loads it for the
# per-thread coherence time (thread_coh, API v2; a v1 shim gives C = 0). Per-op split: opsplit.h (MOT1 v6 Fig 2).
# kv-server refuses a --backend that does not match the flavor of the shim it loads.
# usage: build.sh <out dir> <megalon build dir>     (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd)
MSRC=$ROOT/systems/megalon/src
[ -f "$MB/manifest.txt" ] && [ -f "$MB/ship/lib/libmegalon.so" ] || { echo "not a Megalon build: $MB" >&2; exit 1; }
want=$(sed -n 's/^sha256\[lib\/libmegalon.so\]=//p' "$MB/manifest.txt")
[ "$(sha256sum "$MB/ship/lib/libmegalon.so" | cut -d' ' -f1)" = "$want" ] || { echo "libmegalon.so != its manifest" >&2; exit 1; }
FLAVOR=$(sed -n 's/^flavor=//p' "$MB/manifest.txt")
case $FLAVOR in hwcc|megalon) ;; *) echo "unknown Megalon flavor '$FLAVOR'" >&2; exit 1;; esac
mkdir -p "$OUT/bin" "$OUT/lib"
cp -p "$MB"/ship/lib/* "$OUT/lib/"
SRCS=("$W" "$ROOT/systems/common" "$ROOT/experiments/loadgen/frame.h" "$ROOT/systems/megalon/shim/megalon_objapi.h" "$ROOT/systems/popcorn_new/include/swmc_acct.h")
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DIRTY=$(git -C "$HERE" status --porcelain --untracked-files=all -- "${SRCS[@]}" | wc -l)
INFO="kv-megalon commit=${COMMIT:0:12} dirty=$DIRTY megalon=$(sed -n 's/^build_id=//p' "$MB/manifest.txt")/$FLAVOR/$(sed -n 's/^wmeta_layout=//p' "$MB/manifest.txt")"
FLAGS=(-std=c++17 -O2 -g -pthread -Wall -Wextra -I"$W" -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common"
       -I"$ROOT/systems/megalon/shim" -I"$ROOT/systems/popcorn_new/include")
c++ "${FLAGS[@]}" "$HERE/server.cc" -o "$OUT/bin/kv-server" -ldl -Wl,--enable-new-dtags,-rpath,'$ORIGIN/../lib'
# the shim reads Megalon's counter block through its own header (cxl_port.h: C++23 + abseil), so it is compiled with
# Megalon's toolchain (workspaces/toolchain clang 17, same libstdc++ as the server)
SHIM_CXX=${SHIM_CXX:-$ROOT/../workspaces/toolchain/llvm/bin/clang++-17}
"$SHIM_CXX" --gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11 -std=gnu++23 -O2 -g -fPIC -shared -Wall -Wextra \
    -I"$HERE" -I"$MSRC/include" -I"$MSRC/src" -I"$ROOT/systems/common" -I"$MSRC/third-party/abseil-cpp" \
    -DKV_SHIM_INFO="\"$INFO\"" -DKV_SHIM_FLAVOR="\"$FLAVOR\"" "$HERE/kv_shim.cc" -o "$OUT/lib/libkv-megalon.so" -L"$OUT/lib" -lmegalon \
    -Wl,--enable-new-dtags,-rpath,'$ORIGIN',--no-undefined,--no-as-needed
LD_LIBRARY_PATH= ldd "$OUT/lib/libkv-megalon.so" | grep -q "not found" && { ldd "$OUT/lib/libkv-megalon.so"; exit 1; }
OBJ=$("$HERE/objapi-shim.sh" "$OUT" "$MB" "kv-objapi commit=${COMMIT:0:12} dirty=$DIRTY")
OBJAPI_INFO=$(sed -n 's/^info=//p' <<< "$OBJ"); OBJAPI_SRC=$(sed -n 's/^source=//p' <<< "$OBJ")
OBJAPI_CC=$(sed -n 's/^cc_sha256=//p' <<< "$OBJ")
cp -p "$ROOT/scripts/guest/kv-node.sh" "$OUT/bin/" 2>/dev/null || true
{ echo "# kv-server build (CXL_SWMC/workloads/kv/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$COMMIT dirty=$DIRTY"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain --untracked-files=all -- "${SRCS[@]}" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$( { git -C "$HERE" diff HEAD -- "${SRCS[@]}"; git -C "$HERE" ls-files --others --exclude-standard --full-name -- "${SRCS[@]}" | (cd "$(git -C "$HERE" rev-parse --show-toplevel)" && xargs -r cat); } | sha256sum | cut -c1-64)"
  echo "shim_info=$INFO"
  echo "objapi_shim_info=$OBJAPI_INFO"
  echo "objapi_api_version=$(sed -n 's/^constexpr uint32_t kApiVersion = \([0-9]*\);.*/\1/p' "$ROOT/systems/megalon/shim/megalon_objapi.h")"
  echo "objapi_source=$OBJAPI_SRC   # working-tree: thread_coh implemented (Megalon >= 71); git:<ref>: v1 fallback, C = 0"
  echo "objapi_cc_sha256=$OBJAPI_CC"
  echo "backend=$([ "$FLAVOR" = hwcc ] && echo plain || echo megalon)"
  echo "megalon_build=$MB"
  grep -E '^(source_commit|source_dirty_diff_sha256|build_id|flavor|wmeta_layout|cmake_effective|build_sh|build_sh_sha256)=' "$MB/manifest.txt" | sed 's/^/megalon./'
  echo "megalon.manifest_sha256=$(sha256sum "$MB/manifest.txt" | cut -d' ' -f1)"
  echo "cxx=$(c++ --version | head -1)"; echo "shim_cxx=$("$SHIM_CXX" --version | head -1)"
  (cd "$OUT" && find bin lib -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  for f in bin/kv-server lib/libkv-megalon.so; do echo "runpath[$f]=$(readelf -d "$OUT/$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"; done
  echo "glibc_max=$(objdump -T "$OUT"/bin/kv-server "$OUT"/lib/*.so* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/kv-server "$OUT"/lib/*.so* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT ($INFO)"
