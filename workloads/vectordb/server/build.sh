#!/bin/bash
# Build vdb-server against a Knowhere build dir (its compile flags from compile_commands.json) into OUT/bin,
# ship non-system libraries into OUT/lib (RUNPATH $ORIGIN/../lib), write OUT/manifest.txt.
# usage: build.sh <knowhere build dir> <out dir>      (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
KB=$(cd "$1" && pwd); OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
mkdir -p "$OUT/bin" "$OUT/lib"
mapfile -t FLAGS < <(python3 - "$KB/compile_commands.json" <<'PY'
import json, shlex, sys
cc = json.load(open(sys.argv[1]))
e = [x for x in cc if x["file"].endswith("src/index/hnsw/faiss_hnsw.cc")][0]
a = e.get("arguments") or shlex.split(e["command"])
i = 1
while i < len(a):
    x = a[i]
    if x == "-isystem":
        print(x); print(a[i + 1]); i += 2; continue
    if x.startswith(("-D", "-I", "-std=")) and x != "-Dknowhere_EXPORTS":
        print(x)
    i += 1
PY
)
[ ${#FLAGS[@]} -gt 0 ] || { echo "no compile flags from $KB/compile_commands.json" >&2; exit 1; }
c++ -O3 -g -mavx2 -mfma -fopenmp -pthread -Wall -Wextra "${FLAGS[@]}" \
  -I"$HERE/.." -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common" \
  "$HERE/server.cc" -o "$OUT/bin/vdb-server" -L"$KB" -lknowhere -Wl,-rpath,'$ORIGIN/../lib'
c++ -O3 -g -fopenmp -pthread "${FLAGS[@]}" "$HERE/../tools/build_index.cc" -o "$OUT/bin/vdb-build-index" \
  -L"$KB" -lknowhere -Wl,-rpath,'$ORIGIN/../lib'
# ship every library except the core runtime (guests may lack openblas/gfortran/gomp/glog)
LD_LIBRARY_PATH="$KB" ldd "$OUT/bin/vdb-server" | awk '/=> \// {print $3}' | \
  grep -vE '/(libc|libm|libpthread|libdl|librt|libgcc_s|libstdc\+\+|ld-linux-x86-64)\.so' | \
  while read -r l; do cp -L "$l" "$OUT/lib/"; done
cp -L "$KB/libknowhere.so" "$OUT/lib/"
{ echo "# vdb-server build (CXL_SWMC/workloads/vectordb/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- "$HERE/.." "$ROOT/systems/common" "$ROOT/experiments/loadgen" | wc -l)"
  echo "knowhere_build=$KB knowhere_commit=$(git -C "$ROOT/workloads/rag/vectordb/vectorDB/external/knowhere" rev-parse HEAD)"
  echo "cxx=$(c++ --version | head -1)"
  (cd "$OUT" && find bin lib -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/* 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* "$OUT"/lib/* 2>/dev/null | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
