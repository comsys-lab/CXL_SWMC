#!/bin/bash
# Build the rocksdb workload into OUT (outside the repo, e.g. builds/rocksdb/<n>) and write OUT/manifest.txt:
#   1. verify the RocksDB release tarball (sha256 below), extract it into OUT/rocksdb-src, apply patches/*.patch;
#   2. static librocksdb (CMake Release, RTTI on, no compression/gflags/liburing/tests/tools, -march baseline);
#   3. rocksdb-server against it.
# usage: build.sh <out dir> <rocksdb-v11.8.1.tar.gz> [jobs (32)]
#        (pin: nice -n 19 numactl --cpunodebind=1 --membind=1; never during a measurement)
set -euo pipefail
OUT=$1; TARBALL=$2; JOBS=${3:-32}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
RDB_VERSION=11.8.1
RDB_SHA256=618d9726a7cb1cf4ce034f4cdca49de98aa64867dda06b91371a791ae8921aff
[ "$(sha256sum "$TARBALL" | cut -d' ' -f1)" = "$RDB_SHA256" ] || { echo "tarball sha256 mismatch: $TARBALL" >&2; exit 1; }
[ ! -e "$OUT/manifest.txt" ] || { echo "$OUT already holds a build (new dir per build)" >&2; exit 1; }
mkdir -p "$OUT/bin"
SRC=$OUT/rocksdb-src
rm -rf "$SRC" && mkdir -p "$SRC"
tar xzf "$TARBALL" -C "$SRC" --strip-components=1
for p in "$W"/patches/*.patch; do patch -s -d "$SRC" -p1 < "$p"; done
cmake -S "$SRC" -B "$OUT/rocksdb-build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DUSE_RTTI=1 -DPORTABLE=1 \
  -DWITH_GFLAGS=OFF -DWITH_LIBURING=OFF -DWITH_SNAPPY=OFF -DWITH_LZ4=OFF -DWITH_ZLIB=OFF -DWITH_ZSTD=OFF \
  -DWITH_BZ2=OFF -DWITH_JEMALLOC=OFF -DWITH_TESTS=OFF -DWITH_TOOLS=OFF -DWITH_CORE_TOOLS=OFF \
  -DWITH_BENCHMARK_TOOLS=OFF -DWITH_TRACE_TOOLS=OFF -DROCKSDB_BUILD_SHARED=OFF -DFAIL_ON_WARNINGS=OFF > "$OUT/cmake.log"
ninja -C "$OUT/rocksdb-build" -j "$JOBS" rocksdb > "$OUT/ninja.log"
LIB=$OUT/rocksdb-build/librocksdb.a
FLAGS=(-std=c++20 -O2 -g -pthread -Wall -Wextra -DROCKSDB_USE_RTTI -I"$SRC/include" -I"$W" -I"$HERE"
       -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common" -I"$ROOT/systems/megalon/shim"
       -I"$ROOT/systems/popcorn_new/include" -I"$ROOT/workloads/kv/server")
c++ "${FLAGS[@]}" "$HERE/server.cc" "$LIB" -ldl -o "$OUT/bin/rocksdb-server"
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DEPS=("$W" "$ROOT/workloads/lmdb/proto.h" "$ROOT/systems/common" "$ROOT/experiments/loadgen/frame.h" "$ROOT/workloads/kv/server/opsplit.h" "$ROOT/systems/popcorn_new/include")
DIRTY=$(git -C "$HERE" status --porcelain --untracked-files=all -- "${DEPS[@]}" | wc -l)
SRCHASH=$(cd "$ROOT" && find workloads/rocksdb workloads/lmdb/proto.h systems/common systems/popcorn_new/include/swmc_acct.h \
            workloads/kv/server/opsplit.h experiments/loadgen/frame.h systems/megalon/shim/megalon_objapi.h \
            -type f \( -name '*.h' -o -name '*.cc' -o -name '*.sh' -o -name '*.patch' \) | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
(cd "$ROOT" && tar --sort=name --mtime=@0 --owner=0 --group=0 -cf - workloads/rocksdb workloads/lmdb/proto.h systems/common \
   systems/popcorn_new/include/swmc_acct.h workloads/kv/server/opsplit.h experiments/loadgen/frame.h \
   systems/megalon/shim/megalon_objapi.h) | gzip -n > "$OUT/src.tar.gz"
{ echo "# rocksdb build (CXL_SWMC/workloads/rocksdb/server/build.sh)"; echo "date=$(date -Is)"; echo "host=$(hostname)"
  echo "source_commit=$COMMIT dirty_files=$DIRTY"
  echo "source_tree_sha256=$SRCHASH   # sha256 over sha256sum of the sources listed in build.sh (dirty tree identity)"
  echo "rocksdb_version=$RDB_VERSION tarball_sha256=$RDB_SHA256"
  for p in "$W"/patches/*.patch; do echo "patch[$(basename "$p")]=$(sha256sum "$p" | cut -d' ' -f1)"; done
  echo "cmake=-DCMAKE_BUILD_TYPE=Release -DUSE_RTTI=1 -DPORTABLE=1 no-compression no-gflags no-liburing static"
  echo "cc=$(cc --version | head -1)"; echo "cxx=$(c++ --version | head -1)"
  echo "librocksdb_sha256=$(sha256sum "$LIB" | cut -d' ' -f1)"
  echo "src_tar_sha256=$(sha256sum "$OUT/src.tar.gz" | cut -d' ' -f1)"
  (cd "$OUT" && find bin -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
