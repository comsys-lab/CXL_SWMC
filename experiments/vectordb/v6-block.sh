#!/bin/bash
# VDB-V1 block (reports/VDB-V1-packet.md v1.3): VM validation of the vector DB v6 builds (per-operation time split,
# MOT1 v6 Fig 2/3), HNSW VectorDB 28M, all three systems on one Popcorn build (v1.3: build 12; all-HWcc and Megalon with cxl_shm
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
# H1-HOOK v1 (experiments/h1/README.md, reports/H1-main-packet.md; set H1MODE): the H1 main phases instead of the
#   VDB-V1 runs, with this block's precheck, Host gate per run, pretouch gate (start, every run, end), checks and
#   rollback. Env from experiments/h1/hook.sh: H1MODE slo|fix, H1_N (round), H1_SEED (loadgen seed), H1_PARENT_LOCK
#   (=H1-main: the lock must be held by it; this block never locks or unlocks), H1_MIXES "<mix>=U=<5|50|90> ..." (slo)
#   or H1_LEVELS (levels.tsv, fix). Mix tags u5/u50/u90 = search/update 95/5, 50/50, 10/90 (MOT1 v6), 28M dataset.
#   slo: per system in hw, pop, mg (base order = shuffle seed "H1-vdb-r1", rotated left by N-1: Latin square over
#        rounds) and per mix (shuffle seed "H1-vdb-r<N>", same for every system): one m4-run.sh KIND=slo run
#        <sys>-<mix>-slo-r<N> (ramp/bisect, confirm 3 x 30 s, fill 0.7/0.8/0.9, overload 1.05/1.1/1.2 past the first
#        failure; SLO search p99 <= 100 ms). A loadgen "confirm failed at three rates" NOTE is recorded and the block
#        continues.
#   fix: per levels.tsv row (mix) and per system in hw, pop, mg, mgoff (shuffle seed "H1-vdb-fix-r<N>" per mix):
#        one lifetime m4-run.sh KIND=fixed RATE=<L2_rate>,<L1_rate> (windows 10 s + 60 s each, L2 then L1, no SLO
#        abort) <sys>-<mix>-fix-r<N>; mgoff = Megalon with MEGALON_COH_TIMERS=0 on both nodes (Fig 2 C_diff).
#   Per run: OPCOH_EXPECT + opcoh_check (hw hwcc, pop popcorn, mg megalon-vm, mgoff megalon-t0), clean stop,
#   bad_records 0, E1 check, loadgen finish (all inside m4-run.sh) -> <run>/h1-runcheck.txt (last line RUNCHECK PASS);
#   <dir>/h1-runs.tsv one line per run; order.txt before the first run.
# usage: v6-block.sh <evidence dir (exists, holds only sequence* files)>
# env (required, set by the packet's sequence.sh): KPOP GTPOP CPOP (Popcorn release, guest tools, deploy bundle),
#   PLAIN_BUILD VPLAIN (vdb build + guest dir for all-HWcc and Popcorn), MEG_BUILD VMEG MEG_CFG (vdb-megalon build +
#   guest dir + Megalon config), MEG_LIB (the Megalon build MEG_BUILD must be built on, e.g. builds/megalon/77),
#   LOADGEN_BUILD (loadgen dir), PRETOUCH_DIR (ENV-pretouch evidence dir: pretouch-gate.sh must pass at the block start
#   and before every run: dax0.0 of both VMs pre-touched after their last QEMU start; standing rule 2026-10-17).
#   Optional: EXPECT_DAX_UUID (guest namespace0.0 uuid, checked by the precheck), MEASURE_ENV_DIR (host-gate.sh),
#   MEGALON_LEAN=1 (opcoh_check megalon-vm: Megalon >= 76 lean-sampling checks).
# dax0.0: owned by comsys for all-HWcc/Megalon runs, back to root:root 600 before each Popcorn run (its
# p-popcorn-shm.sh precheck needs it; teardown restores it). Same Host gate (measure-env check) / lock / stop rules as
# M4 (m4-lib.sh, host-gate.sh).
set -uo pipefail
E=$1 R=1
P=/home/comsys/sungsu/destijl-control X=$P/CXL_SWMC/experiments/vectordb
SEED_BASE=20261014 OWNER="VDB-V1"
: "${KPOP:?}" "${GTPOP:?}" "${CPOP:?}" "${PLAIN_BUILD:?}" "${VPLAIN:?}" "${MEG_BUILD:?}" "${VMEG:?}" "${MEG_CFG:?}" "${LOADGEN_BUILD:?}"
: "${MEG_LIB:?}" "${PRETOUCH_DIR:?}"
if [ -n "${H1MODE:-}" ]; then
  [ "${H1_PARENT_LOCK:-}" = H1-main ] || { echo "SEQUENCE STOP: H1MODE needs H1_PARENT_LOCK=H1-main"; exit 2; }
  [[ "${H1_N:-}" =~ ^[1-9]$ ]] && [[ "${H1_SEED:-}" =~ ^[0-9]+$ ]] || { echo "SEQUENCE STOP: H1_N / H1_SEED"; exit 2; }
  case $H1MODE in slo) : "${H1_MIXES:?}";; fix) [ -f "${H1_LEVELS:-}" ] || { echo "SEQUENCE STOP: no H1_LEVELS"; exit 2; };;
    *) echo "SEQUENCE STOP: bad H1MODE"; exit 2;; esac
  PARENT_LOCK=$H1_PARENT_LOCK OWNER="H1-vdb-$H1MODE-r$H1_N"
fi
for b in "$PLAIN_BUILD" "$MEG_BUILD" "$LOADGEN_BUILD"; do
  grep -q "^source_commit=.* dirty=0$" $b/manifest.txt || { echo "SEQUENCE STOP: $b is not a clean build"; exit 2; }
done
grep -qx "megalon_build=$MEG_LIB" $MEG_BUILD/manifest.txt || { echo "SEQUENCE STOP: $MEG_BUILD is not on $MEG_LIB"; exit 2; }
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
PE=(C8=$CPOP K8=$KPOP GT8=$GTPOP RECV_MODE=poll)  # m4-run.sh's Popcorn variables (named C8/K8/GT8), given the bundle
dax_root() {  # before a Popcorn run: back to root:root 600 (no server of ours runs between runs); fresh stat check
  [ $CHOWNED = 1 ] || return 0
  block_stop_servers
  block_dax_root || { echo "SEQUENCE STOP: dax0.0 not back to root:root 600"; exit 1; }
  CHOWNED=0
}
dax_comsys() { [ $CHOWNED = 1 ] || chown_dax; }
pretouch_gate() {  # standing rule: both VMs pre-touched after their last QEMU start (Host-only check)
  bash $X/pretouch-gate.sh "$PRETOUCH_DIR" "$E/pretouch-gate.txt" > /dev/null \
    || { echo "SEQUENCE STOP: pretouch gate ($1; see $E/pretouch-gate.txt)"; exit 1; }
}
one() {  # <sys> <name> <run-specific env...>
  local s=$1 name=$2; shift 2
  pretouch_gate "$name"
  case $s in
    hw)  dax_comsys; run $name SYS=all-HWcc OPCOH_EXPECT=none OPCOH_CHECK_MODE=hwcc "${COMMON[@]}" "$@";;
    mg)  dax_comsys; run $name SYS=Megalon OPCOH_EXPECT=cohsnap "${COMMON[@]}" "$@";;
    pop) dax_root;   run $name SYS=Popcorn OPCOH_EXPECT=swmc_acct OPCOH_CHECK_MODE=popcorn "${COMMON[@]}" "${PE[@]}" "$@";;
    mgoff) dax_comsys; run $name SYS=Megalon OPCOH_EXPECT=cohsnap OPCOH_CHECK_MODE=megalon-t0 "${COMMON[@]}" \
             XENV=ENV:MEGALON_COH_TIMERS=0 "$@";;
  esac
}
# H1 hook helpers
h1_runcheck() {  # <name> <sys> <mix> <phase>: per-run check record (m4-run.sh stops the block on any failed check)
  local r=$E/$1 st
  st=$(grep -h "^M4RUN $1 " "$E/runs.log" | tail -n 1)
  [[ "$st" =~ ^M4RUN\ $1\ (OK|NOTE) ]] || { echo "SEQUENCE STOP: $1 no M4RUN OK/NOTE"; exit 1; }
  { echo "# H1 per-run checks $1 (system $2, mix $3, phase $4, round $H1_N, seed $H1_SEED; v6-block.sh H1-HOOK v1)"
    echo "$st"
    for k in 0 1; do echo "node$k: $(grep -c '^bad_records=0$' $r/node$k.log) x bad_records=0, $(grep -c 'vdb-server: stopping' $r/node$k.log) x stopping, $(grep -h '^opcoh.read_errors=\|^opcoh.register_errors=' $r/node$k.log | tr '\n' ' ')"; done
    echo "opcoh_check: $(tail -n 1 $r/opcoh-check.txt)"
    echo "opsplit: $(tail -n 1 $r/opsplit.log | cut -c1-300)"
    echo "e1: $(head -n 3 $r/e1.e1.txt 2>/dev/null | tr '\n' ' ')"
    echo "loadgen: $(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print("workload_finish", s.get("workload_finish"), "note", repr(s.get("note", "")))' $r/loadgen/summary.json)"
    echo "kernel: $(grep -h '^node0=' $r/manifest.txt)"
  } > $r/h1-runcheck.txt
  grep -q "^opcoh_check: OPCOH_CHECK PASS" $r/h1-runcheck.txt && [ -f $r/opsplit-steps.csv ] \
    && grep -q "workload_finish ok" $r/h1-runcheck.txt || { echo "SEQUENCE STOP: $1 run checks incomplete"; exit 1; }
  if [[ "$st" =~ \ NOTE ]]; then echo "RUNCHECK PASS (NOTE: ${st#* NOTE })" >> $r/h1-runcheck.txt
  else echo "RUNCHECK PASS" >> $r/h1-runcheck.txt; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$H1_N" "$1" >> "$E/h1-runs.tsv"
}
h1_u() { case $1 in U=5|U=50|U=90) echo ${1#U=};; *) echo "SEQUENCE STOP: bad mix parameter $1" >&2; return 1;; esac; }
h1_run() {  # <sys> <mix> <phase> <env...>
  local s=$1 m=$2 ph=$3 name=$1-$2-$3-r$H1_N; shift 3
  parent_lock_check
  case $s in mg) set -- "$@" OPCOH_CHECK_MODE=megalon-vm;; esac
  one $s $name SEED=$H1_SEED REP=h1-$ph-r$H1_N "$@"
  h1_runcheck $name $s $m $ph
}
h1_main() {
  local s m spec u base rot ord mixes line f mix l1 l2 i
  printf '# name\tsystem\tmix\tphase\tround\trun_dir\n' > "$E/h1-runs.tsv"
  if [ $H1MODE = slo ]; then
    base=($(SHUFFLE_SEED=H1-vdb-r1 shuffle hw pop mg)); rot=$(( (H1_N - 1) % 3 ))
    ord="${base[@]:$rot} ${base[@]:0:$rot}"; ord=$(echo $ord)
    mixes=""; for spec in $H1_MIXES; do mixes="$mixes ${spec%%=*}"; h1_u "${spec#*=}" > /dev/null || exit 1; done
    mixes=$(SHUFFLE_SEED=H1-vdb-r$H1_N shuffle $mixes)
    { echo "# H1 vector DB SLO round $H1_N (systems: base shuffle seed H1-vdb-r1 rotated left by $rot; mixes: shuffle seed H1-vdb-r$H1_N; loadgen seed $H1_SEED)"
      echo "systems: $ord"; echo "mixes: $mixes"; echo "H1_MIXES: $H1_MIXES"; } | tee "$E/order.txt"
    for s in $ord; do
      for m in $mixes; do
        for spec in $H1_MIXES; do [ "${spec%%=*}" = $m ] && u=$(h1_u "${spec#*=}"); done
        h1_run $s $m slo U=$u KIND=slo
      done
    done
  else
    { echo "# H1 vector DB fixed phase rep $H1_N (levels $H1_LEVELS; systems per mix: shuffle seed H1-vdb-fix-r$H1_N; loadgen seed $H1_SEED; windows L2 then L1)"
      tail -n +2 "$H1_LEVELS" | while IFS=$'\t' read -r mix f; do
        echo "$mix: $(SHUFFLE_SEED=H1-vdb-fix-r$H1_N shuffle hw pop mg mgoff)"; done; } | tee "$E/order.txt"
    while IFS=$'\t' read -r -a f; do
      mix=${f[0]} l1=${f[8]} l2=${f[9]}
      u=$(h1_u "U=${mix#u}") || exit 1
      [[ $l1 =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ $l2 =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "SEQUENCE STOP: levels $mix rates"; exit 1; }
      for s in $(SHUFFLE_SEED=H1-vdb-fix-r$H1_N shuffle hw pop mg mgoff); do
        h1_run $s $mix fix U=$u KIND=fixed RATE=$l2,$l1 < /dev/null
      done
    done < <(tail -n +2 "$H1_LEVELS")
  fi
}
block_start
C8=$CPOP K8=$KPOP GT8=$GTPOP  # block_shm_cleanup (m4-lib.sh) reads C8/K8/GT8
pretouch_gate block-start
precheck "$KPOP"
if [ -n "${H1MODE:-}" ]; then
  h1_main
  pretouch_gate block-end
  echo "$(date -Is) SEQUENCE DONE H1-vdb $H1MODE r$H1_N ($(($(wc -l < "$E/h1-runs.tsv") - 1)) runs)"
  exit 0
fi
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
pretouch_gate block-end  # no QEMU restart during the block
echo "$(date -Is) SEQUENCE DONE $OWNER"
