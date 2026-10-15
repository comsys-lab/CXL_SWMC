#!/bin/bash
# Build the load generator with the given workload plugins into OUT (outside the repo, e.g. builds/loadgen/<n>).
# usage: build.sh <out dir> <plugin.cc ...>     (always includes echo_plugin.cc; writes <out>/manifest.txt)
set -euo pipefail
OUT=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
CXX=${CXX:-c++}
FLAGS=(-std=c++17 -O2 -g -Wall -Wextra -pthread -I"$HERE")
$CXX "${FLAGS[@]}" "$HERE/loadgen.cc" "$HERE/echo_plugin.cc" "$@" -o "$OUT/loadgen" ${LOADGEN_LIBS:-}
$CXX "${FLAGS[@]}" "$HERE/test/echo_server.cc" -o "$OUT/echo_server"
{ echo "# loadgen build (CXL_SWMC/experiments/loadgen/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- . | wc -l)"
  echo "cxx=$($CXX --version | head -1)"; echo "plugins=echo_plugin.cc $*"
  sha256sum "$OUT/loadgen" "$OUT/echo_server" | sed 's/^/sha256 /'; } > "$OUT/manifest.txt"
echo "built $OUT"
