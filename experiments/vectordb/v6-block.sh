#!/bin/bash
# VDB-V1 block (reports/VDB-V1-packet.md v1): VM validation of the vector DB v6 builds (per-operation time split,
# MOT1 v6 Fig 2/3), HNSW VectorDB 28M, all three systems on Popcorn build 10 (all-HWcc and Megalon with cxl_shm
# unloaded; Popcorn with cxl_shm loaded per run, init_state=shared + preload, recv_mode poll). Validation only, not
# comparison data: checks that the blocks close and the coherence sources are right, and measures the Megalon timer
# overhead.
#   1. per system, order seeded "VDB-V1" over {hw, pop, mg}: one run, mix 95/5 (U=5), KIND=pfix (warm-up 10 s, per
#      rate 5 s + 30 s), two rates in one server run: RATE_LOW (search 10/s) and RATE_L (0.5 x the v5 all-HWcc max,
#      recovery/M4-vdb-h1-v2.1/main/hw-u5-slo-r1: 158.479 search/s). Runs <sys>-u5-v6.
#      OPCOH_EXPECT / OPCOH_CHECK_MODE: hw none / hwcc, pop swmc_acct / popcorn, mg cohsnap / megalon-vm.
#   2. Megalon timers off: mg-u5-t0 = step 1's Megalon run with MEGALON_COH_TIMERS=0 (same rates and seed), check mode
#      megalon-t0. Overhead = step 1 Megalon (timers on) vs t0 at the same offered rates (one pair; noise stated).
#   3. Sharing trace: mg-u90-trace, U=90, KIND=pfix, RATE_TRACE (search 2/s), TRACE=1, --trace-max-mb 512 (the dump at
#      stop must fit vdb-node.sh's 15 s TERM grace: <= 512 MiB per node); run.sh
#      classifies the trace on Host node 1 under a 16 GB address-space cap (sharing.csv); opsplit / opcoh_check
#      megalon-vm as in step 1. trace.dropped must be 0 on both nodes.
# usage: v6-block.sh <evidence dir (exists, holds only sequence* files)>
# env (required, set by the packet's sequence.sh): K10 GT10 C10 (build-10 release, guest tools, deploy bundle),
#   PLAIN_BUILD VPLAIN (vdb build + guest dir for all-HWcc and Popcorn), MEG_BUILD VMEG MEG_CFG (vdb-megalon build +
#   guest dir + Megalon config), LOADGEN_BUILD (loadgen dir).
# dax0.0: owned by comsys for all-HWcc/Megalon runs, back to root:root 600 before each Popcorn run (its
# p-popcorn-shm.sh precheck needs it; teardown restores it). Same Host gate (measure-env check) / lock / stop rules as
# M4 (m4-lib.sh, host-gate.sh).
set -uo pipefail
E=$1 R=1
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
SEED_BASE=20261014 OWNER="VDB-V1"
: "${K10:?}" "${GT10:?}" "${C10:?}" "${PLAIN_BUILD:?}" "${VPLAIN:?}" "${MEG_BUILD:?}" "${VMEG:?}" "${MEG_CFG:?}" "${LOADGEN_BUILD:?}"
for b in "$PLAIN_BUILD" "$MEG_BUILD" "$LOADGEN_BUILD"; do
  grep -q "^source_commit=.* dirty=0$" $b/manifest.txt || { echo "SEQUENCE STOP: $b is not a clean build"; exit 2; }
done
grep -q "^megalon_build=$P/builds/megalon/75$" $MEG_BUILD/manifest.txt || { echo "SEQUENCE STOP: $MEG_BUILD is not on builds/megalon/75"; exit 2; }
grep -q "^shim_kind=shared$" $MEG_BUILD/manifest.txt || { echo "SEQUENCE STOP: $MEG_BUILD has no shared (v3) shim"; exit 2; }
GUEST_INIT=/home/comsys/vdb/init/seg32c32m-a27m HOST_IMAGE=$P/workspaces/vdb-data/seg32-c32m-a27m-m16-efc128-b1
VP=${VPLAIN#/home/comsys/} VM=${VMEG#/home/comsys/}
INSTALL="$VP/bin/vdb-server $PLAIN_BUILD/bin/vdb-server
$VP/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VP/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml
$VM/bin/vdb-server $MEG_BUILD/bin/vdb-server
$VM/bin/vdb-node.sh $P/CXL_SWMC/scripts/guest/vdb-node.sh
$VM/lib/libmegalon-objapi.so $MEG_BUILD/lib/libmegalon-objapi.so
$VM/lib/libmegalon.so $MEG_BUILD/lib/libmegalon.so
$VM/lib/libtbb.so.12 $MEG_BUILD/lib/libtbb.so.12
$VM/lib/libtbbmalloc.so.2 $MEG_BUILD/lib/libtbbmalloc.so.2
$VM/lib/libhwloc.so.15 $MEG_BUILD/lib/libhwloc.so.15
$VM/lib/libatomic.so.1 $MEG_BUILD/lib/libatomic.so.1
$VM/cfg/megalon.yaml $MEG_CFG
$VM/cfg/cxl_region.yaml $P/CXL_SWMC/config/cxl_region.yaml"
. $X/m4-lib.sh
# rates (total req/s of the update + search streams; mix 95/5 unless stated): search 10/s; L = 0.5 x 158.479 search/s
RATE_LOW=10.526 RATE_L=$(rate 158.479 5) RATE_TRACE=20
COMMON=(DATASET=28m PLAIN_BUILD=$PLAIN_BUILD VPLAIN=$VPLAIN MEG_BUILD=$MEG_BUILD VMEG=$VMEG
        LOADGEN_BIN=$LOADGEN_BUILD/loadgen KIND=pfix)
PE=(C8=$C10 K8=$K10 GT8=$GT10 RECV_MODE=poll)  # m4-run.sh's Popcorn variables, given the build-10 bundle
dax_root() {  # before a Popcorn run: back to root:root 600 (no server of ours runs between runs); fresh stat check
  [ $CHOWNED = 1 ] || return 0
  block_stop_servers
  block_dax_root || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600"; exit 1; }
  CHOWNED=0
}
dax_comsys() { [ $CHOWNED = 1 ] || chown_dax; }
one() {  # <sys> <name> <run-specific env...>
  local s=$1 name=$2; shift 2
  case $s in
    hw)  dax_comsys; run $name SYS=all-HWcc OPCOH_EXPECT=none OPCOH_CHECK_MODE=hwcc "${COMMON[@]}" "$@";;
    mg)  dax_comsys; run $name SYS=Megalon OPCOH_EXPECT=cohsnap "${COMMON[@]}" "$@";;
    pop) dax_root;   run $name SYS=Popcorn OPCOH_EXPECT=swmc_acct OPCOH_CHECK_MODE=popcorn "${COMMON[@]}" "${PE[@]}" "$@";;
  esac
}
block_start
C8=$C10 K8=$K10 GT8=$GT10  # block_shm_cleanup (m4-lib.sh) reads C8/K8/GT8
precheck "$K10"
ORD=$(SHUFFLE_SEED=VDB-V1 shuffle hw pop mg)
[ $(echo $ORD | wc -w) = 3 ] || { echo "SEQUENCE STOP: run order list"; exit 1; }
{ echo "# VDB-V1 order (shuffle seed VDB-V1; request seed $((SEED_BASE + R)))"; echo "step 1: $ORD"
  echo "step 2: mg-u5-t0; step 3: mg-u90-trace"
  echo "rates: low $RATE_LOW, L $RATE_L (0.5 x 158.479 search/s, U 5), trace $RATE_TRACE (U 90)"; } | tee "$E/order.txt"
for s in $ORD; do
  case $s in mg) m=OPCOH_CHECK_MODE=megalon-vm;; *) m=;; esac
  one $s $s-u5-v6 U=5 RATE=$RATE_LOW,$RATE_L REP=v6 $m
done
one mg mg-u5-t0 U=5 RATE=$RATE_LOW,$RATE_L REP=t0 OPCOH_CHECK_MODE=megalon-t0 XENV=ENV:MEGALON_COH_TIMERS=0
one mg mg-u90-trace U=90 RATE=$RATE_TRACE REP=trace TRACE=1 OPCOH_CHECK_MODE=megalon-vm "XARGS=--trace-max-mb 512"
grep -q "^-> .*sharing.csv:" $E/mg-u90-trace/sharing.log || { echo "SEQUENCE STOP: trace not classified (see $E/mg-u90-trace/sharing.log)"; exit 1; }
[ "$(grep -h '^trace.dropped=' $E/mg-u90-trace/node*.log | sort -u)" = "trace.dropped=0" ] \
  || { echo "SEQUENCE STOP: trace records dropped (see node logs)"; exit 1; }
python3 $X/v6_overhead.py $E/mg-u5-v6 $E/mg-u5-t0 > $E/timer-overhead.txt 2>&1 || { echo "SEQUENCE STOP: v6_overhead.py"; exit 1; }
echo "$(date -Is) SEQUENCE DONE $OWNER"
