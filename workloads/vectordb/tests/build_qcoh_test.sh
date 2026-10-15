#!/bin/bash
# Build and run the qcoh.h unit test (Host only; no device). usage: build_qcoh_test.sh <out dir>
set -euo pipefail
OUT=$1; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
c++ -std=c++17 -O2 -Wall -Wextra -I"$HERE/../server" "$HERE/qcoh_test.cc" -o "$OUT/qcoh_test"
TMPDIR=$OUT "$OUT/qcoh_test"
