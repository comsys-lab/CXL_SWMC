#!/bin/bash
# Build recsys for the Megalon backend into OUT: bin/* as build.sh, lib/libmegalon-objapi.so (the shared object-API
# shim, systems/megalon/shim, linked against libmegalon) and the Megalon ship libraries of MEGALON_BUILD;
# RUNPATH $ORIGIN/../lib. recsys-server dlopen()s the shim only for --backend megalon.
# usage: build-megalon.sh <out dir> <megalon build dir, e.g. builds/megalon/69>   (pin to node 1)
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
COMMIT=$(git -C "$HERE" rev-parse HEAD)
INFO=$("$ROOT/systems/megalon/shim/build-shim.sh" "$OUT" "$MB" "recsys-megalon commit=${COMMIT:0:12}")
EXTRA_LDFLAGS="-Wl,--enable-new-dtags,-rpath,\$ORIGIN/../lib" "$HERE/build.sh" "$OUT"
{ echo "shim_info=$INFO"; echo "megalon_build=$MB"
  grep -E '^(source_commit|source_dirty_diff_sha256|build_id|flavor|wmeta_layout|cmake_effective)=' "$MB/manifest.txt" | sed 's/^/megalon./'
  echo "megalon.manifest_sha256=$(sha256sum "$MB/manifest.txt" | cut -d' ' -f1)"
  echo "runpath[bin/recsys-server]=$(readelf -d "$OUT/bin/recsys-server" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"; } >> "$OUT/manifest.txt"
echo "built $OUT (megalon)"
