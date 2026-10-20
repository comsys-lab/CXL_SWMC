#!/bin/bash
# Build umwait_ping into OUT (outside the repo, e.g. builds/umwait-ping/<n>); writes <out>/manifest.txt.
# usage: build.sh <out dir>
# Host: nice -n 19 numactl --cpunodebind=1 --membind=1 ./build.sh <out>   (not while workspaces/MEASUREMENT.lock exists)
# Static link so the same binary runs on the guests regardless of their libc.
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
CC=${CC:-gcc}
FLAGS=(-std=gnu11 -O2 -g -Wall -Wextra -mwaitpkg -static)
$CC "${FLAGS[@]}" "$HERE/umwait_ping.c" -o "$OUT/umwait_ping"
dirty_hash=$(git -C "$HERE" diff HEAD -- . | sha256sum | cut -d' ' -f1)
{ echo "# umwait_ping build (CXL_SWMC/workloads/microbench/umwait_ping/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$(git -C "$HERE" rev-parse HEAD) dirty=$(git -C "$HERE" status --porcelain -- . | wc -l) dirty_diff_sha256=$dirty_hash"
  echo "source_sha256=$(sha256sum "$HERE/umwait_ping.c" | cut -d' ' -f1)"
  echo "cc=$($CC --version | head -1)"; echo "flags=${FLAGS[*]}"; echo "host=$(uname -r)"
  sha256sum "$OUT/umwait_ping" | sed 's/^/sha256 /'; } > "$OUT/manifest.txt"
echo "built $OUT"
