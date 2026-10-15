#!/bin/bash
# Build the shared object-API shim into OUT/lib: libmegalon-objapi.so (linked against libmegalon) plus the Megalon ship
# libraries of MEGALON_BUILD (checked against its manifest); RUNPATH $ORIGIN. Prints the shim info string.
# usage: build-shim.sh <out dir> <megalon build dir, e.g. builds/megalon/69> <info prefix, e.g. "recsys-megalon commit=...">
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd); PREFIX=${3:-shim}
HERE=$(cd "$(dirname "$0")" && pwd); MSRC=$HERE/../src
[ -f "$MB/manifest.txt" ] && [ -f "$MB/ship/lib/libmegalon.so" ] || { echo "not a Megalon build: $MB" >&2; exit 1; }
want=$(sed -n 's/^sha256\[lib\/libmegalon.so\]=//p' "$MB/manifest.txt")
[ "$(sha256sum "$MB/ship/lib/libmegalon.so" | cut -d' ' -f1)" = "$want" ] || { echo "libmegalon.so != its manifest" >&2; exit 1; }
mkdir -p "$OUT/lib"
cp -p "$MB"/ship/lib/* "$OUT/lib/"
INFO="$PREFIX megalon=$(sed -n 's/^build_id=//p' "$MB/manifest.txt")/$(sed -n 's/^flavor=//p' "$MB/manifest.txt")/$(sed -n 's/^wmeta_layout=//p' "$MB/manifest.txt")"
c++ -std=c++17 -O2 -g -fPIC -shared -Wall -Wextra -I"$HERE" -I"$MSRC/include" -DMSHIM_INFO="\"$INFO\"" \
    "$HERE/megalon_objapi.cc" -o "$OUT/lib/libmegalon-objapi.so" -L"$OUT/lib" -lmegalon \
    -Wl,--enable-new-dtags,-rpath,'$ORIGIN',--no-undefined,--no-as-needed
LD_LIBRARY_PATH= ldd "$OUT/lib/libmegalon-objapi.so" | grep -q "not found" && { ldd "$OUT/lib/libmegalon-objapi.so"; exit 1; }
echo "$INFO"
