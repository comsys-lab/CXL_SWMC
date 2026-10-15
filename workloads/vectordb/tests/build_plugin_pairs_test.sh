#!/bin/bash
# Build the vectordb loadgen plugin unit test (Host only; no server, no shared memory).
# usage: build_plugin_pairs_test.sh <out binary>; run: <out binary> <data dir> <scratch dir>
#        (data dir: pool_b.fbin, queries.fbin (dim 768), writes.bin from gen_writes.py --mode update and
#         writes-indep.bin from --mode independent)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
c++ -std=c++17 -O1 -g -Wall -Wextra -pthread -I"$ROOT/experiments/loadgen" "$HERE/plugin_pairs_test.cc" -o "$1"
