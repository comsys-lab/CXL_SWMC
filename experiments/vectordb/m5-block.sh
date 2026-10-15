#!/bin/bash
# One M5 pilot block (reports/M5-pilot-packet.md; MOT1 v5 §3.3): HNSW 1M (pubmed-a1m-b1m-q10k, image seg32c32m,
# update-mode writes writes-a1m-b1m-u1m.bin), update 5%, pilot mode (m4-run.sh KIND=pslo / pfix).
# usage: m5-block.sh <block> <evidence dir (exists, empty)>
#   eqA  kernel KV (vanilla):                    all-HWcc pslo x 2 + Megalon pslo x 1 (order seeded)
#   eqB  kernel K8 (page MSI build 8), no cxl_shm: the same three runs
#   h1   kernel K8: all-HWcc, Megalon (cxl_shm unloaded) and page MSI (cxl_shm loaded per run, recv_mode poll,
#        init_state=shared + preload) pslo, then pfix 30 s for all three at L = 0.5 x this block's all-HWcc result
# env: KV (default 6.14.0-vanilla-1); K8, GT8, C8 (eqB/h1; h1 page MSI); MEG_BUILD (vdb-megalon build on Megalon 70,
#      required; its manifest must name builds/megalon/70 and dirty=0), VMEG (default /home/comsys/vdbm6).
# dax0.0 is owned by comsys for the all-HWcc/Megalon runs and back to root:root 600 before each page MSI run (its
# p-popcorn-shm.sh precheck needs it; its teardown restores it). Same Host gate / lock / stop rules as M4.
set -uo pipefail
B=$1 E=$2 R=1
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
KV=${KV:-6.14.0-vanilla-1} SEED_BASE=20261014 OWNER="M5-$B"
: "${MEG_BUILD:?}"
VMEG=${VMEG:-/home/comsys/vdbm6}
grep -q "^megalon_build=$P/builds/megalon/70$" $MEG_BUILD/manifest.txt && grep -q "^source_commit=.* dirty=0$" $MEG_BUILD/manifest.txt \
  || { echo "SEQUENCE STOP: $MEG_BUILD is not a clean vdb-megalon build on builds/megalon/70"; exit 2; }
GUEST_INIT=/home/comsys/vdb/init/seg32c32m HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a1m-m16-efc128-b3
INSTALL="vdb8/bin/vdb-server $P/builds/vdb/8/bin/vdb-server
vdb8/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
vdb8/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml
${VMEG#/home/comsys/}/bin/vdb-server $MEG_BUILD/bin/vdb-server
${VMEG#/home/comsys/}/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
${VMEG#/home/comsys/}/lib/libvdb-megalon.so $MEG_BUILD/lib/libvdb-megalon.so
${VMEG#/home/comsys/}/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
${VMEG#/home/comsys/}/cfg/megalon.yaml $P/CXL_SWMC/systems/megalon/vectordb-1m-2vm.yaml
${VMEG#/home/comsys/}/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"
. $X/m4-lib.sh
COMMON=(DATASET=1m U=5 MEG_BUILD=$MEG_BUILD VMEG=$VMEG)
dax_root() {  # before a page MSI run: back to root:root 600 (no server of ours runs between runs)
  [ $CHOWNED = 1 ] || return 0
  block_rollback; CHOWNED=0
  [ "$(grep -o 'stat=.*' "$E/rollback.out" | tail -2 | sort -u)" = "stat=root:root 600" ] \
    || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600"; exit 1; }
}
dax_comsys() { [ $CHOWNED = 1 ] || chown_dax; }
block_start
case "$B" in
  eqA|eqB)
    if [ $B = eqA ]; then precheck "$KV"; t=a; else : "${K8:?}"; precheck "$K8"; t=b; fi
    dax_comsys
    for x in $(shuffle hw:1 hw:2 mg:1); do
      s=${x%:*} n=${x#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
      run $s-u5-pslo-$t$n SYS=$S KIND=pslo "${COMMON[@]}"
    done;;
  h1)
    : "${K8:?}" "${GT8:?}" "${C8:?}"
    precheck "$K8"
    PE=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=poll)
    for s in $(shuffle hw pop mg); do
      case $s in
        hw) dax_comsys; run hw-u5-pslo-h SYS=all-HWcc KIND=pslo "${COMMON[@]}";;
        mg) dax_comsys; run mg-u5-pslo-h SYS=Megalon KIND=pslo "${COMMON[@]}";;
        pop) dax_root; run pop-u5-pslo-h SYS=Popcorn KIND=pslo "${COMMON[@]}" "${PE[@]}";;
      esac
    done
    x=$(confirm_x $E/hw-u5-pslo-h/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc result for L"; exit 1; }
    r=$(rate "$x" 5)
    echo "L = 0.5 x $x search/s (hw-u5-pslo-h): total rate $r" | tee "$E/fixed-load-L.txt"
    for s in $(shuffle hw pop mg); do
      case $s in
        hw) dax_comsys; run hw-u5-pfix-h SYS=all-HWcc KIND=pfix RATE=$r "${COMMON[@]}";;
        mg) dax_comsys; run mg-u5-pfix-h SYS=Megalon KIND=pfix RATE=$r "${COMMON[@]}";;
        pop) dax_root; run pop-u5-pfix-h SYS=Popcorn KIND=pfix RATE=$r "${COMMON[@]}" "${PE[@]}";;
      esac
    done;;
  *) echo "SEQUENCE STOP: bad block"; exit 2;;
esac
echo "$(date -Is) SEQUENCE DONE $OWNER"
