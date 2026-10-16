#!/bin/bash
# Build lib/libmegalon-objapi.so (systems/megalon/shim) for a workload build (kv, lmdb) against one Megalon build.
#   Megalon build exports rackobj::GetObjectThreadCoh (build >= 71): systems/megalon/shim/build-shim.sh as is (API v2,
#     thread_coh implemented).
#   Older build (<= 70): the v1 fallback, i.e. the shim source of git ref $SHIM_V1_REF (default 89d4552a1 = the contract
#     commit: API v2 table with thread_coh = nullptr, so workloads report C = 0 and opt.meg_coh=0), compiled with
#     build-shim.sh's flags.
# Prints "info=<shim info>", "source=working-tree|git:<ref>" and "cc_sha256=<compiled shim source>".
# usage: objapi-shim.sh <out dir> <megalon build dir> <info prefix>
set -euo pipefail
OUT=$1; MB=$(cd "$2" && pwd); PREFIX=$3
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
S=$ROOT/systems/megalon/shim; MSRC=$ROOT/systems/megalon/src
if nm -D --defined-only "$MB/ship/lib/libmegalon.so" | grep GetObjectThreadCoh > /dev/null; then  # no -q: SIGPIPE + pipefail
  echo "info=$("$S/build-shim.sh" "$OUT" "$MB" "$PREFIX")"
  echo "source=working-tree"
  echo "cc_sha256=$(sha256sum "$S/megalon_objapi.cc" | cut -d' ' -f1)"
  exit 0
fi
REF=${SHIM_V1_REF:-89d4552a1}
want=$(sed -n 's/^sha256\[lib\/libmegalon.so\]=//p' "$MB/manifest.txt")
[ "$(sha256sum "$MB/ship/lib/libmegalon.so" | cut -d' ' -f1)" = "$want" ] || { echo "libmegalon.so != its manifest" >&2; exit 1; }
T=$OUT/objapi-v1-src; mkdir -p "$T" "$OUT/lib"
git -C "$ROOT" show "$REF:systems/megalon/shim/megalon_objapi.cc" > "$T/megalon_objapi.cc"
git -C "$ROOT" show "$REF:systems/megalon/shim/megalon_objapi.h" > "$T/megalon_objapi.h"
grep -q thread_coh "$T/megalon_objapi.cc" && { echo "$REF shim already implements thread_coh (not a v1 fallback)" >&2; exit 1; }
# the v1 source is compiled against the current header: its code (comments stripped) must be unchanged since REF
code() { sed -e 's://.*$::' -e 's:/\*.*\*/::' -e 's/[[:space:]]\+/ /g' -e '/^ *$/d' "$1"; }
[ "$(code "$T/megalon_objapi.h")" = "$(code "$S/megalon_objapi.h")" ] || { echo "contract header code changed since $REF: refusing the v1 fallback" >&2; exit 1; }
cp -p "$S/megalon_objapi.h" "$T/megalon_objapi.h"
cp -p "$MB"/ship/lib/* "$OUT/lib/"
INFO="$PREFIX megalon=$(sed -n 's/^build_id=//p' "$MB/manifest.txt")/$(sed -n 's/^flavor=//p' "$MB/manifest.txt")/$(sed -n 's/^wmeta_layout=//p' "$MB/manifest.txt") objapi=v1-fallback@$REF"
c++ -std=c++17 -O2 -g -fPIC -shared -Wall -Wextra -Wno-missing-field-initializers -I"$T" -I"$MSRC/include" -DMSHIM_INFO="\"$INFO\"" \
    "$T/megalon_objapi.cc" -o "$OUT/lib/libmegalon-objapi.so" -L"$OUT/lib" -lmegalon \
    -Wl,--enable-new-dtags,-rpath,'$ORIGIN',--no-undefined,--no-as-needed
LD_LIBRARY_PATH= ldd "$OUT/lib/libmegalon-objapi.so" | grep -q "not found" && { ldd "$OUT/lib/libmegalon-objapi.so" >&2; exit 1; }
echo "info=$INFO"
echo "source=git:$REF"
echo "cc_sha256=$(sha256sum "$T/megalon_objapi.cc" | cut -d' ' -f1)"
