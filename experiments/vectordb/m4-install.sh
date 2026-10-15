#!/bin/bash
# M4 (reports/M4-vdb-packet.md §3.1): copy our builds to both guests (standing grant A1), then print sha256s.
#   /home/comsys/vdb8:  bin/vdb-server (builds/vdb/8), bin/vdb-node.sh, cfg/cxl_region.yaml   (all-HWcc, Popcorn)
#   /home/comsys/vdbm5: bin/vdb-server, lib/* (builds/vdb-megalon/5), bin/vdb-node.sh, cfg/cxl_region.yaml,
#                       cfg/megalon.yaml (systems/megalon/vectordb-2vm.yaml)                      (Megalon)
# Refuses to overwrite an existing install dir. usage: m4-install.sh <log file>
set -euo pipefail
P=/home/comsys/sungsu/destijl-control C=$P/CXL_SWMC LOG=$1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
for ip in 192.168.122.100 192.168.122.101; do
  $SSH comsys@$ip 'test ! -e /home/comsys/vdb8 && test ! -e /home/comsys/vdbm5 && mkdir -p /home/comsys/vdb8/bin /home/comsys/vdb8/cfg /home/comsys/vdbm5/bin /home/comsys/vdbm5/lib /home/comsys/vdbm5/cfg' < /dev/null
  scp -q $P/builds/vdb/8/bin/vdb-server $C/scripts/guest/vdb-node.sh comsys@$ip:/home/comsys/vdb8/bin/
  scp -q $C/config/cxl_region.yaml comsys@$ip:/home/comsys/vdb8/cfg/
  scp -q $P/builds/vdb-megalon/5/bin/vdb-server $C/scripts/guest/vdb-node.sh comsys@$ip:/home/comsys/vdbm5/bin/
  scp -q $P/builds/vdb-megalon/5/lib/* comsys@$ip:/home/comsys/vdbm5/lib/
  scp -q $C/config/cxl_region.yaml comsys@$ip:/home/comsys/vdbm5/cfg/
  scp -q $C/systems/megalon/vectordb-2vm.yaml comsys@$ip:/home/comsys/vdbm5/cfg/megalon.yaml
  { echo "== $ip $(date -Is)"; $SSH comsys@$ip 'cd /home/comsys && sha256sum vdb8/bin/* vdb8/cfg/* vdbm5/bin/* vdbm5/lib/* vdbm5/cfg/*; echo ldd_not_found=$(ldd vdbm5/lib/libvdb-megalon.so vdb8/bin/vdb-server | grep -c "not found")' < /dev/null; } | tee -a $LOG
done
{ echo "== Host expected"; (cd $P/builds/vdb/8 && sha256sum bin/vdb-server); (cd $P/builds/vdb-megalon/5 && sha256sum bin/vdb-server lib/*)
  sha256sum $C/scripts/guest/vdb-node.sh $C/config/cxl_region.yaml $C/systems/megalon/vectordb-2vm.yaml; } | tee -a $LOG
