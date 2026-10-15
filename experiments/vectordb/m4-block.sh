#!/bin/bash
# One M4 block (reports/M4-vdb-packet.md §3; MOT1 v5 §3.3, §4.3): a fixed list of m4-run.sh runs on one kernel, in a
# recorded order.
# usage: m4-block.sh <block> <round> <evidence dir (exists, empty)>
#   block p1:  Popcorn build 8, update 5%: functional (poll), SLO search per recv_mode (order shuffled), then a
#              60 s fixed-load window per recv_mode at L = 0.5 x the best of the three SLO results.
#   block pop: Popcorn build 8 (RECV_MODE): functional (round 1), SLO search for U in {0,5,20,50} (shuffled);
#              round 2 adds the fixed-load windows U in {5,20,50} at L = 0.5 x all-HWcc round 1 (LREF).
#   block van: vanilla kernel: functional all-HWcc and Megalon (round 1), SLO search for {all-HWcc, Megalon} x U
#              (shuffled); round 1 adds the fixed-load windows (all-HWcc and Megalon, U in {5,20,50}; Megalon U 20/50
#              with TRACE=1, U 5 TRACE=0; L from this block's all-HWcc SLO results).
# env: Popcorn blocks C8 K8 GT8 (and RECV_MODE for pop); pop round 2: LREF (van round-1 evidence dir);
#      KV (vanilla release, default 6.14.0-vanilla-1). Every run: m4-run.sh (Host gate, checks, E1).
# Request seed (loadgen --seed and plugin seed) = 20261014 + round: same request sequence for every system within a
# round, a different one per round. Holds the measurement lock for the whole block. Stops at the first M4RUN STOP;
# vanilla blocks then roll back /dev/dax0.0 (Popcorn runs tear down per run). L never comes from a run whose SLO
# search ended with a note (confirm_x refuses it).
set -uo pipefail
B=$1 R=$2 E=$3
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
KV=${KV:-6.14.0-vanilla-1} SEED_BASE=20261014 OWNER="M4-$B-r$R"
GUEST_INIT=/home/comsys/vdb/init/seg32c32m-a27m HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1
# Megalon variant (default: vdb-megalon/6 on Megalon build 70, 28M config, guest /home/comsys/vdbm6-28m)
export MEG_BUILD=${MEG_BUILD:-$P/builds/vdb-megalon/6} VMEG=${VMEG:-/home/comsys/vdbm6-28m}
MEG_CFG=${MEG_CFG:-$P/CXL_SWMC/systems/megalon/vectordb-2vm.yaml}
grep -q "^source_commit=.* dirty=0$" $MEG_BUILD/manifest.txt || { echo "SEQUENCE STOP: $MEG_BUILD not clean"; exit 2; }
VM=${VMEG#/home/comsys/}
INSTALL="vdb8/bin/vdb-server $P/builds/vdb/8/bin/vdb-server
vdb8/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
vdb8/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml
$VM/bin/vdb-server $MEG_BUILD/bin/vdb-server
$VM/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VM/lib/libvdb-megalon.so $MEG_BUILD/lib/libvdb-megalon.so
$VM/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
$VM/cfg/megalon.yaml $MEG_CFG
$VM/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"
. $X/m4-lib.sh
block_start
case "$B" in
  p1)
    : "${C8:?}" "${K8:?}" "${GT8:?}"
    precheck "$K8"
    run pop-u5-func-poll SYS=Popcorn U=5 KIND=functional RECV_MODE=poll GATE=0 C8=$C8 K8=$K8 GT8=$GT8
    for m in $(shuffle poll idle sleep); do run pop-u5-slo-$m SYS=Popcorn U=5 KIND=slo RECV_MODE=$m C8=$C8 K8=$K8 GT8=$GT8; done
    best=$(for m in poll idle sleep; do confirm_x $E/pop-u5-slo-$m/loadgen/summary.json; done | sort -g | tail -1)
    [ -n "$best" ] || { echo "SEQUENCE STOP: no SLO result without a note"; exit 1; }
    r=$(rate "$best" 5) || { echo "SEQUENCE STOP: no SLO result"; exit 1; }
    echo "fixed-load L: 0.5 x best $best search/s -> total rate $r (runs with a note excluded)" | tee "$E/fixed-load-L.txt"
    for m in $(shuffle poll idle sleep); do run pop-u5-fix-$m SYS=Popcorn U=5 KIND=fixed RATE=$r RECV_MODE=$m C8=$C8 K8=$K8 GT8=$GT8; done;;
  pop)
    : "${C8:?}" "${K8:?}" "${GT8:?}" "${RECV_MODE:?}"
    precheck "$K8"
    PE=(C8=$C8 K8=$K8 GT8=$GT8 RECV_MODE=$RECV_MODE REP=r$R)
    [ "$R" = 1 ] && run pop-u5-func SYS=Popcorn U=5 KIND=functional GATE=0 "${PE[@]}"
    for u in $(shuffle 0 5 20 50); do run pop-u$u-slo-r$R SYS=Popcorn U=$u KIND=slo "${PE[@]}"; done
    if [ "$R" = 2 ]; then
      : "${LREF:?}"
      for u in $(shuffle 5 20 50); do
        x=$(confirm_x $LREF/hw-u$u-slo-r1/loadgen/summary.json) || { echo "SEQUENCE STOP: L for u$u"; exit 1; }
        r=$(rate "$x" $u)
        echo "u$u L from $LREF/hw-u$u-slo-r1 ($x search/s): total rate $r" >> "$E/fixed-load-L.txt"
        run pop-u$u-fix SYS=Popcorn U=$u KIND=fixed RATE=$r "${PE[@]}"
      done
    fi;;
  van)
    precheck "$KV"
    chown_dax
    if [ "$R" = 1 ]; then
      run hw-u5-func SYS=all-HWcc U=5 KIND=functional GATE=0
      run mg-u5-func SYS=Megalon U=5 KIND=functional GATE=0
    fi
    for su in $(shuffle hw:0 hw:5 hw:20 hw:50 mg:0 mg:5 mg:20 mg:50); do
      s=${su%:*} u=${su#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
      run $s-u$u-slo-r$R SYS=$S U=$u KIND=slo REP=r$R
    done
    if [ "$R" = 1 ]; then
      for su in $(shuffle hw:5 hw:20 hw:50 mg:5 mg:20 mg:50); do
        s=${su%:*} u=${su#*:}; [ $s = hw ] && S=all-HWcc || S=Megalon
        t=0; [ $s = mg ] && [ $u != 5 ] && t=1
        x=$(confirm_x $E/hw-u$u-slo-r1/loadgen/summary.json) || { echo "SEQUENCE STOP: L for u$u"; exit 1; }
        r=$(rate "$x" $u)
        echo "$s u$u L from hw-u$u-slo-r1 ($x search/s): total rate $r trace=$t" >> "$E/fixed-load-L.txt"
        run $s-u$u-fix SYS=$S U=$u KIND=fixed RATE=$r TRACE=$t
      done
    fi;;
  *) echo "SEQUENCE STOP: bad block"; exit 2;;
esac
echo "$(date -Is) SEQUENCE DONE $OWNER"
