#!/bin/bash
# Build zero_copy_test against a Knowhere build dir, reusing that build's compile flags (compile_commands.json).
# usage: build_zero_copy_test.sh <knowhere build dir (cmake)> <out binary>
set -euo pipefail
B=$1 OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
mapfile -t FLAGS < <(python3 - "$B/compile_commands.json" <<'PY'
import json, shlex, sys
cc = json.load(open(sys.argv[1]))
e = [x for x in cc if x["file"].endswith("src/index/hnsw/faiss_hnsw.cc")][0]
a = e.get("arguments") or shlex.split(e["command"])
i = 1
while i < len(a):
    x = a[i]
    if x == "-isystem":
        print(x); print(a[i + 1]); i += 2; continue
    if x.startswith(("-D", "-I", "-std=")) and x != "-Dknowhere_EXPORTS":
        print(x)
    i += 1
PY
)
c++ -O2 -fopenmp "${FLAGS[@]}" "$HERE/zero_copy_test.cc" -o "$OUT" -L"$B" -lknowhere -Wl,-rpath,"$B"
