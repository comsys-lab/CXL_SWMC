#!/bin/bash
# H1 main block, HNSW VectorDB 28M (reports/M4-vdb-packet.md v2.0; MOT1 v5 §3.3; user decisions 2026-10-16):
# all three systems on page MSI build 8 (all-HWcc and Megalon with cxl_shm unloaded; page MSI with cxl_shm loaded per
# run, init_state=shared + preload, recv_mode poll), update 5% (delete+insert pair), SLO search p99 <= 100 ms.
#   step 1: 3 consecutive rounds; the orders form a 3x3 Latin square (each system once in each position): base =
#           [hw, pop, mg] shuffled with seed "H1-vdb-latin", round r = base rotated left by r-1 (written to order.txt
#           before the first run); request seed SEED_BASE + r, the same for the three systems of a round.
#           Runs <sys>-u5-slo-r<r> (m4-run.sh KIND=slo: full MOT1 procedure).
#   step 2: fixed load 60 s at L = 0.5 x all-HWcc round-1 confirm mean (never from a run with a note), once per system,
#           TRACE=0, order shuffled with seed "H1-vdb-fix", request seed SEED_BASE + 10. Runs <sys>-u5-fix.
# Every run starts from the initial image (node 0 loads /home/comsys/vdb/init/seg32c32m-a27m; page MSI: preload).
# usage: h1-block.sh <evidence dir (exists, holds only sequence* files)>
# env (required, set by the packet's sequence.sh): K8 GT8 C8 (build-8 release, guest tools, deploy bundle),
#   PLAIN_BUILD VPLAIN (vdb build + guest dir for all-HWcc and page MSI), MEG_BUILD VMEG MEG_CFG (vdb-megalon build on
#   Megalon 70 + guest dir + Megalon config), LOADGEN_BUILD (loadgen dir).
# dax0.0: owned by comsys for all-HWcc/Megalon runs, back to root:root 600 before each page MSI run (its
# p-popcorn-shm.sh precheck needs it; teardown restores it). Same Host gate / lock / stop rules as M4 (m4-lib.sh).
set -uo pipefail
E=$1 R=1
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
SEED_BASE=20261014 OWNER="H1-vdb" ROUNDS=3
: "${K8:?}" "${GT8:?}" "${C8:?}" "${PLAIN_BUILD:?}" "${VPLAIN:?}" "${MEG_BUILD:?}" "${VMEG:?}" "${MEG_CFG:?}" "${LOADGEN_BUILD:?}"
for b in "$PLAIN_BUILD" "$MEG_BUILD" "$LOADGEN_BUILD"; do
  grep -q "^source_commit=.* dirty=0$" $b/manifest.txt || { echo "SEQUENCE STOP: $b is not a clean build"; exit 2; }
done
grep -q "^megalon_build=$P/builds/megalon/70$" $MEG_BUILD/manifest.txt || { echo "SEQUENCE STOP: $MEG_BUILD is not on builds/megalon/70"; exit 2; }
GUEST_INIT=/home/comsys/vdb/init/seg32c32m-a27m HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1
VP=${VPLAIN#/home/comsys/} VM=${VMEG#/home/comsys/}
INSTALL="$VP/bin/vdb-server $PLAIN_BUILD/bin/vdb-server
$VP/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VP/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml
$VM/bin/vdb-server $MEG_BUILD/bin/vdb-server
$VM/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VM/lib/libvdb-megalon.so $MEG_BUILD/lib/libvdb-megalon.so
$VM/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
$VM/cfg/megalon.yaml $MEG_CFG
$VM/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"
. $X/m4-lib.sh
COMMON=(DATASET=28m U=5 PLAIN_BUILD=$PLAIN_BUILD VPLAIN=$VPLAIN MEG_BUILD=$MEG_BUILD VMEG=$VMEG QCOH_EXPECT=swmc
        LOADGEN_BIN=$LOADGEN_BUILD/loadgen)
PE=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=poll)
dax_root() {  # before a page MSI run: back to root:root 600 (no server of ours runs between runs); fresh stat check
  [ $CHOWNED = 1 ] || return 0
  block_stop_servers
  block_dax_root || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600"; exit 1; }
  CHOWNED=0
}
dax_comsys() { [ $CHOWNED = 1 ] || chown_dax; }
one() {  # <sys> <name> <kind-specific env...>
  local s=$1 name=$2; shift 2
  case $s in
    hw)  dax_comsys; run $name SYS=all-HWcc "${COMMON[@]}" "$@";;
    mg)  dax_comsys; run $name SYS=Megalon "${COMMON[@]}" "$@";;
    pop) dax_root;   run $name SYS=Popcorn "${COMMON[@]}" "${PE[@]}" "$@";;
  esac
}
block_start
precheck "$K8"
read -r -a BASE <<< "$(SHUFFLE_SEED=H1-vdb-latin shuffle hw pop mg)"
FIXORD=$(SHUFFLE_SEED=H1-vdb-fix shuffle hw pop mg)
[ ${#BASE[@]} = 3 ] && [ $(echo $FIXORD | wc -w) = 3 ] || { echo "SEQUENCE STOP: run order lists"; exit 1; }
ORD=()
for r in 1 2 3; do ORD[$r]="${BASE[$(( (r - 1) % 3 ))]} ${BASE[$(( r % 3 ))]} ${BASE[$(( (r + 1) % 3 ))]}"; done
{ echo "# H1 block order (Latin square from shuffle seed H1-vdb-latin, fixed H1-vdb-fix; request seed $SEED_BASE + r, fixed $SEED_BASE + 10)"
  for r in 1 2 3; do echo "round $r seed $((SEED_BASE + r)): ${ORD[$r]}"; done
  echo "fixed seed $((SEED_BASE + 10)): $FIXORD"; } | tee "$E/order.txt"
for r in 1 2 3; do
  R=$r
  [ $(echo ${ORD[$r]} | wc -w) = 3 ] || { echo "SEQUENCE STOP: empty order for round $r"; exit 1; }
  for s in ${ORD[$r]}; do one $s $s-u5-slo-r$r KIND=slo REP=r$r; done
done
x=$(confirm_x $E/hw-u5-slo-r1/loadgen/summary.json) || { echo "SEQUENCE STOP: no all-HWcc round-1 result for L ($x)"; exit 1; }
rate=$(rate "$x" 5)
echo "L = 0.5 x $x search/s (hw-u5-slo-r1): total rate $rate (search + update streams)" | tee "$E/fixed-load-L.txt"
for s in $FIXORD; do
  one $s $s-u5-fix KIND=fixed RATE=$rate TRACE=0 REP=fix SEED=$((SEED_BASE + 10))
done
echo "$(date -Is) SEQUENCE DONE $OWNER"
