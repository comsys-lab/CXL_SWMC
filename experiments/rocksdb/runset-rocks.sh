#!/bin/bash
# RocksDB SLO-search run set (eval3, experiment de-stijl-evaluation-run1, blocks D and E): one v1-block.sh block per
# (conf, N, kernel phase). Phase hwpop = the hw and pop cells on the Popcorn guest kernel (hw first: one dax0.0 chown
# switch), phase ds = the De Stijl cells (T = 0) on the De Stijl guest kernel; the kernel switch between the phases is
# the calling chain's job (scripts/deploy/p-destijl-*.sh). Every cell = one server lifetime with ONE aggregate SLO
# search (loadgen --mode slo: ramp, bisect, confirm, fill, overload points past the knee; the vector DB cell rule via
# ROCKS_SLO_EXTRA), result dir <E>/<sys>-<mix>-n<N>/ (manifest, steps.csv, stats-steps.csv, loadgen/), after the block
# <E>/rocks-results.tsv (slo_result.py: max requests/s under the SLO per cell, checks).
# usage: runset-rocks.sh <conf> <N> <hwpop|ds> [--dry-run] [--v V] [--only "<sys>-<mix> ..."]
#   conf     experiments/rocksdb/eval3-rocks-{d,e}.conf (keys below; relative paths are relative to the project root)
#   --dry-run  validate the conf and the chain environment, print the block plan and run v1-block.sh DRY=1 (bundle
#            hashes, region configs, builds, every run's arguments, the cxl_shm plan); no ssh, no lock, nothing written
#   --v V    evidence dir version (default: the next free one); --only: a subset of the phase's cells, in conf order
# exit: 0 all cells confirmed | 3 block done, some cell UNCONFIRMED (loadgen note "confirm failed at three rates"; the
#   other cells still ran; a WARN, not a failure) | 1 real failure (block stop or result ERROR row) | 2 usage / env stop
# Chain environment (required unless --dry-run): PRETOUCH_DIR (pretouch evidence of the VMs' current QEMU lifetimes),
#   MEASURE_ENV_DIR, MEASURE_PART_DIR (Host measurement evidence; h3-gate.sh). Real runs also require
#   state/EXPERIMENTS.md "### de-stijl-evaluation-run1" to read "- Status: approved" or "- Status: running".
# Evidence: <RESULTS_ROOT>/<EVIDENCE_PREFIX>-<block>-<phase>-n<N>-v<V> (block.out, tasks-check.txt, v1-block evidence).
# Conf keys: ROCKS_BLOCK (D | E), ROCKS_TOPO (2 = cxl_vm0/1 16 vCPU XML with CPUs 4-15 offline | 8 = VM8 4 vCPU),
#   ROCKS_NODES ("2" | "4 8"), ROCKS_MIXES ("u5 u50"), ROCKS_SYSTEMS (subset of "hw pop ds"), ROCKS_SLO_MS (1),
#   ROCKS_KEYS, ROCKS_THREADS, EXPECT_NPROC, MIN_MEM_G, ROCKS_BUILD, ROCKS_LOADGEN_BUILD, ROCKS_SLO_EXTRA, RECV_MODE,
#   EXPECT_DAX_UUID, RESULTS_ROOT, EVIDENCE_PREFIX, ROCKS_GUEST_PREFIX, POP_REGION POP_C POP_BUNDLE_SHA POP_K POP_GT,
#   DS_REGION DS_C DS_BUNDLE_SHA DS_K DS_GT.
# Optional keys (2026-11-02, receiver 200 / 50 re-measure): ROCKS_DS_RECV_EXTRA "idle_sleep_us=<n> idle_spin_us=<n>"
#   (phase ds: exported as DS_RECV_EXTRA to pilot-run.sh = appended to the cxl_shm load, read back after the enable;
#   empty / absent = module defaults). ROCKS_BLOCK may then be D200 | E200 (evidence <prefix>-D200-ds-n<N>-v<V>,
#   guest dir <ROCKS_GUEST_PREFIX>-d200-...), so the 200 / 50 cells never share a name with the block D / E cells.
# Megalon (eval run2, 2026-11-03; workloads/rocksdb DESIGN.md §7): phase mg = the mg cells (Object SWcc, user level, no
#   cxl_shm) on the all-HWcc guest kernel and region (POP_K, POP_REGION, dax0.0 chowned to comsys as for hw), with the
#   Megalon server build of that N: ROCKS_MG_BUILD_N<N> (build.sh with builds/megalon/<b>-n<N>; lib/ shipped),
#   ROCKS_MG_CFG_N<N> (Megalon config, object_arena_size >= N x (512 + extents) MiB), ROCKS_MG_EXTENTS_N<N> (file extents
#   per node). ROCKS_SYSTEMS may then contain mg; ROCKS_BLOCK may be MG. ROCKS_EXPERIMENT (optional): the
#   state/EXPERIMENTS.md block a real run requires approved/running (default de-stijl-evaluation-run1).
set -uo pipefail
P=/home/comsys/sungsu/destijl-control
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$HERE/../.." && pwd)
die() { echo "RUNSET STOP: $*"; exit 2; }
CONF=${1:-}; N=${2:-}; PHASE=${3:-}; shift 3 2>/dev/null || die "usage: runset-rocks.sh <conf> <N> <hwpop|ds|mg> [--dry-run] [--v V] [--only '...']"
DRY=0 V= ONLY=
while [ $# -gt 0 ]; do
  case $1 in --dry-run) DRY=1; shift;; --v) V=${2:-}; shift 2;; --only) ONLY=${2:-}; shift 2;; *) die "unknown argument $1";; esac
done
[ -f "$CONF" ] || die "conf $CONF missing"
KEYS="ROCKS_BLOCK ROCKS_TOPO ROCKS_NODES ROCKS_MIXES ROCKS_SYSTEMS ROCKS_SLO_MS ROCKS_KEYS ROCKS_THREADS EXPECT_NPROC MIN_MEM_G
  ROCKS_BUILD ROCKS_LOADGEN_BUILD ROCKS_SLO_EXTRA RECV_MODE EXPECT_DAX_UUID RESULTS_ROOT EVIDENCE_PREFIX ROCKS_GUEST_PREFIX
  POP_REGION POP_C POP_BUNDLE_SHA POP_K POP_GT DS_REGION DS_C DS_BUNDLE_SHA DS_K DS_GT"
OPTKEYS="ROCKS_DS_RECV_EXTRA ROCKS_EXPERIMENT ROCKS_MG_BUILD_N2 ROCKS_MG_BUILD_N4 ROCKS_MG_BUILD_N8 ROCKS_MG_CFG_N2
  ROCKS_MG_CFG_N4 ROCKS_MG_CFG_N8 ROCKS_MG_EXTENTS_N2 ROCKS_MG_EXTENTS_N4 ROCKS_MG_EXTENTS_N8
  POP_RECV_MODE POP_ADAPT_KO RECV_IPOLL RECV_WATCH_US RECV_S_MAX_US ROCKS_PMAX ROCKS_PMAX_FROM ROCKS_PMAX_MEASURE_S
  REQUIRE_ADAPTIVE REQUIRE_SLEEP2050
  ROCKS_FIXED ROCKS_FIXED_RECVP ROCKS_FIXED_RECVP_BASE"
# shellcheck disable=SC2086
unset $KEYS $OPTKEYS
# the conf may set only these keys (a typo or a foreign key stops)
bad=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | grep -vE "^($(echo $KEYS $OPTKEYS | tr ' ' '|'))=" | head -3)
[ -z "$bad" ] || die "conf lines that are not KEY=value of a known key: $bad"
# shellcheck disable=SC1090
. "$CONF"
for k in $KEYS; do [ -n "${!k:-}" ] || die "conf key $k empty"; done
abs() { case $1 in /*) echo "$1";; *) echo "$P/$1";; esac; }
ROCKS_BUILD=$(abs "$ROCKS_BUILD") ROCKS_LOADGEN_BUILD=$(abs "$ROCKS_LOADGEN_BUILD") RESULTS_ROOT=$(abs "$RESULTS_ROOT")
POP_REGION=$(abs "$POP_REGION") POP_C=$(abs "$POP_C") DS_REGION=$(abs "$DS_REGION") DS_C=$(abs "$DS_C")
[[ $ROCKS_BLOCK =~ ^([DE](200)?|MG|ABL)$ ]] || die "ROCKS_BLOCK D | E | D200 | E200 | MG | ABL"
# Receiver-ablation lifetimes (run 2, 2026-11-04; optional, unset = every cell is one SLO search as before):
#   ROCKS_FIXED       tokens <sys>/<part>/-/-/<rates>/<step warm-up s>/<measure s>/<drain s> (sys pop | ds; per system in
#                     order, the first = the warm part at the base): the pop / ds cell is ONE lifetime of fixed-rate parts
#                     (pilot-run.sh KIND=parts), no SLO search, no pmax; exactly one mix; ROCKS_BLOCK ABL
#   ROCKS_FIXED_RECVP tokens <sys>/<part>/<k>=<v>[,<k>=<v>...] (k: recv_mode poll|sleep|adaptive, ipoll, spin_us,
#                     watch_us, s_min_us, s_max_us, idle_spin_us, idle_sleep_us; fault_poll 0|1 for ds parts whose base
#                     has ds:fault_poll=<the ROCKS_DS_RECV_EXTRA value>): written before the part on every VM,
#                     restored after it (experiments/eval/fixed-part-hook.sh via part-hook.sh; recv_mode last)
#   ROCKS_FIXED_RECVP_BASE <k>=<v>,... = the lifetime's receiver state (recv_mode = RECV_MODE, ipoll = RECV_IPOLL),
#                     checked on every VM before the parts, before each variant part and after each part
FX=${ROCKS_FIXED:-} FXR=${ROCKS_FIXED_RECVP:-} FXB=${ROCKS_FIXED_RECVP_BASE:-}
if [ -n "$FX$FXR$FXB" ]; then
  [ -n "$FX" ] && [ -n "$FXB" ] || die "ROCKS_FIXED and ROCKS_FIXED_RECVP_BASE go together"
  [ "$ROCKS_BLOCK" = ABL ] || die "ROCKS_FIXED needs ROCKS_BLOCK ABL (evidence names apart from the SLO blocks)"
  [ "$(wc -w <<< "$ROCKS_MIXES")" = 1 ] || die "ROCKS_FIXED: exactly one mix in ROCKS_MIXES"
  [ "${ROCKS_PMAX:-0}" = 0 ] || die "ROCKS_FIXED: ROCKS_PMAX must be 0 (no SLO part)"
  RPKRE='(recv_mode=(poll|sleep|adaptive)|(ipoll|spin_us|watch_us|s_min_us|s_max_us|idle_spin_us|idle_sleep_us)=[0-9]+|fault_poll=[01])'
  # base items may carry a system prefix (ds:fault_poll=0: De Stijl's base only; fixed-part-hook.sh); fault_poll is ds-only
  BPKRE="((pop|ds):)?$RPKRE"
  [[ $FXB =~ ^$BPKRE(,$BPKRE)*$ ]] && [[ ,$FXB, == *,recv_mode=$RECV_MODE,* ]] || die "bad ROCKS_FIXED_RECVP_BASE ($FXB; recv_mode must be RECV_MODE $RECV_MODE)"
  [[ ,$FXB, != *,fault_poll=* && ,$FXB, != *,pop:fault_poll=* ]] || die "ROCKS_FIXED_RECVP_BASE: fault_poll only as ds:fault_poll=<0|1> (Popcorn's cxl_shm has none)"
  fpb=$(sed -n 's/.*ds:fault_poll=\([01]\).*/\1/p' <<< "$FXB")
  [ -z "$fpb" ] || [[ " ${ROCKS_DS_RECV_EXTRA:-} " == *" fault_poll=$fpb "* ]] \
    || die "ROCKS_FIXED_RECVP_BASE ds:fault_poll=$fpb != ROCKS_DS_RECV_EXTRA fault_poll (the load value is the base)"
  [ -z "${POP_RECV_MODE:-}" ] || [ "$POP_RECV_MODE" = "$RECV_MODE" ] || die "ROCKS_FIXED: POP_RECV_MODE != RECV_MODE (one base)"
  [ -z "${RECV_IPOLL:-}" ] || [[ ,$FXB, == *,ipoll=$RECV_IPOLL,* ]] || die "ROCKS_FIXED_RECVP_BASE ipoll != RECV_IPOLL $RECV_IPOLL"
  for x in watch_us=${RECV_WATCH_US:-} s_max_us=${RECV_S_MAX_US:-}; do
    [ -z "${x#*=}" ] || [[ ,$FXB, != *,${x%%=*}=* ]] || [[ ,$FXB, == *,$x,* ]] || die "ROCKS_FIXED_RECVP_BASE ${x%%=*} != the conf's $x (RECV_WATCH_US / RECV_S_MAX_US)"
  done
  declare -A FXP=()
  for t in $FX; do
    [[ $t =~ ^(pop|ds)/[a-z0-9]+/-/-/[0-9]+(,[0-9]+)*/[0-9]+/[1-9][0-9]*/[0-9]+$ ]] || die "bad ROCKS_FIXED token $t (<pop|ds>/<part>/-/-/<rates>/<warm-up>/<measure>/<drain>)"
    IFS=/ read -r fs fp _ <<< "$t"
    [[ " ${FXP[$fs]:-} " != *" $fp "* ]] || die "ROCKS_FIXED: part $fp twice for $fs"
    FXP[$fs]+=" $fp"
  done
  for t in $FXR; do
    [[ $t =~ ^(pop|ds)/[a-z0-9]+/$RPKRE(,$RPKRE)*$ ]] || die "bad ROCKS_FIXED_RECVP token $t"
    IFS=/ read -r fs fp fkv <<< "$t"
    [[ " ${FXP[$fs]:-} " == *" $fp "* ]] || die "ROCKS_FIXED_RECVP $t: no ROCKS_FIXED part $fp for $fs"
    [ "$fp" != "$(set -- ${FXP[$fs]}; echo "$1")" ] || die "ROCKS_FIXED_RECVP $t: the first (warm) part runs at the base"
    for x in ${fkv//,/ }; do [[ ,$FXB, == *,${x%%=*}=* || ,$FXB, == *,$fs:${x%%=*}=* ]] || die "ROCKS_FIXED_RECVP $t: ${x%%=*} not in ROCKS_FIXED_RECVP_BASE (for $fs)"; done
  done
fi
EXPN=${ROCKS_EXPERIMENT:-de-stijl-evaluation-run1}
[[ $EXPN =~ ^[a-z0-9][-a-z0-9]*$ ]] || die "bad ROCKS_EXPERIMENT ($EXPN)"
DSRX=${ROCKS_DS_RECV_EXTRA:-}
[[ $DSRX =~ ^(((idle_sleep_us|idle_spin_us)=[0-9]+|fault_poll=[01])( |$))*$ ]] || die "bad ROCKS_DS_RECV_EXTRA ($DSRX: 'idle_sleep_us=<n> idle_spin_us=<n> fault_poll=<0|1>')"
# run-2 receiver keys (experiments/eval/recv-mode.sh; pilot-run.sh checks them per cell): POP_RECV_MODE, POP_ADAPT_KO
# (relative = project root), RECV_IPOLL, RECV_WATCH_US / RECV_S_MAX_US (adaptive watch_us / s_max_us, recv_wsm_check;
# a non-adaptive pop / ds cell refuses them: pilot-run.sh stops, its dry run notes)
[ -z "${POP_ADAPT_KO:-}" ] || POP_ADAPT_KO=$(abs "$POP_ADAPT_KO")
. "$TREE/experiments/eval/recv-mode.sh"
why=$(recv_wsm_check); [ $? != 1 ] || die "$why"
if [ "$PHASE" = hwpop ] && [[ " $ROCKS_SYSTEMS " == *" pop "* ]]; then
  why=$(recv_rules pop "${POP_RECV_MODE:-$RECV_MODE}" "$POP_C" "$N") || die "Popcorn receiver: $why"
elif [ "$PHASE" = ds ]; then
  why=$(recv_rules ds "$RECV_MODE" "$DS_C" "$N") || die "De Stijl receiver: $why"
fi
[[ $ROCKS_BLOCK != *200 ]] || [ -n "$DSRX" ] || die "ROCKS_BLOCK $ROCKS_BLOCK needs ROCKS_DS_RECV_EXTRA"
# run-2 guard (conf REQUIRE_SLEEP2050=1, earlier REQUIRE_ADAPTIVE=1, verifier M3): phases hwpop / ds of a real run
# refuse placeholder receiver pins; REQUIRE_SLEEP2050 is exported to pilot-run.sh (readback asserts sleep 20/50)
if [ "$PHASE" != mg ] && ! why=$(recv_run2_guard); then
  [ $DRY = 1 ] && echo "RUNSET NOTE: run-2 guard: $why (a real run stops here)" || die "run-2 guard: $why"
fi
[ "$PHASE" = mg ] || [ "${REQUIRE_SLEEP2050:-0}" != 1 ] || echo "RUNSET run-2 guard: sleep 20/50 receiver for pop and ds (readback asserted)"
[[ " $ROCKS_NODES " == *" $N "* ]] || die "N=$N not in ROCKS_NODES ($ROCKS_NODES)"
[ "$ROCKS_SLO_MS" = 1 ] || die "ROCKS_SLO_MS must be 1 (user decision: RocksDB SLO p99 1 ms)"
[ "$EXPECT_NPROC" = 4 ] || die "EXPECT_NPROC must be 4 (4 vCPU rule, user 2026-11-01)"
case $ROCKS_TOPO in
  2) [ "$N" = 2 ] || die "ROCKS_TOPO=2 is N = 2 only"; IPS="192.168.122.100 192.168.122.101"; DOMS="cxl_vm0 cxl_vm1";;
  8) IPS=$(for ((k = 0; k < N; k++)); do printf '192.168.122.%d ' $((100 + k)); done); IPS=${IPS% }
     DOMS=$(for ((k = 0; k < N; k++)); do printf 'cxl_vm%d ' $k; done); DOMS=${DOMS% };;
  *) die "ROCKS_TOPO 2 | 8";;
esac
case $PHASE in
  hwpop) SYSS=""; for s in hw pop; do [[ " $ROCKS_SYSTEMS " == *" $s "* ]] && SYSS="$SYSS $s"; done
         EXPECT_K=$POP_K REGION=$POP_REGION;;
  ds) [[ " $ROCKS_SYSTEMS " == *" ds "* ]] || die "ds not in ROCKS_SYSTEMS"; SYSS=" ds"; EXPECT_K=$DS_K REGION=$DS_REGION;;
  mg) [[ " $ROCKS_SYSTEMS " == *" mg "* ]] || die "mg not in ROCKS_SYSTEMS"; SYSS=" mg"; EXPECT_K=$POP_K REGION=$POP_REGION
      kb=ROCKS_MG_BUILD_N$N kc=ROCKS_MG_CFG_N$N kx=ROCKS_MG_EXTENTS_N$N
      [ -n "${!kb:-}" ] && [ -n "${!kc:-}" ] && [ -n "${!kx:-}" ] || die "phase mg at N = $N needs $kb, $kc and $kx"
      MG_BUILD=$(abs "${!kb}") MEG_CFG=$(abs "${!kc}") MG_EXTENTS=${!kx}
      [[ $MG_EXTENTS =~ ^[1-9][0-9]*$ ]] || die "bad $kx"
      [ -f "$MG_BUILD/manifest.txt" ] && [ -f "$MEG_CFG" ] || die "$kb ($MG_BUILD) or $kc ($MEG_CFG) missing"
      ROCKS_BUILD=$MG_BUILD;;
  *) die "phase hwpop | ds | mg";;
esac
[ -n "$SYSS" ] || die "no system of phase $PHASE in ROCKS_SYSTEMS"
RUNS=""; NAMES=""
for s in $SYSS; do
  XR=""
  case $s in hw) SYS=all-HWcc;; pop) SYS=Popcorn;; ds) SYS=DeStijl;; mg) SYS=Megalon XR=" FILE_EXTENTS=$MG_EXTENTS";; esac
  [ "${ROCKS_PMAX:-0}" = 0 ] || [[ ! $s =~ ^(pop|ds)$ ]] || XR="$XR PMAX=1"   # run-2 pmax step (pop / ds cells)
  for mix in $ROCKS_MIXES; do
    case $mix in u5) UR=0.05;; u50) UR=0.5;; *) die "mix $mix: u5 | u50 (pilot-run.sh UPDATE_RATIO 0.05 | 0.5)";; esac
    name=$s-$mix-n$N
    [ -z "$ONLY" ] || [[ " $ONLY " == *" $s-$mix "* ]] || continue
    KD=slo
    if [ -n "$FX" ]; then  # receiver ablation: pop / ds cells only, each with its own ROCKS_FIXED parts
      [[ $s =~ ^(pop|ds)$ ]] || die "ROCKS_FIXED: cell $name (only pop / ds cells are part lifetimes)"
      [ -n "${FXP[$s]:-}" ] || die "ROCKS_FIXED has no part for $s"
      KD=parts
    fi
    RUNS+="$name SYS=$SYS KIND=$KD KEYS=$ROCKS_KEYS THREADS=$ROCKS_THREADS UPDATE_RATIO=$UR$XR"$'\n'; NAMES+=" $name"
  done
done
[ -n "$RUNS" ] || die "no cell selected (--only '$ONLY')"
BL=$(tr 'A-Z' 'a-z' <<< "$ROCKS_BLOCK")
[ "$PHASE" = ds ] || [ -z "$DSRX" ] || echo "RUNSET NOTE: ROCKS_DS_RECV_EXTRA ignored in phase $PHASE (De Stijl only)"
if [ -z "$V" ]; then V=1; while [ -e "$RESULTS_ROOT/$EVIDENCE_PREFIX-$ROCKS_BLOCK-$PHASE-n$N-v$V" ]; do V=$((V + 1)); done; fi
[[ $V =~ ^[1-9][0-9]*$ ]] || die "bad --v"
E=$RESULTS_ROOT/$EVIDENCE_PREFIX-$ROCKS_BLOCK-$PHASE-n$N-v$V
OWNER=$(basename "$E") L=$ROCKS_GUEST_PREFIX-$BL-$PHASE-n$N-v$V
if [ $DRY = 1 ]; then
  : "${PRETOUCH_DIR:=<chain PRETOUCH_DIR>}" "${MEASURE_ENV_DIR:=<chain MEASURE_ENV_DIR>}" "${MEASURE_PART_DIR:=<chain MEASURE_PART_DIR>}"
else
  : "${PRETOUCH_DIR:?chain env PRETOUCH_DIR}" "${MEASURE_ENV_DIR:?chain env MEASURE_ENV_DIR}" "${MEASURE_PART_DIR:?chain env MEASURE_PART_DIR}"
  st=$(awk -v h="### $EXPN" '$0 == h || index($0, h " ") == 1 {f=1; next} /^### /{f=0} f && /^- Status:/' "$P/state/EXPERIMENTS.md" | head -1)
  [[ $st =~ ^-\ Status:\ (approved|running) ]] || die "experiment $EXPN not approved/running ($st)"
  [ ! -e "$E" ] || die "$E exists (results are immutable; use the next --v)"
  [ -z "$(git -C "$TREE" status --porcelain --untracked-files=no)" ] || die "tree $TREE dirty"
fi
export OWNER EXPECT_K PRETOUCH_DIR L RUNS NODES="$IPS" VM_DOMAINS="$DOMS" EXPECT_RUNNING="$DOMS" BUILD=$ROCKS_BUILD \
  LOADGEN_BUILD=$ROCKS_LOADGEN_BUILD REGION EXPECT_DAX_UUID MIN_MEM_G EXPECT_NPROC RECV_MODE SLO_EXTRA="$ROCKS_SLO_EXTRA" \
  MEASURE=1 MEASURE_ENV_DIR MEASURE_PART_DIR GATE_SCRIPT=$TREE/scripts/host/h3-gate.sh
if [ $PHASE = hwpop ]; then export C8=$POP_C K8=$POP_K GT8=$POP_GT POP_BUNDLE_SHA
elif [ $PHASE = mg ]; then export MEG_CFG
else export DS_C DS_K DS_GT DS_BUNDLE_SHA DS_RECV_EXTRA="$DSRX"; fi
echo "RUNSET rocks conf=$CONF ($(sha256sum < "$CONF" | cut -c1-16)) block=$ROCKS_BLOCK N=$N phase=$PHASE topo=$ROCKS_TOPO E=$E"
[ "$PHASE" != ds ] || echo "RUNSET De Stijl receiver: recv_mode $RECV_MODE ${DSRX:-module defaults} ipoll ${RECV_IPOLL:-default} $(recv_wsm_desc)"
[ "$PHASE" != hwpop ] || echo "RUNSET Popcorn receiver: recv_mode ${POP_RECV_MODE:-$RECV_MODE}${POP_ADAPT_KO:+ module $POP_ADAPT_KO} ipoll ${RECV_IPOLL:-default} $(recv_wsm_desc)"
for x in POP_RECV_MODE POP_ADAPT_KO RECV_IPOLL RECV_WATCH_US RECV_S_MAX_US REQUIRE_SLEEP2050; do [ -z "${!x:-}" ] || export "$x"; done
if [ -n "$FX" ]; then  # receiver ablation: no SLO search arguments; the part plan for pilot-run.sh / part-hook.sh
  unset SLO_EXTRA
  export FIXED_SPEC="$FX" FIXED_RECVP="$FXR" FIXED_RECVP_BASE="$FXB"
  echo "RUNSET receiver ablation: fixed parts [$FX] receiver parameters [$FXR] base [$FXB] (no SLO search)"
fi
# run-2 pmax step (pilot-run.sh PMAX): ROCKS_PMAX 0 | 1; ROCKS_PMAX_FROM = rocks-results.tsv globs of the hwpop block
# (phase ds; {N} = this N, {V} = this block's evidence version, i.e. run j of ds reads run j of hwpop; relative = project
# root; later files win per row); ROCKS_PMAX_MEASURE_S (30) = the window
unset PMAX PMAX_FROM PMAX_MEASURE_S
case ${ROCKS_PMAX:-0} in
  0) [ -z "${ROCKS_PMAX_FROM:-}" ] || die "ROCKS_PMAX_FROM without ROCKS_PMAX=1";;
  1) [ -z "${ROCKS_PMAX_MEASURE_S:-}" ] || export PMAX_MEASURE_S=$ROCKS_PMAX_MEASURE_S
     PMF=""
     if [ "$PHASE" = ds ]; then
       for g in ${ROCKS_PMAX_FROM:-}; do
         g=${g//\{N\}/$N}; g=${g//\{V\}/$V}; g=$(abs "$g")
         for f in $g; do [ -f "$f" ] && PMF="$PMF $f"; done
       done
       export PMAX_FROM="${PMF# }"
     fi
     echo "RUNSET pmax step: pop / ds cells append one fixed window at Popcorn's max (pop: own slo part; ds: pop rows of [${PMF# }] from [${ROCKS_PMAX_FROM:-}])";;
  *) die "bad ROCKS_PMAX (0 | 1)";;
esac
echo "RUNSET cells:$NAMES"
if [ $DRY = 1 ]; then
  DRY=1 bash "$HERE/v1-block.sh" "$E"; rc=$?
  [ $rc = 0 ] && echo "RUNSET DRY PASS ($ROCKS_BLOCK n$N $PHASE)" || echo "RUNSET DRY FAIL ($ROCKS_BLOCK n$N $PHASE)"
  exit $rc
fi
mkdir -p "$E" || die "mkdir $E"
{ echo "# tasks-check $(date -Is) runset-rocks.sh $CONF $N $PHASE (caller pid $PPID)"; echo "experiment: $st"
  echo "lock: $(cat "$P/workspaces/MEASUREMENT.lock" 2>/dev/null || echo none)"
  echo "tree: $(git -C "$TREE" rev-parse HEAD) conf_sha256=$(sha256sum < "$CONF" | cut -c1-64)"; } > "$E/tasks-check.txt"
bash "$HERE/v1-block.sh" "$E" > "$E/block.out" 2>&1; rc=$?
tail -n 3 "$E/block.out"
RD=(); for n in $NAMES; do [ -d "$E/$n/loadgen" ] && RD+=("$E/$n"); done
if [ -n "$FX" ]; then  # receiver ablation: no SLO result (slo_result.py); the parts table is the chain's derive step
  for n in $NAMES; do [ -f "$E/$n/ladder-result.txt" ] && cat "$E/$n/ladder-result.txt"; done
  if grep -q "BLOCK DONE" "$E/block.log" 2>/dev/null && [ $rc = 0 ]; then echo "RUNSET DONE $E (fixed parts)"; exit 0; fi
  echo "RUNSET FAILED rc=$rc $E (block.log: $(grep -m1 'BLOCK STOP' "$E/block.log" 2>/dev/null))"; exit 1
fi
RRC=0 UNC=
if [ ${#RD[@]} -gt 0 ]; then
  python3 -I -B "$HERE/slo_result.py" --slo-ms "$ROCKS_SLO_MS" --vcpus "$EXPECT_NPROC" --out "$E/rocks-results.tsv" "${RD[@]}" \
    > /dev/null 2> "$E/rocks-results.err"; RRC=$?
  case $RRC in
    0) ;;
    3) UNC=$(awk -F'\t' '!/^#/ && $21 == "UNCONFIRMED" {printf "%s%s", s, $1; s=" "}' "$E/rocks-results.tsv")
       echo "RUNSET NOTE: unconfirmed cells (a result, not a failure): $UNC (see $E/rocks-results.err)";;
    *) echo "RUNSET NOTE: rocks-results has ERROR rows (rc $RRC, see $E/rocks-results.err)";;
  esac
  cut -f1,7,8,11,12,19,20,21 "$E/rocks-results.tsv"   # name, offered max, confirm x, max req/s, src, past knee, lag, check
fi
# rc: 0 = every cell confirmed; 3 = block done, every cell has a result row, some unconfirmed (WARN: the calling chain
# continues and counts the part as done); 1 = a real failure (block stop: crash, verify, server / protocol / error
# counter checks, ... or a result ERROR row); 2 = usage / environment stop before the block.
if grep -q "BLOCK DONE" "$E/block.log" 2>/dev/null && [ $rc = 0 ]; then
  case $RRC in
    0) echo "RUNSET DONE $E"; exit 0;;
    3) echo "RUNSET DONE-UNCONFIRMED $E ($UNC)"; exit 3;;
    *) echo "RUNSET FAILED result ERROR rows $E ($(head -c 300 "$E/rocks-results.err" | tr '\n' ';'))"; exit 1;;
  esac
fi
echo "RUNSET FAILED rc=$rc $E (block.log: $(grep -m1 'BLOCK STOP' "$E/block.log" 2>/dev/null))"; exit 1
