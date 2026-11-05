#!/bin/bash
# Build the page-granularity layout Host test (tests/page_layout_test.cc) with the vdb-server flags (server/build.sh).
# usage: build_page_layout_test.sh <out binary>     (pin: scripts/ctl/build-wrap.sh)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
c++ -std=c++17 -O2 -g -mavx2 -mfma -fopenmp-simd -pthread -Wall -Wextra -I"$HERE/../server" -I"$ROOT/systems/common" \
  "$HERE/page_layout_test.cc" -o "$OUT"
