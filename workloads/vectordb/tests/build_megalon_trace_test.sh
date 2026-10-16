#!/bin/bash
# Build the Megalon wrapper trace / per-operation arithmetic unit test (Host only; fake object API v2, no Megalon
# library, no shared memory). usage: build_megalon_trace_test.sh <out binary>; run: <out binary> <scratch dir>, then
# python3 tests/classify_sharing_test.py <scratch dir>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
c++ -std=c++17 -O1 -g -fopenmp-simd -mavx2 -mfma -Wall -Wextra -pthread -I"$HERE/.." -I"$HERE/../server" \
  -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common" -I"$ROOT/systems/megalon/shim" \
  -I"$ROOT/systems/popcorn_new/include" "$HERE/megalon_trace_test.cc" -o "$1" -ldl
