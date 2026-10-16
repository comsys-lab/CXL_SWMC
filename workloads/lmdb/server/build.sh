#!/bin/bash
# Build lmdb-server, lmdb-image and lmdb-stress (patched liblmdb, no external libraries) into OUT/bin and write
# OUT/manifest.txt. With a Megalon build dir as 2nd argument also lib/libvdb-megalon.so (the vectordb dlopen shim,
# workloads/vectordb/server/megalon_shim.cc, unchanged) + Megalon's ship libraries; RUNPATH $ORIGIN/../lib.
# The binaries are the same for both: --backend plain never loads the shim.
# usage: build.sh <out dir> [<megalon build dir, e.g. builds/megalon/68>]
#        (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1; MB=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
VSHIM=$ROOT/workloads/vectordb/server
mkdir -p "$OUT/bin" "$OUT/obj"
CFLAGS=(-O2 -g -pthread -W -Wall -Wno-unused-parameter -Wbad-function-cast -Wuninitialized)
for f in mdb midl; do cc "${CFLAGS[@]}" -c "$HERE/liblmdb/$f.c" -o "$OUT/obj/$f.o"; done
FLAGS=(-std=c++17 -O2 -g -pthread -Wall -Wextra -I"$W" -I"$HERE" -I"$HERE/liblmdb" -I"$ROOT/experiments/loadgen"
       -I"$ROOT/systems/common" -I"$VSHIM")
LINK=("$OUT/obj/mdb.o" "$OUT/obj/midl.o" -ldl)
RP=()
if [ -n "$MB" ]; then
  MB=$(cd "$MB" && pwd); MSRC=$ROOT/systems/megalon/src
  [ -f "$MB/manifest.txt" ] && [ -f "$MB/ship/lib/libmegalon.so" ] || { echo "not a Megalon build: $MB" >&2; exit 1; }
  want=$(sed -n 's/^sha256\[lib\/libmegalon.so\]=//p' "$MB/manifest.txt")
  [ "$(sha256sum "$MB/ship/lib/libmegalon.so" | cut -d' ' -f1)" = "$want" ] || { echo "libmegalon.so != its manifest" >&2; exit 1; }
  mkdir -p "$OUT/lib"; cp -p "$MB"/ship/lib/* "$OUT/lib/"
  RP=(-Wl,--enable-new-dtags,-rpath,'$ORIGIN/../lib')
fi
c++ "${FLAGS[@]}" "$HERE/server.cc" "${LINK[@]}" -o "$OUT/bin/lmdb-server" "${RP[@]}"
c++ "${FLAGS[@]}" "$W/tools/lmdb_image.cc" "${LINK[@]}" -o "$OUT/bin/lmdb-image"
c++ "${FLAGS[@]}" "$W/tools/lmdb_stress.cc" "${LINK[@]}" -o "$OUT/bin/lmdb-stress" "${RP[@]}"
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DIRTY=$(git -C "$HERE" status --porcelain --untracked-files=all -- "$W" "$ROOT/systems/common" "$ROOT/experiments/loadgen" "$VSHIM" | wc -l)
SRCHASH=$(cd "$ROOT" && find workloads/lmdb/proto.h workloads/lmdb/server workloads/lmdb/tools systems/common \
            workloads/vectordb/server/megalon_api.h workloads/vectordb/server/megalon_shim.cc experiments/loadgen/frame.h \
            -type f \( -name '*.h' -o -name '*.c' -o -name '*.cc' -o -name '*.sh' \) | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
if [ -n "$MB" ]; then
  INFO="lmdb-megalon commit=${COMMIT:0:12} dirty=$DIRTY src=${SRCHASH:0:12} megalon=$(sed -n 's/^build_id=//p' "$MB/manifest.txt")/$(sed -n 's/^flavor=//p' "$MB/manifest.txt")/$(sed -n 's/^wmeta_layout=//p' "$MB/manifest.txt")"
  c++ -std=c++17 -O2 -g -fPIC -shared -Wall -Wextra -I"$VSHIM" -I"$MSRC/include" -DVDB_SHIM_INFO="\"$INFO\"" \
      "$VSHIM/megalon_shim.cc" -o "$OUT/lib/libvdb-megalon.so" -L"$OUT/lib" -lmegalon -Wl,--enable-new-dtags,-rpath,'$ORIGIN',--no-undefined,--no-as-needed
  LD_LIBRARY_PATH= ldd "$OUT/lib/libvdb-megalon.so" | grep -q "not found" && { ldd "$OUT/lib/libvdb-megalon.so"; exit 1; }
fi
rm -rf "$OUT/obj"
# exact sources of this build (the tree may be uncommitted): workloads/lmdb without third_party + shared headers used
(cd "$ROOT" && tar --sort=name --mtime=@0 --owner=0 --group=0 -cf - --exclude=workloads/lmdb/third_party \
   workloads/lmdb/proto.h workloads/lmdb/server workloads/lmdb/tools workloads/lmdb/loadgen workloads/lmdb/tests \
   systems/common workloads/vectordb/server/megalon_api.h workloads/vectordb/server/megalon_shim.cc experiments/loadgen/frame.h) | gzip -n > "$OUT/src.tar.gz"
{ echo "# lmdb build (CXL_SWMC/workloads/lmdb/server/build.sh)"; echo "date=$(date -Is)"; echo "host=$(hostname)"
  echo "source_commit=$COMMIT dirty_files=$DIRTY"
  echo "source_tree_sha256=$SRCHASH   # sha256 over sha256sum of the sources listed in build.sh (dirty tree identity)"
  echo "liblmdb=0.9.70 base=workloads/lmdb/third_party/LMDB/libraries/liblmdb/mdb.c sha256=$(sha256sum "$W/third_party/LMDB/libraries/liblmdb/mdb.c" | cut -d' ' -f1)"
  echo "liblmdb_patched_mdb_c_sha256=$(sha256sum "$HERE/liblmdb/mdb.c" | cut -d' ' -f1)"
  echo "liblmdb_patch_sha256=$(diff -u "$W/third_party/LMDB/libraries/liblmdb/mdb.c" "$HERE/liblmdb/mdb.c" | tail -n +3 | sha256sum | cut -d' ' -f1)"
  if [ -n "$MB" ]; then
    echo "shim_info=$INFO"; echo "megalon_build=$MB"
    grep -E '^(source_commit|source_dirty_diff_sha256|build_id|flavor|wmeta_layout|cmake_effective)=' "$MB/manifest.txt" | sed 's/^/megalon./'
    echo "megalon.manifest_sha256=$(sha256sum "$MB/manifest.txt" | cut -d' ' -f1)"
  fi
  echo "cc=$(cc --version | head -1)"; echo "cxx=$(c++ --version | head -1)"
  echo "src_tar_sha256=$(sha256sum "$OUT/src.tar.gz" | cut -d' ' -f1)"
  (cd "$OUT" && find bin lib -type f 2>/dev/null | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
