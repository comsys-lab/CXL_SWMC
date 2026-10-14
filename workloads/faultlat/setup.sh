#!/usr/bin/env bash
# faultlat setup: build the binary (on the Host, then copy to the guests, or
# on a guest). Usage: setup.sh [build-dir]   (default: this directory)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here}
mkdir -p "$out"
make -C "$here" BIN="$out/faultlat" "$out/faultlat" >/dev/null
"$out/faultlat" 2>&1 | head -1 || true
sha256sum "$out/faultlat"
