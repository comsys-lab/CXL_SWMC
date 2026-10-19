#!/bin/bash
# recsys pilot install (reports/RECSYS-design.md §8): copy our builds to both guests (standing grant A1), print sha256s.
#   /home/comsys/rs3:  bin/recsys-server (builds/recsys/3), bin/recsys-node.sh, cfg/cxl_region.yaml   (all-HWcc, page MSI)
#   $VM_MEG (default /home/comsys/rsm4): bin/recsys-server + lib/* (MEG_BUILD, default builds/recsys-megalon/4 on
#            Megalon 70), bin/recsys-node.sh, cfg/cxl_region.yaml, cfg/megalon.yaml (systems/megalon/recsys-pilot-2vm.yaml)
# env (main runs, reports/RECSYS-main-packet.md): PLAIN_DIR (default /home/comsys/rs3), MEG_CFG (default
#   systems/megalon/recsys-pilot-2vm.yaml; main: systems/megalon/recsys-2vm.yaml). Defaults = the pilot install.
#   v6 (reports/RECSYS-V1-packet.md): PLAIN_BUILD (default builds/recsys/3), MEGALON_BASE (default builds/megalon/70).
# Each dir is installed only if it does not exist; an existing dir is accepted only if every file equals the Host's
# (sha256), otherwise the script stops (never overwrites). No data goes to the guests.
# usage: install.sh <log file>
set -euo pipefail
P=/home/comsys/sungsu/destijl-control C=$P/CXL_SWMC LOG=$1
MB=${MEG_BUILD:-$P/builds/recsys-megalon/4} VM=${VM_MEG:-/home/comsys/rsm4}
PB=${PLAIN_BUILD:-$P/builds/recsys/3} MBASE=${MEGALON_BASE:-$P/builds/megalon/70}
PD=${PLAIN_DIR:-/home/comsys/rs3} MCFG=${MEG_CFG:-$C/systems/megalon/recsys-pilot-2vm.yaml}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
# "<guest path> <Host file>" per install dir
PLAIN="$PD/bin/recsys-server $PB/bin/recsys-server
$PD/bin/recsys-node.sh $C/scripts/guest/recsys-node.sh
$PD/cfg/cxl_region.yaml ${REGION:-$C/config/cxl_region.yaml}"
MEG="$VM/bin/recsys-server $MB/bin/recsys-server
$VM/bin/recsys-node.sh $C/scripts/guest/recsys-node.sh
$VM/cfg/cxl_region.yaml ${REGION:-$C/config/cxl_region.yaml}
$VM/cfg/megalon.yaml $MCFG"
for f in "$MB"/lib/*; do MEG="$MEG
$VM/lib/$(basename "$f") $f"; done
grep -q "^megalon_build=$MBASE$" "$MB/manifest.txt" || { echo "STOP: $MB is not on $MBASE"; exit 1; }
install_dir() {  # ip, dir, list
  local ip=$1 dir=$2 list=$3 g h
  if $SSH comsys@$ip "test -e $dir" < /dev/null; then
    while read -r g h; do
      [ "$($SSH comsys@$ip "sha256sum $g 2>/dev/null | cut -d' ' -f1" < /dev/null)" = "$(sha256sum "$h" | cut -d' ' -f1)" ] \
        || { echo "STOP: $ip $dir exists and $g differs from $h"; exit 1; }
    done <<< "$list"
    echo "$ip $dir exists, identical to the Host files" | tee -a $LOG
    return 0
  fi
  $SSH comsys@$ip "mkdir -p $dir/bin $dir/cfg $dir/lib" < /dev/null
  while read -r g h; do scp -q "$h" comsys@$ip:"$g"; done <<< "$list"
  echo "$ip $dir installed" | tee -a $LOG
}
for ip in 192.168.122.100 192.168.122.101; do
  install_dir $ip $PD "$PLAIN"
  install_dir $ip $VM "$MEG"
  { echo "== $ip $(date -Is)"; $SSH comsys@$ip "sha256sum $PD/bin/* $PD/cfg/* $VM/bin/* $VM/lib/* $VM/cfg/*; echo ldd_not_found=\$(ldd $VM/lib/libmegalon-objapi.so $VM/bin/recsys-server $PD/bin/recsys-server | grep -c 'not found')" < /dev/null; } | tee -a $LOG
done
{ echo "== Host expected"; echo "$PLAIN"$'\n'"$MEG" | while read -r g h; do echo "$(sha256sum "$h" | cut -d' ' -f1)  $g"; done; } | tee -a $LOG
