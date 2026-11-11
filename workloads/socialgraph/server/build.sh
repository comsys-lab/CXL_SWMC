#!/bin/bash
# Build the socialgraph Host tools (sg-image-gen) and tests (sg-layout-test) into OUT/bin; write OUT/manifest.txt.
# (sg-server is added here in part 3.)
# usage: build.sh <out dir>      (run through scripts/ctl/build-wrap.sh)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); WL=$(cd "$HERE/.." && pwd)
mkdir -p "$OUT/bin"
FLAGS=(-std=c++17 -O2 -g -pthread -Wall -Wextra -Werror -I"$WL" -I"$HERE")
c++ "${FLAGS[@]}" "$WL/tools/sg_image_gen.cc" -o "$OUT/bin/sg-image-gen" -lz
c++ "${FLAGS[@]}" "$WL/tests/layout_test.cc" -o "$OUT/bin/sg-layout-test"
{ echo "# socialgraph build (CXL_SWMC/workloads/socialgraph/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- "$WL" | wc -l)"
  echo "source_dirty_files=$(git -C "$HERE" status --porcelain -- "$WL" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$HERE" diff HEAD -- "$WL" | sha256sum | cut -c1-64)"
  echo "cxx=$(c++ --version | head -1)"
  echo "zlib=$(grep -m1 '#define ZLIB_VERSION' /usr/include/zlib.h | awk '{print $3}')"
  (cd "$OUT" && find bin -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
