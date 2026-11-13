#!/bin/bash
# Build recsys-server (plain backend; also runs --backend megalon if lib/libmegalon-objapi.so is next to it) and the
# recsys tools into OUT/bin; write OUT/manifest.txt.
# usage: build.sh <out dir>      (pin: nice -n 19 numactl --cpunodebind=1 --membind=1)
set -euo pipefail
OUT=$1
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
mkdir -p "$OUT/bin" "$OUT/obj"
# -march: the guests and the Host are Sapphire Rapids (avx512f/bw/vl exposed to the guests, no AMX)
FLAGS=(-std=c++17 -O3 -g -mavx2 -mfma -mavx512f -mavx512vl -mavx512bw -pthread -Wall -Wextra
       -I"$W" -I"$HERE" -I"$ROOT/experiments/loadgen" -I"$ROOT/systems/common" -I"$ROOT/systems/megalon/shim" -I"$ROOT/systems/popcorn_new/include")
# libdestijl (systems/destijl/lib; de_stijl_set_staleness only): recsys-server applies $CXL_DESTIJL_T_US with
# CXL_SYSTEM=ds to the embedding tables (cxl_region.h region_apply_staleness); a no-op for every other system
DSL=$ROOT/systems/destijl/lib
cc -O2 -g -Wall -Wextra -Werror -std=gnu11 -I"$DSL" -c "$DSL/de_stijl.c" -o "$OUT/obj/de_stijl.o"
ar rcs "$OUT/obj/libdestijl.a" "$OUT/obj/de_stijl.o"
c++ "${FLAGS[@]}" -mf16c -DCXL_REGION_DESTIJL -I"$DSL" "$HERE/server.cc" -o "$OUT/bin/recsys-server" -L"$OUT/obj" -ldestijl -ldl ${EXTRA_LDFLAGS:-}
c++ "${FLAGS[@]}" "$W/tools/gen_samples.cc" -o "$OUT/bin/recsys-gen-samples"
c++ "${FLAGS[@]}" "$W/tools/rate_calib.cc" -o "$OUT/bin/recsys-rate"
c++ "${FLAGS[@]}" "$W/tests/model_test.cc" -o "$OUT/bin/recsys-model-test"
c++ "${FLAGS[@]}" "$W/tests/chunk_test.cc" -o "$OUT/bin/recsys-chunk-test"  # serving split (server/chunk.h)
# v7 (DESIGN.md §10): Host scorer / prequential trainer (baseline + frozen AUC, updater CPU) and the backward test
c++ "${FLAGS[@]}" -mf16c "$W/tools/recsys_score.cc" -o "$OUT/bin/recsys-score"
c++ "${FLAGS[@]}" -mf16c "$W/tests/model_grad_test.cc" -o "$OUT/bin/recsys-model-grad-test"
c++ "${FLAGS[@]}" -mf16c "$W/tests/fp16_sr_test.cc" -o "$OUT/bin/recsys-fp16-sr-test"  # stochastic rounding (emb_v7.h)
COMMIT=$(git -C "$HERE" rev-parse HEAD)
DIRTY=$(git -C "$HERE" status --porcelain -- "$W" "$ROOT/systems/common" "$ROOT/experiments/loadgen" "$ROOT/systems/megalon/shim" "$ROOT/systems/popcorn_new/include" "$DSL" | wc -l)
{ echo "# recsys build (CXL_SWMC/workloads/recsys/server/build.sh)"; echo "date=$(date -Is)"
  echo "source_commit=$COMMIT dirty=$DIRTY"
  echo "source_tree_sha256=$(cd "$ROOT" && find workloads/recsys systems/common experiments/loadgen/frame.h systems/megalon/shim systems/popcorn_new/include systems/destijl/lib/de_stijl.c systems/destijl/lib/de_stijl.h -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
  echo "cxx=$(c++ --version | head -1)"; echo "flags=${FLAGS[*]}"
  (cd "$OUT" && find bin $([ -d lib ] && echo lib) -type f | sort | while read -r f; do echo "sha256[$f]=$(sha256sum "$f" | cut -d' ' -f1)"; done)
  echo "glibc_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
  echo "glibcxx_max=$(objdump -T "$OUT"/bin/* | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"; } > "$OUT/manifest.txt"
echo "built $OUT"
