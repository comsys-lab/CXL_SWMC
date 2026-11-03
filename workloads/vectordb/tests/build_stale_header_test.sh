#!/bin/bash
# Build the stale-header guard Host test (tests/stale_header_test.cc) with the vdb-server flags (server/build.sh).
# usage: build_stale_header_test.sh <out binary>     (pin: scripts/ctl/build-wrap.sh)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
c++ -std=c++17 -O2 -g -mavx2 -mfma -fopenmp-simd -pthread -Wall -Wextra -I"$HERE/../server" -I"$ROOT/systems/common" \
  "$HERE/stale_header_test.cc" -o "$OUT"
