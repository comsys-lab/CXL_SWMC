#!/usr/bin/env bash
# faultlat run: one measurement step on THIS node (run on a guest).
#   run.sh <outdir> <step-name> <faultlat args...>
# Writes <outdir>/<step-name>.json (+ .csv raw samples) and <step-name>.env
# (kernel release, protocol, knobs). Example:
#   run.sh /tmp/fl r1 access --op read --pages 4096 --page-offset 0 --cpu 2
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=${FAULTLAT_BIN:-$here/faultlat}
out=$1; step=$2; shift 2
mkdir -p "$out"
: "${CXL_REGION_CONFIG:?set CXL_REGION_CONFIG to the region config}"
sys=/sys/kernel/swmc/page_coherence
{
  echo "step=$step"
  echo "date=$(date -Is)"
  echo "uname=$(uname -r)"
  echo "args=$*"
  echo "region_config=$CXL_REGION_CONFIG sha256=$(sha256sum "$CXL_REGION_CONFIG" | cut -d' ' -f1)"
  echo "bin_sha256=$(sha256sum "$bin" | cut -d' ' -f1)"
  for k in protocol managed_base managed_bytes acquire_flush downgrade_flush wait_spin_ns; do
    [ -r $sys/$k ] && echo "$k=$(cat $sys/$k)"
  done
  for p in /sys/module/swmc_kmsg/parameters/inline_dispatch /sys/module/cxl_shm/parameters/*; do
    [ -r "$p" ] && echo "$(basename "$p")=$(cat "$p")"
  done
  echo "loadavg=$(cat /proc/loadavg)"
} > "$out/$step.env"
"$bin" "$@" --out "$out/$step.json" --raw "$out/$step.csv"
