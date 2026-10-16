#!/bin/bash
# Negative-control build of lmdb-stress (tests only, never deployed): liblmdb compiled with -DMDB_CXL_TEST_SCAN, so a
# writer's oldest-reader scan can be restricted by $MDB_CXL_TEST_SCAN=lo:hi (e.g. its own node's slots only). Used by
# tests/host_test.sh to show that lmdb-stress detects a broken cross-node MVCC rule.
# usage: build_negative.sh <out dir>   (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1; HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd)
mkdir -p "$OUT/bin" "$OUT/obj"
for f in mdb midl; do cc -O2 -g -pthread -DMDB_CXL_TEST_SCAN -c "$W/server/liblmdb/$f.c" -o "$OUT/obj/$f.o"; done
c++ -std=c++17 -O2 -g -pthread -I"$W" -I"$W/server" -I"$W/server/liblmdb" -I"$ROOT/experiments/loadgen" \
    -I"$ROOT/systems/common" -I"$ROOT/workloads/vectordb/server" "$W/tools/lmdb_stress.cc" "$OUT/obj/mdb.o" \
    "$OUT/obj/midl.o" -ldl -o "$OUT/bin/lmdb-stress-negative"
rm -rf "$OUT/obj"; echo "built $OUT/bin/lmdb-stress-negative"
