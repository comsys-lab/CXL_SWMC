#!/bin/bash
# LMDB install (reports/LMDB-F1-packet.md): copy our builds and the initial image to the guests (standing grant A:
# our artifacts under /home/comsys/<dir>), print sha256s. Refuses existing install dirs.
#   $L/plain   bin/{lmdb-server,lmdb-stress,lmdb-node.sh}, cfg/cxl_region.yaml                     (all-HWcc, Popcorn)
#   $L/megalon bin/{lmdb-server,lmdb-stress,lmdb-node.sh}, lib/* (libmegalon-objapi.so + Megalon ship libs),
#              cfg/cxl_region.yaml, cfg/megalon.yaml                                               (Megalon)
#   $L/img-$RECORDS (node 0 only): lmdb-image output (pages.bin + meta.txt)
#   cfg/megalon.yaml = workloads/lmdb/config/megalon-2vm.yaml with object_arena_size = ARENA (default 4GB; must be
#   >= (MAX_PAGES - 2) x 4096), written to $LOG.megalon.yaml first.
# usage: install.sh <log file>     env: L (/home/comsys/lmdb), RECORDS (1000000), IMG (Host image dir, required),
#        PLAIN_BUILD (builds/lmdb/3), MEG_BUILD (builds/lmdb-megalon/3), MAX_PAGES (600000), ARENA (4GB)
set -euo pipefail
P=/home/comsys/sungsu/destijl-control C=$P/CXL_SWMC LOG=$1
L=${L:-/home/comsys/lmdb} RECORDS=${RECORDS:-1000000} MAX_PAGES=${MAX_PAGES:-600000} ARENA=${ARENA:-4GB}
: "${IMG:?IMG = Host image dir (lmdb-image --out)}"
BP=${PLAIN_BUILD:-$P/builds/lmdb/3} BM=${MEG_BUILD:-$P/builds/lmdb-megalon/3}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
CFG=$LOG.megalon.yaml
[ -e "$CFG" ] && { echo "refusing: $CFG exists"; exit 2; }
[ "$(sed -n 's/^records=//p' "$IMG/meta.txt")" = "$RECORDS" ] || { echo "image $IMG is not for $RECORDS records"; exit 2; }
want=$(( (MAX_PAGES - 2) * 4096 )); got=$(numfmt --from=iec "${ARENA%B}")
[ "$got" -ge "$want" ] || { echo "ARENA $ARENA < (MAX_PAGES - 2) x 4096 = $want"; exit 2; }
sed -e "s/^object_arena_size:.*/object_arena_size: $ARENA/" "$C/workloads/lmdb/config/megalon-2vm.yaml" > "$CFG"
for i in 0 1; do
  ip=192.168.122.10$i
  $SSH comsys@$ip "test ! -e $L && mkdir -p $L/plain/bin $L/plain/cfg $L/megalon/bin $L/megalon/lib $L/megalon/cfg $L/runs" < /dev/null
  scp -q "$BP/bin/lmdb-server" "$BP/bin/lmdb-stress" "$C/experiments/lmdb/lmdb-node.sh" comsys@$ip:"$L/plain/bin/"
  scp -q "$BM/bin/lmdb-server" "$BM/bin/lmdb-stress" "$C/experiments/lmdb/lmdb-node.sh" comsys@$ip:"$L/megalon/bin/"
  scp -q "$BM"/lib/* comsys@$ip:"$L/megalon/lib/"
  scp -q "$C/config/cxl_region.yaml" comsys@$ip:"$L/plain/cfg/"
  scp -q "$C/config/cxl_region.yaml" comsys@$ip:"$L/megalon/cfg/"
  scp -q "$CFG" comsys@$ip:"$L/megalon/cfg/megalon.yaml"
  if [ $i = 0 ]; then scp -q -r "$IMG" comsys@$ip:"$L/img-$RECORDS"; fi
  { echo "== $ip $(date -Is)"; $SSH comsys@$ip "cd $L && find . -type f -not -path './runs/*' | sort | xargs sha256sum; echo ldd_not_found=\$(ldd plain/bin/lmdb-server megalon/bin/lmdb-server megalon/lib/libmegalon-objapi.so | grep -c 'not found')" < /dev/null; } | tee -a "$LOG"
done
{ echo "== Host expected"; (cd "$BP" && sha256sum bin/lmdb-server bin/lmdb-stress); (cd "$BM" && sha256sum bin/lmdb-server bin/lmdb-stress lib/*)
  sha256sum "$C/experiments/lmdb/lmdb-node.sh" "$C/config/cxl_region.yaml" "$CFG"; (cd "$IMG" && sha256sum pages.bin meta.txt); } | tee -a "$LOG"
