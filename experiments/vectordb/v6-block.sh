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
# H1-HOOK v2 (experiments/h1/README.md "Hook contract H1-HOOK v2", reports/H1-main-packet.md v0.3 §2-§3; user decisions
#   2026-10-18): one block call per round, with this block's precheck, Host gate per lifetime (m4-run.sh), pretouch gate
#   (start, every lifetime, end), parent-lock check per lifetime, checks and rollback. Env from experiments/h1/hook.sh:
#   H1MODE r1|cont, H1_N, H1_SEED (loadgen seed of every part), H1_MIXES "<mix>=U=<5|50|90> ..." (u5/u50/u90 =
#   search/update 95/5, 50/50, 10/90, MOT1 v6, 28M), H1_SETTLE_S (vector DB 60), H1_PARENT_LOCK=H1-main (this block
#   never locks or unlocks), r1: H1_LEVELS_CMD (+ H1_PLAN H1_W H1_LEVELS_OUT H1_STAGE_DIR for it), cont: H1_LEVELS.
#   A lifetime = one m4-run.sh KIND=h1 run (one server start incl. initial image / Popcorn preload) with loadgen parts
#   <lifetime>/slo (full SLO search: ramp, bisect, confirm 3 x 30 s, fill, overload 1.05/1.1/1.2; every step kept) and
#   <lifetime>/fix (settle = loadgen --warmup-s H1_SETTLE_S at the L2 rate, discarded; then 60 s windows L2, L1).
#   r1, per mix (mix order shuffle seed "H1-vdb-r1"): hw and pop SLO-only lifetimes (order seed "H1-vdb-r1-<mix>");
#       mg lifetime: slo part, its h1-runs.tsv line, "$H1_LEVELS_CMD <mix>" -> "<L2> <L1>" (failure = LEVELS STOP: the
#       block stops, no fixed windows, rollback), fix part at those rates; mgoff lifetime (MEGALON_COH_TIMERS=0, fix
#       part only, rates from H1_LEVELS_OUT); hw and pop fixed lifetimes (fix part only; order seed "H1-vdb-r1-<mix>-fix").
#   cont (rounds 2, 3; rates = H1_LEVELS L2_rate / L1_rate), per mix (order seed "H1-vdb-r<N>"): hw, pop, mg in the
#       Latin order shuffle("H1-vdb-latin") rotated by N, each one lifetime slo + fix; mgoff (fix only) right after mg.
#   Per lifetime <lifetime>/h1-runcheck.txt (last line RUNCHECK PASS[ (NOTE: ...)]); <dir>/h1-runs.tsv 8 columns
#   name system mix phase round run_dir(<lifetime>/<part>) steps(- | <L2 step>,<L1 step>) lifetime(sep|cont).
#   A loadgen "confirm failed at three rates" note in a slo part is a NOTE (block continues). E1 wait timeouts on
#   overload steps are recorded (timeouts.txt), not failures; every other check failure stops the block.
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
  : "${H1_MIXES:?}"; [[ "${H1_SETTLE_S:-}" =~ ^[1-9][0-9]*$ ]] || { echo "SEQUENCE STOP: bad H1_SETTLE_S"; exit 2; }
  case $H1MODE in r1) : "${H1_LEVELS_CMD:?}" "${H1_LEVELS_OUT:?}";;
    cont) [ -f "${H1_LEVELS:-}" ] || { echo "SEQUENCE STOP: no H1_LEVELS"; exit 2; };;
    *) echo "SEQUENCE STOP: bad H1MODE (H1-HOOK v2: r1 | cont)"; exit 2;; esac
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
# H1 hook helpers (H1-HOOK v2)
h1_u() { case $1 in U=5|U=50|U=90) echo ${1#U=};; *) echo "SEQUENCE STOP: bad mix parameter $1" >&2; return 1;; esac; }
h1_mixu() {  # <mix> -> U from H1_MIXES
  local spec; for spec in $H1_MIXES; do [ "${spec%%=*}" = "$1" ] && { h1_u "${spec#*=}"; return; }; done
  echo "SEQUENCE STOP: mix $1 not in H1_MIXES" >&2; return 1
}
h1_levels() {  # <levels.tsv> <mix> -> "<L2_rate>,<L1_rate>"
  awk -F'\t' -v m="$2" 'NR > 1 && $1 == m { print $10 "," $9; f = 1 } END { exit f ? 0 : 1 }' "$1" \
    | grep -xE '[0-9]+(\.[0-9]+)?,[0-9]+(\.[0-9]+)?' || { echo "SEQUENCE STOP: no levels for $2 in $1" >&2; return 1; }
}
h1_line() {  # <sys> <mix> <phase> <lifetime> <life sep|cont>
  local st=- r=$E/$4/$3
  [ $3 = fix ] && { st=$(cat $r/h1-steps.txt 2>/dev/null); [[ $st =~ ^[0-9]+,[0-9]+$ ]] || { echo "SEQUENCE STOP: $4 fix steps"; exit 1; }; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1-$2-$3-r$H1_N" "$1" "$2" "$3" "$H1_N" "$4/$3" "$st" "$5" >> "$E/h1-runs.tsv"
}
h1_runcheck() {  # <lifetime> <sys> <mix> <parts>: per-lifetime record (m4-run.sh stopped the block on any failed check)
  local L=$1 r=$E/$1 st p
  st=$(grep -h "^M4RUN $L " "$E/runs.log" | tail -n 1)
  [[ "$st" =~ ^M4RUN\ $L\ (OK|NOTE) ]] || { echo "SEQUENCE STOP: $L no M4RUN OK/NOTE"; exit 1; }
  { echo "# H1 per-lifetime checks $L (system $2, mix $3, parts $4, round $H1_N, seed $H1_SEED, settle ${H1_SETTLE_S}s; v6-block.sh H1-HOOK v2)"
    echo "$st"
    for k in 0 1; do echo "node$k: $(grep -c '^bad_records=0$' $r/node$k.log) x bad_records=0, $(grep -c 'vdb-server: stopping' $r/node$k.log) x stopping, $(grep -h '^opcoh.read_errors=\|^opcoh.register_errors=' $r/node$k.log | tr '\n' ' ')"; done
    for p in $4; do
      echo "[$p] opcoh_check: $(tail -n 1 $r/$p/opcoh-check.txt)"
      echo "[$p] opsplit: $(tail -n 1 $r/$p/opsplit.log | cut -c1-300)"
      echo "[$p] e1: $(head -n 3 $r/$p/e1.e1.txt 2>/dev/null | tr '\n' ' ')"
      echo "[$p] loadgen: $(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print("workload_finish", s.get("workload_finish"), "note", repr(s.get("note", "")))' $r/$p/loadgen/summary.json)"
      [ $p = fix ] && echo "[$p] steps L2,L1: $(cat $r/$p/h1-steps.txt)"
    done
    echo "kernel: $(grep -h '^node0=' $r/manifest.txt)"
  } > $r/h1-runcheck.txt
  for p in $4; do
    grep -q "^\[$p\] opcoh_check: OPCOH_CHECK PASS" $r/h1-runcheck.txt && [ -f $r/$p/opsplit-steps.csv ] \
      && grep -q "^\[$p\] loadgen: workload_finish ok" $r/h1-runcheck.txt || { echo "SEQUENCE STOP: $L run checks incomplete ($p)"; exit 1; }
  done
  if [[ "$st" =~ \ NOTE ]]; then echo "RUNCHECK PASS (NOTE: ${st#* NOTE })" >> $r/h1-runcheck.txt
  else echo "RUNCHECK PASS" >> $r/h1-runcheck.txt; fi
}
h1_life() {  # <sys> <mix> <lifetime name> <parts "slo"|"slo fix"|"fix"> <life sep|cont> <rates "L2,L1" | cb>
  local s=$1 m=$2 L=$3 parts=$4 life=$5 rates=$6 u x
  u=$(h1_mixu $m) || exit 1
  parent_lock_check
  x=(U=$u KIND=h1 "H1_PARTS=$parts" SETTLE_S=$H1_SETTLE_S SEED=$H1_SEED REP=h1-r$H1_N)
  case $rates in
    cb) x+=(RATE= "RATES_CMD=bash $X/h1-rates.sh $E $s $m $L $life $H1_N");;  # r1 mg: slo line + levels callback
    -) x+=(RATE= RATES_CMD=);;  # slo-only lifetime: no fix part
    *) x+=(RATE=$rates);;
  esac
  case $s in mg) x+=(OPCOH_CHECK_MODE=megalon-vm);; esac
  one $s $L "${x[@]}" < /dev/null
  h1_runcheck $L $s $m "$parts"
  [[ " $parts " == *" slo "* ]] && [ "$rates" != cb ] && h1_line $s $m slo $L $life
  [[ " $parts " == *" fix "* ]] && h1_line $s $m fix $L $life
  return 0
}
h1_main() {
  local m s mixes base rot ord rates
  printf '# name\tsystem\tmix\tphase\tround\trun_dir\tsteps\tlifetime\n' > "$E/h1-runs.tsv"
  mixes=""; for spec in $H1_MIXES; do mixes="$mixes ${spec%%=*}"; h1_u "${spec#*=}" > /dev/null || exit 1; done
  mixes=$(SHUFFLE_SEED=H1-vdb-r$H1_N shuffle $mixes)
  if [ $H1MODE = r1 ]; then
    { echo "# H1 vector DB r1 (H1-HOOK v2; mixes: shuffle seed H1-vdb-r1; loadgen seed $H1_SEED; settle ${H1_SETTLE_S}s)"
      echo "mixes: $mixes"
      for m in $mixes; do echo "$m: slo $(SHUFFLE_SEED=H1-vdb-r1-$m shuffle hw pop) mg(slo+levels+fix) mgoff(fix) fix $(SHUFFLE_SEED=H1-vdb-r1-$m-fix shuffle hw pop)"; done
    } | tee "$E/order.txt"
    for m in $mixes; do
      for s in $(SHUFFLE_SEED=H1-vdb-r1-$m shuffle hw pop); do h1_life $s $m $s-$m-slo-r1 slo sep -; done
      h1_life mg $m mg-$m-r1 "slo fix" cont cb
      rates=$(h1_levels "$H1_LEVELS_OUT" $m) || exit 1
      h1_life mgoff $m mgoff-$m-fix-r1 fix sep $rates
      for s in $(SHUFFLE_SEED=H1-vdb-r1-$m-fix shuffle hw pop); do h1_life $s $m $s-$m-fix-r1 fix sep $rates; done
    done
  else
    base=($(SHUFFLE_SEED=H1-vdb-latin shuffle hw pop mg)); rot=$(( H1_N % 3 ))
    ord="${base[@]:$rot} ${base[@]:0:$rot}"; ord=$(echo $ord)
    { echo "# H1 vector DB round $H1_N cont (H1-HOOK v2; systems: shuffle seed H1-vdb-latin rotated by $H1_N; mixes: shuffle seed H1-vdb-r$H1_N; mgoff right after mg; loadgen seed $H1_SEED; settle ${H1_SETTLE_S}s; levels $H1_LEVELS)"
      echo "systems: $ord"; echo "mixes: $mixes"; } | tee "$E/order.txt"
    for m in $mixes; do
      rates=$(h1_levels "$H1_LEVELS" $m) || exit 1
      for s in $ord; do
        h1_life $s $m $s-$m-r$H1_N "slo fix" cont $rates
        [ $s = mg ] && h1_life mgoff $m mgoff-$m-fix-r$H1_N fix sep $rates
      done
    done
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
