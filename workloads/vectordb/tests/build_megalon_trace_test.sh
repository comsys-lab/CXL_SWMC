#!/bin/bash
# Build the Megalon wrapper trace unit test (Host only; fake object API, no Megalon library, no shared memory).
# usage: build_megalon_trace_test.sh <out binary>; run: <out binary> <scratch dir>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
c++ -std=c++17 -O1 -g -fopenmp-simd -Wall -Wextra -pthread -I"$HERE/.." -I"$HERE/../server" -I"$ROOT/experiments/loadgen" \
  -I"$ROOT/systems/common" "$HERE/megalon_trace_test.cc" -o "$1" -ldl
