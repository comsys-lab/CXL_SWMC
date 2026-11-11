#!/bin/bash
# Build the loadgen with the socialgraph plugin (+ echo) and the socialgraph loadgen tools into OUT:
#   OUT/loadgen, OUT/echo_server (experiments/loadgen/build.sh), OUT/bin/sg-loadgen-mix (--mix value for rw:1),
#   OUT/bin/sg-loadgen-keys-test (generator unit test), OUT/bin/sg-loadgen-stub (protocol stub server).
# Then rewrites OUT/manifest.txt: source commit + dirty files + dirty diff sha256 (workloads/socialgraph and
# experiments/loadgen), compiler, sha256 of every artifact.
# usage: build.sh <out dir>      (run through scripts/ctl/build-wrap.sh; OUT outside the repo, e.g. builds/socialgraph-loadgen/<n>)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); WL=$(cd "$HERE/.." && pwd); REPO=$(git -C "$HERE" rev-parse --show-toplevel)
LG=$REPO/experiments/loadgen
mkdir -p "$OUT/bin"; OUT=$(cd "$OUT" && pwd)
bash "$LG/build.sh" "$OUT" "$HERE/socialgraph_plugin.cc" > /dev/null
FLAGS=(-std=c++17 -O2 -g -pthread -Wall -Wextra -Werror -I"$LG" -I"$HERE")
c++ "${FLAGS[@]}" "$HERE/sg_mix.cc" -o "$OUT/bin/sg-loadgen-mix"
c++ "${FLAGS[@]}" "$HERE/keys_test.cc" -o "$OUT/bin/sg-loadgen-keys-test"
c++ "${FLAGS[@]}" "$HERE/stub_server.cc" -o "$OUT/bin/sg-loadgen-stub"
PATHS=(workloads/socialgraph experiments/loadgen workloads/vectordb/proto.h)
{ echo "# socialgraph loadgen build (CXL_SWMC/workloads/socialgraph/loadgen/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$REPO" rev-parse HEAD) dirty=$(git -C "$REPO" status --porcelain -- "${PATHS[@]}" | wc -l)"
  echo "source_dirty_files=$(git -C "$REPO" status --porcelain -- "${PATHS[@]}" | awk '{print $2}' | tr '\n' ' ')"
  echo "source_dirty_diff_sha256=$(git -C "$REPO" diff HEAD -- "${PATHS[@]}" | sha256sum | cut -c1-64)"
  echo "branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  echo "cxx=$(c++ --version | head -1)"
  echo "plugins=echo_plugin.cc workloads/socialgraph/loadgen/socialgraph_plugin.cc"
  (cd "$OUT" && for f in loadgen echo_server $(find bin -type f | sort); do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/loadgen "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/loadgen "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
