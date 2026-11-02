#!/bin/bash
# RocksDB install (reports/ROCKSDB-V1-packet.md): copy our build to every guest (standing grant A: our artifacts
# under /home/comsys/<dir>), print the guests' and the Host's sha256s. Refuses an existing install dir.
#   $L  bin/{rocksdb-server,rocksdb-node.sh}, cfg/cxl_region.yaml, runs/   (plain backend: all-HWcc, Popcorn)
# The image is not installed: every run builds a fresh one inside the servers.
# usage: install.sh <log file>     env: L (/home/comsys/rocksdb3), BUILD (builds/rocksdb/3),
#        NODES (192.168.122.100 192.168.122.101), REGION (CXL_SWMC/config/cxl_region.yaml; N > 2 Popcorn:
#        config/cxl_region-ring2m.yaml), copied as cfg/cxl_region.yaml
set -euo pipefail
P=/home/comsys/sungsu/destijl-control C=$P/CXL_SWMC LOG=$1
L=${L:-/home/comsys/rocksdb3} B=${BUILD:-$P/builds/rocksdb/3} REGION=${REGION:-$C/config/cxl_region.yaml}
read -r -a NODE <<< "${NODES:-192.168.122.100 192.168.122.101}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
[ -e "$LOG" ] && { echo "refusing: $LOG exists"; exit 2; }
[ -f "$B/manifest.txt" ] || { echo "not a build: $B"; exit 2; }
# MEG_CFG (Megalon runs, eval run2): Host Megalon config, copied as cfg/megalon.yaml; the build's lib/ (shim
# libmegalon-objapi.so + Megalon's ship libraries, RUNPATH $ORIGIN/../lib) is copied as lib/
MEG_CFG=${MEG_CFG:-}
if [ -n "$MEG_CFG" ]; then
  [ -f "$MEG_CFG" ] && [ -f "$B/lib/libmegalon-objapi.so" ] && [ -f "$B/lib/libmegalon.so" ] || { echo "MEG_CFG $MEG_CFG or $B/lib (Megalon) missing"; exit 2; }
fi
for ip in "${NODE[@]}"; do
  $SSH comsys@"$ip" "test ! -e $L && mkdir -p $L/bin $L/cfg $L/runs${MEG_CFG:+ $L/lib}" < /dev/null
  scp -q "$B/bin/rocksdb-server" "$C/experiments/rocksdb/rocksdb-node.sh" comsys@"$ip":"$L/bin/"
  scp -q "$REGION" comsys@"$ip":"$L/cfg/cxl_region.yaml"
  if [ -n "$MEG_CFG" ]; then
    scp -q "$MEG_CFG" comsys@"$ip":"$L/cfg/megalon.yaml"
    scp -q "$B"/lib/* comsys@"$ip":"$L/lib/"
  fi
  { echo "== $ip $(date -Is)"; $SSH comsys@"$ip" "cd $L && find . -type f -not -path './runs/*' | sort | xargs sha256sum; echo ldd_not_found=\$(ldd bin/rocksdb-server | grep -c 'not found');${MEG_CFG:+ echo ldd_shim_not_found=\$(ldd lib/libmegalon-objapi.so | grep -c 'not found');} echo glibc=\$(ldd --version | head -1)" < /dev/null; } | tee -a "$LOG"
done
{ echo "== Host expected"; (cd "$B" && sha256sum bin/rocksdb-server); sha256sum "$C/experiments/rocksdb/rocksdb-node.sh" "$REGION"; echo "region=$REGION $(grep -E '^msg_ring:' "$REGION")"
  [ -z "$MEG_CFG" ] || { (cd "$B" && sha256sum lib/*); echo "megalon_cfg=$MEG_CFG $(sha256sum < "$MEG_CFG" | cut -c1-64)"; }
  grep -E '^(source_commit|rocksdb_version|patch|glibc_max|glibcxx_max|megalon_build|shim_info)' "$B/manifest.txt"; } | tee -a "$LOG"
