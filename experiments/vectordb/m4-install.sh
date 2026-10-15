#!/bin/bash
# Copy one of our vdb-server builds to both guests (standing grant A1) and log the sha256s (reports/M4-vdb-packet.md,
# reports/M5-pilot-packet.md). Refuses an existing install dir.
# usage: m4-install.sh <log file> plain|megalon
#   plain:   VPLAIN (default /home/comsys/vdb8) <- PLAIN_BUILD (default builds/vdb/8): bin/vdb-server, bin/vdb-node.sh,
#            cfg/cxl_region.yaml
#   megalon: VMEG (default /home/comsys/vdbm5) <- MEG_BUILD (default builds/vdb-megalon/5): bin/vdb-server, lib/*,
#            bin/vdb-node.sh, cfg/cxl_region.yaml, cfg/megalon.yaml <- MEG_CFG (default systems/megalon/vectordb-2vm.yaml)
set -euo pipefail
P=/home/comsys/sungsu/destijl-control C=$P/CXL_SWMC LOG=$1 WHAT=$2
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
case "$WHAT" in
  plain) V=${VPLAIN:-/home/comsys/vdb8} B=${PLAIN_BUILD:-$P/builds/vdb/8};;
  megalon) V=${VMEG:-/home/comsys/vdbm5} B=${MEG_BUILD:-$P/builds/vdb-megalon/5} CFG=${MEG_CFG:-$C/systems/megalon/vectordb-2vm.yaml}
           grep -q "^source_commit=.* dirty=0$" $B/manifest.txt || { echo "megalon build not clean: $B"; exit 1; };;
  *) echo "plain|megalon"; exit 2;;
esac
[ -f $B/bin/vdb-server ] || { echo "no build $B"; exit 1; }
for ip in 192.168.122.100 192.168.122.101; do
  $SSH comsys@$ip "test ! -e $V && mkdir -p $V/bin $V/cfg $([ $WHAT = megalon ] && echo $V/lib)" < /dev/null
  scp -q $B/bin/vdb-server $C/scripts/guest/vdb-node.sh comsys@$ip:$V/bin/
  scp -q $C/config/cxl_region.yaml comsys@$ip:$V/cfg/
  if [ $WHAT = megalon ]; then scp -q $B/lib/* comsys@$ip:$V/lib/; scp -q $CFG comsys@$ip:$V/cfg/megalon.yaml; fi
  { echo "== $ip $(date -Is) $V <- $B"; $SSH comsys@$ip "sha256sum $V/bin/* $V/cfg/* \$(ls $V/lib/* 2>/dev/null); echo ldd_not_found=\$(ldd $V/bin/vdb-server \$(ls $V/lib/libvdb-megalon.so 2>/dev/null) | grep -c 'not found')" < /dev/null; } | tee -a $LOG
done
{ echo "== Host expected ($B)"; sha256sum $B/bin/vdb-server $C/scripts/guest/vdb-node.sh $C/config/cxl_region.yaml
  [ $WHAT = megalon ] && sha256sum $B/lib/* $CFG; true; } | tee -a $LOG
