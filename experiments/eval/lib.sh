# Shared functions of the evaluation run-set drivers (runset-vdb.sh, runset-rs-main.sh, runset-rs-h1.sh); sourced.
# Caller sets RUNSET (vdb | rs-main | rs-h1) and WL (vdb | recsys) before sourcing, and passes "$@".
# usage of every driver: runset-<x>.sh <k> [--dry] [--v <N>]
#   k      run number 1..RUNS (eval.conf)
#   --dry  Host-only dry start: every check up to the evidence-dir check, prints the plan and the block command, then
#          exits 0 before the lock (no VM contact, nothing written outside stdout)
#   --v N  evidence version (default: the lowest N whose dir does not exist)
# Real runs: only from the live tree /home/comsys/sungsu/destijl-control/CXL_SWMC (the blocks call its scripts by
# absolute path), clean (git status --porcelain --untracked-files=no empty), launched as
# `setsid nohup bash CXL_SWMC/experiments/eval/runset-<x>.sh <k> > <log> 2>&1 &` (see RUN.md); needs PRETOUCH_DIR,
# MEASURE_ENV_DIR, MEASURE_PART_DIR (current QEMU lifetime's pretouch evidence and Host measurement dirs).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
EVD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE=$(cd "$EVD/../.." && pwd)
# env EVAL_CONF (optional): another config file with the same keys (e.g. recv-sleep.conf; default eval.conf next to
# this file). Optional keys, absent in eval.conf (never inherited from the environment):
#   REGISTRY         [run] runs.tsv the run set registers in (registry.py EVAL_REGISTRY; default the eval registry)
#   LEVELS_SOURCE    registry = the fixed-load levels of EVERY run k (also k = LEVELS_FROM_RUN) come from the accepted
#                    run LEVELS_FROM_RUN of the same run set name in LEVELS_REGISTRY (another experiment's registry);
#                    empty = as before (run LEVELS_FROM_RUN of this registry, run LEVELS_FROM_RUN computes its own)
#   LEVELS_REGISTRY  runs.tsv read for LEVELS_SOURCE=registry
#   RS_PROC_CXL_SHM  1 = RecSys servers also snapshot /sys/kernel/cxl_shm per step (sleep_wakeups, tick_kicks)
#   RUNSETS          [run] the run sets this config may drive (others refuse it); empty = all
#   EVIDENCE_TAG     [run] evidence dir tag instead of the run set name (evidence_dir; e.g. h1-u10u95.conf vdb-u10u95);
#                    a driver that sets its own EVIDENCE_TAG after sourcing this file (runset-h2n.sh) overrides it
unset REGISTRY LEVELS_SOURCE LEVELS_REGISTRY RS_PROC_CXL_SHM RUNSETS EVIDENCE_TAG EXPORT_SUFFIX
CONFSH=$(python3 -I -B "$EVD/evalconf.py" shell ${EVAL_CONF:+--conf "$EVAL_CONF"}) || { echo "RUNSET STOP: ${EVAL_CONF:-eval.conf} does not parse"; exit 2; }
eval "$CONFSH"
export EVAL_CONF   # absolute path of the config (evalconf.py shell); pins-vdb.sh (sourced by the hook) reads the same file
die() { echo "RUNSET STOP ($RUNSET): $*"; exit 2; }
[ -z "${RUNSETS:-}" ] || [[ " $RUNSETS " == *" $RUNSET "* ]] || die "$EVAL_CONF is for the run sets [$RUNSETS] only"
K=${1:-}; shift || true
DRY=0 VER=
while [ $# -gt 0 ]; do
  case $1 in --dry) DRY=1; shift;; --v) VER=${2:-}; shift 2;; *) die "unknown argument $1";; esac
done
[[ $K =~ ^[1-9]$ ]] && [ "$K" -le "$RUNS" ] || die "run number k must be 1..RUNS=$RUNS (got '$K')"
[ -z "$VER" ] || [[ $VER =~ ^[1-9][0-9]*$ ]] || die "bad --v"
case $WL in vdb) CSHA=$CONFIG_SHA256_VDB;; recsys) CSHA=$CONFIG_SHA256_RECSYS;; *) die "bad WL";; esac
# H3 drivers (runset-h3-*.sh) set CONF_WL=h3-vdb | h3-recsys: config_sha256 and the manifest dump over WL + H3_* keys
case ${CONF_WL:-} in "") CONF_WL=$WL;; h3-vdb) CSHA=$CONFIG_SHA256_H3_VDB;; h3-recsys) CSHA=$CONFIG_SHA256_H3_RECSYS;;
  h2n) CSHA=$CONFIG_SHA256_H2N;; *) die "bad CONF_WL";; esac
REG="python3 -I -B $EVD/registry.py"
[ -z "${REGISTRY:-}" ] || REG="env EVAL_REGISTRY=$REGISTRY $REG"
plan() { echo "PLAN ($RUNSET run $K): $*"; }
[ "$EVAL_CONF" = "$EVD/eval.conf" ] || plan "config $EVAL_CONF (sha256 $EVAL_CONF_SHA256) config_sha256 $CSHA"
[ -z "${REGISTRY:-}" ] || plan "registry $REGISTRY"
case ${LEVELS_SOURCE:-} in
  "") ;;
  registry) [ -f "${LEVELS_REGISTRY:-}" ] || die "LEVELS_SOURCE=registry needs an existing LEVELS_REGISTRY"
            [ "$LEVELS_REGISTRY" != "${REGISTRY:-}" ] || die "LEVELS_REGISTRY must be another registry than REGISTRY";;
  *) die "bad LEVELS_SOURCE ($LEVELS_SOURCE)";;
esac
# the code tree: real runs need the clean live tree; a dry start may run in a worktree and reports the difference
if [ "$TREE" != "$P/CXL_SWMC" ]; then
  [ $DRY = 1 ] || die "real runs only from the live tree $P/CXL_SWMC (this is $TREE; merge first)"
  plan "code tree $TREE (worktree; a real run uses $P/CXL_SWMC after the merge)"
fi
COMMIT=$(git -C "$TREE" rev-parse HEAD) DIRTY=$(git -C "$TREE" status --porcelain --untracked-files=no | wc -l)
DIFFSHA=$(git -C "$TREE" diff HEAD | sha256sum | cut -c1-64)
[ $DRY = 1 ] || [ "$DIRTY" = 0 ] || die "$TREE is dirty ($DIRTY files)"
need_files() { local f; for f in "$@"; do [ -e "$f" ] || die "missing $f"; done; }
need_env() {  # PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR
  local v
  for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do
    if [ -d "${!v:-}" ]; then plan "$v=${!v}"
    elif [ $DRY = 1 ]; then plan "$v not set (required for the real run)"
    else die "$v must name an existing dir"; fi
  done
}
lock_free() {
  if [ -e "$P/workspaces/MEASUREMENT.lock" ]; then
    [ $DRY = 1 ] || die "workspaces/MEASUREMENT.lock exists ($(cat "$P/workspaces/MEASUREMENT.lock"))"
    plan "MEASUREMENT.lock is held now ($(cat "$P/workspaces/MEASUREMENT.lock")): the real run would stop here"
  fi
}
# evidence dir: <RESULTS_ROOT>/<prefix>-run<k>-<tag>-v<N>, tag = EVIDENCE_TAG if the run set or the config sets it, else <runset>
evidence_dir() {
  local n=${VER:-1} tag=${EVIDENCE_TAG:-$RUNSET}
  if [ -z "$VER" ]; then while [ -e "$RESULTS_ROOT/$EVIDENCE_PREFIX-run$K-$tag-v$n" ]; do n=$((n + 1)); done; fi
  E=$RESULTS_ROOT/$EVIDENCE_PREFIX-run$K-$tag-v$n
  [ ! -e "$E" ] || die "$E exists (evidence dirs are immutable; a failed attempt bumps v<N>)"
  plan "evidence dir $E (absent: OK)"
}
# accepted (or, with a second argument, measured) evidence dir of run j of a run set
run_dir_of() {  # <runset> <j> [status]
  local x
  x=$($REG get "$1" "$2" ${3:+--status $3}) || return 1
  echo "${x% *}"
}
# evidence dir the fixed-load levels of this run come from (accepted run LEVELS_FROM_RUN); LEVELS_SOURCE=registry:
# that run in LEVELS_REGISTRY (also for k = LEVELS_FROM_RUN), else run_dir_of in this run set's registry
levels_dir_of() {  # <runset>: sets LEVELS_SRC_DIR (and LEVELS_SRC_SHA = its config_sha256); 1 = no accepted run
  local x
  LEVELS_SRC_DIR= LEVELS_SRC_SHA=
  if [ "${LEVELS_SOURCE:-}" = registry ]; then
    x=$(EVAL_REGISTRY=$LEVELS_REGISTRY python3 -I -B "$EVD/registry.py" get "$1" "$LEVELS_FROM_RUN") || return 1
  else x=$($REG get "$1" "$LEVELS_FROM_RUN") || return 1; fi
  LEVELS_SRC_DIR=${x% *} LEVELS_SRC_SHA=${x##* }
}
manifest() {  # written into E at the real start
  { echo "# evaluation run-set manifest (experiments/eval/lib.sh)"
    echo "runset=$RUNSET workload=$WL run=$K evidence=$E start=$(date -Is) pid=$$"
    echo "code_tree=$TREE commit=$COMMIT dirty_files=$DIRTY dirty_diff_sha256=$DIFFSHA"
    echo "eval_conf=$EVAL_CONF sha256=$EVAL_CONF_SHA256 config_sha256=$CSHA"
    python3 -I -B "$EVD/evalconf.py" dump "$CONF_WL" --conf "$EVAL_CONF" | sed 's/^/conf: /'
    python3 -I -B "$EVD/evalconf.py" later --conf "$EVAL_CONF" | sed 's/^/later: /'
    [ -z "${REGISTRY:-}" ] || echo "registry=$REGISTRY"
    [ -z "${ONLY_POINTS:-}" ] || echo "only_points=$VDB_POINTS (env EVAL_ONLY_POINTS; conf points ${CONF_POINTS:-})"
    [ -z "${LEVELS_SOURCE:-}" ] || echo "levels_source=$LEVELS_SOURCE registry=$LEVELS_REGISTRY run=$LEVELS_FROM_RUN dir=${LEVELS_SRC_DIR:-} config_sha256=${LEVELS_SRC_SHA:-}"
    local b
    for b in "$@"; do
      [ -f "$b/manifest.txt" ] && echo "build $b manifest_sha256=$(sha256sum < "$b/manifest.txt" | cut -c1-64) $(grep -m1 '^source_commit=' "$b/manifest.txt")"
      find "$b" -maxdepth 2 -type f \( -path '*/bin/*' -o -path '*/lib/*' -o -name loadgen \) -printf '%p\n' 2>/dev/null | sort | while read -r f; do echo "artifact $(sha256sum "$f")"; done
    done
    echo "region $(sha256sum "$REGION")"
    echo "popcorn bundle $POP_C packet_sha256=$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64) (expected $POP_BUNDLE_SHA)"
    echo "PRETOUCH_DIR=${PRETOUCH_DIR:-} MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-} MEASURE_PART_DIR=${MEASURE_PART_DIR:-}"
  } > "$E/eval-manifest.txt"
}
ring_check() {  # REGION's msg_ring must equal the Popcorn bundle's region (cxl_shm module parameters come from it)
  [ "$(grep -E '^msg_ring:' "$REGION" | cut -d'#' -f1 | tr -d ' ')" = "$(grep -E '^msg_ring:' "$POP_C/tools/cxl_region.yaml" | cut -d'#' -f1 | tr -d ' ')" ] \
    || die "REGION msg_ring differs from the Popcorn bundle's region"
  cmp -s "$REGION" "$POP_C/tools/cxl_region.yaml" || plan "note: REGION and the bundle region differ outside msg_ring"
}
# RecSys: environment of experiments/recsys/main-block.sh BLOCK=stream with EVAL_RUN (both RecSys run sets)
rs_env() {
  RSENV=(BLOCK=stream EVAL_RUN=$K RS_THREADS=$RS_THREADS REGION=$REGION C8=$POP_C K8=$POP_K GT8=$POP_GT
    RECV_MODE=$RECV_MODE POP_BUILD=$POP_BUILD POP_BUNDLE_SHA=$POP_BUNDLE_SHA D=$RS_INPUTS VM_PLAIN=$RS_VM_PLAIN
    VM_MEG=$RS_VM_MEG MEG_BUILD=$RS_MEG_BUILD MEGALON_BASE=$RS_MEGALON_BASE PLAIN_BUILD=$RS_PLAIN_BUILD
    LOADGEN=$RS_LOADGEN SEED=$((SEED_BASE + K)) XT=$RS_XT MG_RPO_OPT=$RS_MG_RPO_OPT MG_TABLE_N=$RS_MG_TABLE_N
    MG_COH_SAMPLE=$RS_MG_COH_SAMPLE EXPECT_DAX_UUID=$EXPECT_DAX_UUID STREAM_FIX_S=$RS_FIX_S
    STREAM_FIX_SETTLE_S=$RS_FIX_SETTLE_S H1_MEASURE_RUN=1)
  [ -z "${RS_PROC_CXL_SHM:-}" ] || RSENV+=(STREAM_PROC_CXL_SHM=$RS_PROC_CXL_SHM)
  local v; for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!v:-}" ] || RSENV+=("$v=${!v}"); done
}
rs_checks() {  # static checks shared by the RecSys drivers
  [ "$RS_SLO_PCT:$RS_SLO_MS:$RS_RAMP_START" = 95:100:1 ] || die "RecSys SLO / ramp start are fixed in BLOCK=stream (query:95:100, start 1)"
  [ -z "$RS_LOW_RAMP_FACTOR" ] || die "RS_LOW_RAMP_FACTOR needs a loadgen option that does not exist yet (cut Q8; RUN.md)"
  need_files "$RS_PLAIN_BUILD/bin/recsys-server" "$RS_MEG_BUILD/bin/recsys-server" "$RS_LOADGEN" "$REGION" "$RS_MEG_CFG" \
    "$POP_C/p-popcorn-shm.sh" "$RS_INPUTS/MANIFEST.txt" "$TREE/experiments/recsys/main-block.sh"
  [ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
  grep -qx "megalon_build=$RS_MEGALON_BASE" "$RS_MEG_BUILD/manifest.txt" || die "$RS_MEG_BUILD is not on $RS_MEGALON_BASE"
  ring_check   # verifier L3: same check as runset-vdb.sh
  cmp -s "$RS_MEG_CFG" "$P/CXL_SWMC/systems/megalon/recsys-2vm.yaml" || die "main-block.sh prechecks systems/megalon/recsys-2vm.yaml: RS_MEG_CFG must be it"
  local app ring scr
  app=$("$RS_PLAIN_BUILD/bin/recsys-server" --nodes 2 --row-div 1 --serve-threads $RS_THREADS --update-threads 1 \
    --load-threads 8 --start-timeout-ms $((RS_XT * 500)) --update-mode stream --print-app-bytes) || die "print-app-bytes"
  ring=$(grep -E '^msg_ring:' "$REGION" | sed 's/.*,[[:space:]]*\([0-9]*\)\].*/\1/')
  scr=$(sed -n 's/^logical_scr_size: *\([0-9]*\)MB.*/\1/p' "$RS_MEG_CFG"); scr=$((scr * 1048576 + 14848))
  plan "app HWcc $app B + ring $ring B; Megalon SCR footprint $scr B <= hwcc - ring - app = $((268435456 - ring - app)) B"
  [ $scr -le $((268435456 - ring - app)) ] || die "Megalon SCR does not fit the HWcc budget with this ring"
}
# dry start of the block itself: run it on a non-empty scratch dir, so that it passes every check it makes before its
# evidence-dir check and stops there (before any lock, VM contact or write); <expected stop text> <cmd...> (last arg =
# the dir placeholder @DIR@)
block_dry() {
  local want=$1 t out; shift
  t=$(mktemp -d /tmp/eval-dry-XXXXXX) && touch "$t/not-empty" || die "mktemp"
  # unset gate dirs: an existing placeholder dir (the block only tests -d before its evidence-dir check)
  out=$(env PRETOUCH_DIR=${PRETOUCH_DIR:-$RESULTS_ROOT} MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-$RESULTS_ROOT} \
        MEASURE_PART_DIR=${MEASURE_PART_DIR:-$RESULTS_ROOT} "${@//@DIR@/$t}" 2>&1 | tail -n 3)
  rm -rf "$t"
  if [[ "$out" == *"$want"* ]]; then plan "block dry start reached its evidence-dir check: $(echo "$out" | grep -m1 "$want")"
  else die "block dry start did not reach the evidence-dir check: $out"; fi
}
export_run() {  # <export script> <evidence dir>: canonical CSVs into DERIVED_ROOT/<WL>/<RUNSET>/run<K>
  # (runset-vdb.sh EVAL_ONLY_POINTS: run<K>-only-<mixes>, so a partial rerun never replaces a whole run's export)
  local out=$DERIVED_ROOT/$WL/$RUNSET/run$K${EXPORT_SUFFIX:-}
  mkdir -p "$out" && python3 -I -B "$1" --run "$K" --runset "$RUNSET" --config-sha256 "$CSHA" --out "$out" "$2" > "$out/export.log" 2>&1 \
    && echo "export: $out" || echo "RUNSET NOTE: export failed (see $out/export.log; the run itself is unaffected)"
}
