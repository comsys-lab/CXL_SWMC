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
#   POP_RECV_MODE    Popcorn lifetimes' cxl_shm recv_mode (default RECV_MODE; run 2: adaptive for ds AND pop)
#   POP_ADAPT_KO     signed adaptive cxl_shm.ko the Popcorn bundle installs (required for POP_RECV_MODE=adaptive;
#                    recv-mode.sh: sha256 = KO_SHA of the bundle's popcorn.env, srcversion checked on the guests)
#   RECV_IPOLL       0 | 1: adaptive idle pollers written after the enable (0 = pollers-off cell); unset = default 1
#   RECV_WATCH_US    adaptive watch_us (us, 1..1000000), written after the enable with ipoll; unset = default 200
#   RECV_S_MAX_US    adaptive s_max_us (us, s_min_us 50..1000000), written after the enable; unset = default 200
#                    (both: recv-mode.sh recv_wsm_check; adaptive pop / ds lifetimes only, refused for other modes)
#   (De Stijl fault-entry polling: fault_poll=0|1 in H2N_DS_RECV_EXTRA / RS_DS_RECV_EXTRA; build-9 bundles load 0)
unset REGISTRY LEVELS_SOURCE LEVELS_REGISTRY RS_PROC_CXL_SHM RUNSETS EVIDENCE_TAG EXPORT_SUFFIX
#   REQUIRE_SLEEP2050 1 = run-2 receiver guard (recv-mode.sh recv_run2_guard; passed to the blocks: the readback asserts
#                    recv_mode=sleep idle_spin_us 50 idle_sleep_us 20 for pop and ds)
unset POP_RECV_MODE POP_ADAPT_KO RECV_IPOLL RECV_WATCH_US RECV_S_MAX_US REQUIRE_SLEEP2050
unset RS_V7 RS_V7_IMAGE RS_V7_DENSE RS_V7_IMAGE_HOST RS_V7_DENSE_HOST RS_V7_LR RS_V7_ACC_INIT RS_V7_TRAIN_BATCH RS_V7_TRAIN_THREADS RS_V7_W_S \
  RS_V7_STALE_SAMPLE RS_V7_STALE_DIR RS_V7_SAMPLES RS_V7_FROZEN   # v7 keys come only from the conf
unset RS_PMAX RS_PMAX_FROM RS_PMAX_S RS_PMAX_SETTLE_S   # run-2 RecSys pmax step keys (rs_env), only from the conf
unset RS_AUC_Q RS_AUC_S RS_AUC_SETTLE_S RS_AUC_ONLY     # run-2 RecSys fixed-rate AUC lifetimes (rs_env), only from the conf
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
    [ "$WL" != recsys ] || echo "EVAL_RS_LEAN=${EVAL_RS_LEAN:-0} (1 = confirm probes capped at 3)"
  } > "$E/eval-manifest.txt"
}
# receiver keys of the conf for the blocks (recv-mode.sh): RECVENV = POP_RECV_MODE / POP_ADAPT_KO / RECV_IPOLL /
# RECV_WATCH_US / RECV_S_MAX_US assignments (only the set ones); recv_pop_check <N>: the Popcorn mode is allowed for
# POP_C (adaptive: POP_ADAPT_KO). The blocks refuse RECV_WATCH_US / RECV_S_MAX_US for a non-adaptive pop / ds lifetime.
. "$EVD/recv-mode.sh"
RECVENV=()
for _v in POP_RECV_MODE POP_ADAPT_KO RECV_IPOLL RECV_WATCH_US RECV_S_MAX_US REQUIRE_SLEEP2050; do [ -z "${!_v:-}" ] || RECVENV+=("$_v=${!_v}"); done
[[ ${RECV_IPOLL:-} =~ ^[01]?$ ]] || { echo "RUNSET STOP: bad RECV_IPOLL (${RECV_IPOLL})"; exit 2; }
_why=$(recv_wsm_check) || { echo "RUNSET STOP: $_why"; exit 2; }
[ -z "${RECV_WATCH_US:-}${RECV_S_MAX_US:-}" ] || plan "receiver: adaptive $(recv_wsm_desc) (RECV_WATCH_US / RECV_S_MAX_US, written after the enable, pop and ds)"
# run-2 guard (conf REQUIRE_SLEEP2050=1, earlier REQUIRE_ADAPTIVE=1; recv-mode.sh recv_run2_guard): a real run refuses placeholder receiver pins
if _why=$(recv_run2_guard); then
  if [ "${REQUIRE_SLEEP2050:-0}" = 1 ]; then plan "run-2 guard: sleep 20/50 receiver for pop and ds, POP_ADAPT_KO set: OK"
  elif [ "${REQUIRE_ADAPTIVE:-0}" != 0 ]; then plan "run-2 guard: adaptive receiver for pop and ds, POP_ADAPT_KO set: OK"; fi
elif [ $DRY = 1 ]; then plan "run-2 guard: $_why (a real run stops here)"
else die "run-2 guard: $_why"; fi
recv_pop_check() {  # <N>
  local why m=${POP_RECV_MODE:-$RECV_MODE}
  why=$(recv_rules pop "$m" "$POP_C" "$1") || die "Popcorn receiver: $why"
  plan "receiver: Popcorn recv_mode $m${POP_ADAPT_KO:+ module $POP_ADAPT_KO (srcversion $(recv_pop_srcversion))} ipoll ${RECV_IPOLL:-default} $(recv_wsm_desc)"
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
  [ ${#RECVENV[@]} = 0 ] || RSENV+=("${RECVENV[@]}")   # receiver keys (recv-mode.sh; main-block.sh checks them)
  # RS_SLO_MS 400 (user 2026-11-02, 4 vCPU): main-block.sh STREAM_SLO_MS; 100 = its built-in value (env unchanged)
  [ "$RS_SLO_MS" = 100 ] || RSENV+=(STREAM_SLO_MS=$RS_SLO_MS)
  # env EVAL_RS_LEAN=1 (eval3 schedule §1 cell-time cut, only when late): loadgen confirm probes capped at 3
  case ${EVAL_RS_LEAN:-0} in 0) ;; 1) RSENV+=(STREAM_CONFIRM_PROBES=3); plan "LEAN: confirm probes capped at 3 (EVAL_RS_LEAN=1)";;
    *) die "bad EVAL_RS_LEAN (${EVAL_RS_LEAN}: 0 or 1)";; esac
  plan "RecSys SLO query p$RS_SLO_PCT <= $RS_SLO_MS ms, max confirm probes $([ "${EVAL_RS_LEAN:-0}" = 1 ] && echo 3 || echo 6)"
  local v; for v in PRETOUCH_DIR MEASURE_ENV_DIR MEASURE_PART_DIR; do [ -z "${!v:-}" ] || RSENV+=("$v=${!v}"); done
  # RecSys v7 (RS_V7=1; workloads/recsys/DESIGN.md §10.6): RS_V7_<X> -> main-block.sh V7_<X>; @USER@ values = not
  # decided by the user (dry start plans with the server defaults, a real run stops in the block)
  case ${RS_V7:-0} in 0) ;; 1)
    RSENV+=(V7=1)
    for v in IMAGE DENSE IMAGE_HOST DENSE_HOST LR ACC_INIT TRAIN_BATCH TRAIN_THREADS W_S STALE_SAMPLE STALE_DIR SAMPLES FROZEN; do
      local c=RS_V7_$v; [ -n "${!c:-}" ] || die "RS_V7=1 needs $c in $EVAL_CONF"; RSENV+=("V7_$v=${!c}")
    done
    plan "RecSys v7: image ${RS_V7_IMAGE} dense ${RS_V7_DENSE} lr ${RS_V7_LR} acc_init ${RS_V7_ACC_INIT} batch ${RS_V7_TRAIN_BATCH} W ${RS_V7_W_S} s stale 1/${RS_V7_STALE_SAMPLE} rows";;
    *) die "bad RS_V7 (${RS_V7}: 0 or 1)";; esac
  # run-2 pmax step (main-block.sh STREAM_PMAX): RS_PMAX 0 | 1, RS_PMAX_FROM = stream-results.tsv globs of the rs-main
  # block whose pop rows a ds block uses ({RUN} = this run k; relative = project root), RS_PMAX_S / RS_PMAX_SETTLE_S
  case ${RS_PMAX:-0} in 0) [ -z "${RS_PMAX_FROM:-}" ] || die "RS_PMAX_FROM without RS_PMAX=1";;
    1) RSENV+=(STREAM_PMAX=1)
       for v in S SETTLE_S; do local c=RS_PMAX_$v; [ -z "${!c:-}" ] || RSENV+=("STREAM_PMAX_$v=${!c}"); done
       local g fs="" f
       for g in ${RS_PMAX_FROM:-}; do
         g=${g//\{RUN\}/$K}; case $g in /*) ;; *) g=$P/$g;; esac
         for f in $g; do [ -f "$f" ] && fs="$fs $f"; done
       done
       [ -z "$fs" ] || RSENV+=("STREAM_PMAX_FROM=${fs# }")
       plan "pmax step: pop / ds lifetimes append one fixed window at Popcorn's max under the SLO (pop: own slo row; ds: pop rows of [${fs# }] from [${RS_PMAX_FROM:-}])";;
    *) die "bad RS_PMAX (${RS_PMAX}: 0 or 1)";; esac
  # run-2 fixed-rate AUC lifetimes (T sweep, user 2026-11-05; main-block.sh STREAM_AUC): RS_AUC_Q "<rate>=<query/s> ..."
  # (one fixed query rate per update rate, shared by every system), RS_AUC_S / RS_AUC_SETTLE_S, RS_AUC_ONLY 0 | 1
  # (1 = no SLO lifetimes in the block, AUC lifetimes only)
  if [ -n "${RS_AUC_Q:-}" ]; then
    [ "${RS_V7:-0}" = 1 ] || die "RS_AUC_Q needs RS_V7=1"
    local m
    for m in $RS_AUC_Q; do
      [[ $m =~ ^[1-9][0-9]*=[0-9]+(\.[0-9]+)?$ ]] || die "bad RS_AUC_Q entry $m (<rate>=<query/s>)"
      [[ " $RS_POINTS " == *" ${m%%=*} "* ]] || die "RS_AUC_Q rate ${m%%=*} not in RS_POINTS"
    done
    [[ ${RS_AUC_S:-300} =~ ^[1-9][0-9]*$ && ${RS_AUC_SETTLE_S:-30} =~ ^[1-9][0-9]*$ && ${RS_AUC_ONLY:-0} =~ ^[01]$ ]] \
      || die "bad RS_AUC_S / RS_AUC_SETTLE_S / RS_AUC_ONLY"
    RSENV+=("STREAM_AUC=$RS_AUC_Q" STREAM_AUC_S=${RS_AUC_S:-300} STREAM_AUC_SETTLE_S=${RS_AUC_SETTLE_S:-30} STREAM_AUC_ONLY=${RS_AUC_ONLY:-0})
    plan "fixed-rate AUC lifetimes: [$RS_AUC_Q] (rate=query/s), warm-up as the SLO lifetimes, then ${RS_AUC_SETTLE_S:-30} s settle + 5 s + ${RS_AUC_S:-300} s measured, seed SEED + 3$([ "${RS_AUC_ONLY:-0}" = 1 ] && echo '; AUC lifetimes only (no SLO lifetime)')"
  elif [ -n "${RS_AUC_S:-}${RS_AUC_SETTLE_S:-}${RS_AUC_ONLY:-}" ]; then die "RS_AUC_S / RS_AUC_SETTLE_S / RS_AUC_ONLY without RS_AUC_Q"
  fi
}
# rs_check.py arguments of a RecSys block: AUCSYS (systems with AUC lifetimes; empty without RS_AUC_Q), SLOSYS (the SLO
# systems, empty with RS_AUC_ONLY=1) and AUCRATES (rates of RS_AUC_Q)
rs_auc_args() {  # <systems of the block>
  AUCSYS= AUCRATES= SLOSYS=$1
  [ -n "${RS_AUC_Q:-}" ] || return 0
  AUCSYS=$1 AUCRATES=$(for m in $RS_AUC_Q; do printf '%s ' "${m%%=*}"; done)
  AUCRATES=${AUCRATES% }
  [ "${RS_AUC_ONLY:-0}" = 0 ] || SLOSYS=
}
rs_checks() {  # static checks shared by the RecSys drivers
  case $RS_SLO_PCT:$RS_SLO_MS:$RS_RAMP_START in 95:100:1|95:400:1) ;;
    *) die "RecSys SLO / ramp start: BLOCK=stream takes query:95:100 or query:95:400 (STREAM_SLO_MS), start 1";; esac
  [ -z "$RS_LOW_RAMP_FACTOR" ] || die "RS_LOW_RAMP_FACTOR needs a loadgen option that does not exist yet (cut Q8; RUN.md)"
  need_files "$RS_PLAIN_BUILD/bin/recsys-server" "$RS_MEG_BUILD/bin/recsys-server" "$RS_LOADGEN" "$REGION" "$RS_MEG_CFG" \
    "$POP_C/p-popcorn-shm.sh" "$RS_INPUTS/MANIFEST.txt" "$TREE/experiments/recsys/main-block.sh"
  [ "$(sha256sum < "$POP_C/packet.sha256" | cut -c1-64)" = "$POP_BUNDLE_SHA" ] || die "Popcorn bundle packet.sha256 != POP_BUNDLE_SHA"
  grep -qx "megalon_build=$RS_MEGALON_BASE" "$RS_MEG_BUILD/manifest.txt" || die "$RS_MEG_BUILD is not on $RS_MEGALON_BASE"
  ring_check   # verifier L3: same check as runset-vdb.sh
  cmp -s "$RS_MEG_CFG" "$P/CXL_SWMC/systems/megalon/recsys-2vm.yaml" || die "main-block.sh prechecks systems/megalon/recsys-2vm.yaml: RS_MEG_CFG must be it"
  local app ring scr v7a=(--update-mode stream)
  # v7: the app layout comes from the image header (dim, fp16 records); the Host reads its copy (RS_V7_IMAGE_HOST)
  if [ "${RS_V7:-0}" = 1 ]; then
    need_files "${RS_V7_IMAGE_HOST:?RS_V7=1 needs RS_V7_IMAGE_HOST}" "${RS_V7_DENSE_HOST:?RS_V7=1 needs RS_V7_DENSE_HOST}"
    v7a=(--update-mode train --image "$RS_V7_IMAGE_HOST" --model-dense "$RS_V7_DENSE_HOST" --publish-ms 0)
  fi
  app=$("$RS_PLAIN_BUILD/bin/recsys-server" --nodes 2 --row-div 1 --serve-threads $RS_THREADS --update-threads 1 \
    --load-threads 8 --start-timeout-ms $((RS_XT * 500)) "${v7a[@]}" --print-app-bytes) || die "print-app-bytes"
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
        MEASURE_PART_DIR=${MEASURE_PART_DIR:-$RESULTS_ROOT} "${@//@DIR@/$t}" 2>&1)
  rm -rf "$t"
  # eval3: the block's L1 / pending lines are shown (h2n-block.sh H2N_L1, @MAIN_T@); the check uses the last 3 lines;
  # damon-policy-exploration: also the block's DAMON plan line (H2N_DS_DAMON_AT / _EXTRA / _WARMUP / _REGIONS);
  # run-2 §6: the fixed warmup plan line (H2N_WARMUP); RecSys De Stijl replica_mode (main-block.sh "PLAN: replica: ")
  # megalon-page-granularity: the block's "PLAN: megalon-page: " line (H2N_MG_SERVER_EXTRA / H2N_READY_TIMEOUT set only)
  # RecSys torn rows (user 2026-11-07): main-block.sh "PLAN: torn rows: " (ds lifetimes: allowed or zero-torn invariant)
  echo "$out" | grep -E '^BLOCK (PLAN: L1 |PLAN: DAMON |PLAN: pmax |PLAN: auc |PLAN: receiver|PLAN: fixed warmup |PLAN: replica: |PLAN: torn rows: |PLAN: megalon-page: |DRY NOTE|NOTE)' | while IFS= read -r l; do plan "block dry: $l"; done
  out=$(echo "$out" | tail -n 3)
  if [[ "$out" == *"$want"* ]]; then plan "block dry start reached its evidence-dir check: $(echo "$out" | grep -m1 "$want")"
  else die "block dry start did not reach the evidence-dir check: $out"; fi
}
export_run() {  # <export script> <evidence dir>: canonical CSVs into DERIVED_ROOT/<WL>/<RUNSET>/run<K>
  # (runset-vdb.sh EVAL_ONLY_POINTS: run<K>-only-<mixes>, so a partial rerun never replaces a whole run's export)
  local out=$DERIVED_ROOT/$WL/$RUNSET/run$K${EXPORT_SUFFIX:-}
  mkdir -p "$out" && python3 -I -B "$1" --run "$K" --runset "$RUNSET" --config-sha256 "$CSHA" --out "$out" "$2" > "$out/export.log" 2>&1 \
    && echo "export: $out" || echo "RUNSET NOTE: export failed (see $out/export.log; the run itself is unaffected)"
}
# De Stijl v2 in the H3 run sets (H3_SYSTEMS entry ds; the H3 equivalent of runset-h2n.sh H2N_DS_*). Conf keys
# H3_DS_C (bundle dir: p-destijl-shm.sh, packet.sha256), H3_DS_BUNDLE_SHA (sha256 of H3_DS_C/packet.sha256), H3_DS_K
# (guest release -ds-destijl-<n>), H3_DS_GT (guest tools dir), optional H3_DS_REGION (default
# config/cxl_region-destijl.yaml of this tree) and H3_DS_T_US (staleness bound T in us, default 0 = synchronous); the
# drivers unset them before this file is sourced (never inherited from the environment). Passed to h3-block.sh as
# DS_C DS_BUNDLE_SHA DS_K DS_GT DS_REGION H3_DS_T_US. pop and ds never share a block (different guest kernels); a
# T > 0 needs a server build that links libdestijl (de_stijl_set_staleness), else the servers would ignore T.
h3_ds_env() {  # <Host server binary of the block>: sets HASDS (0 | 1) and DSENV (env assignments for h3-block.sh)
  HASDS=0 DSENV=()
  [[ " $H3_SYSTEMS " == *" ds "* ]] || return 0
  HASDS=1
  [[ " $H3_SYSTEMS " != *" pop "* ]] || die "pop and ds need different guest kernels: run them in separate H3 blocks (confs)"
  local x dsc dsr t=${H3_DS_T_US:-0}
  for x in H3_DS_C H3_DS_K H3_DS_GT H3_DS_BUNDLE_SHA; do [ -n "${!x:-}" ] || die "ds needs $x in $EVAL_CONF"; done
  [[ $H3_DS_K == *-ds-destijl-* ]] || die "H3_DS_K=$H3_DS_K is not a De Stijl release (-ds-destijl-<n>)"
  [[ $t =~ ^(0|[1-9][0-9]*)$ ]] || die "bad H3_DS_T_US ($t: integer us, 0 = synchronous)"
  dsc=$H3_DS_C dsr=${H3_DS_REGION:-$TREE/config/cxl_region-destijl.yaml}
  need_files "$dsc/p-destijl-shm.sh" "$dsc/packet.sha256" "$dsr"
  x=$(recv_rules ds "$RECV_MODE" "$dsc" "${H3_N:-2}") || die "De Stijl receiver: $x"
  [ "$(sha256sum < "$dsc/packet.sha256" | cut -c1-64)" = "$H3_DS_BUNDLE_SHA" ] || die "De Stijl bundle packet.sha256 != H3_DS_BUNDLE_SHA"
  [ "$t" = 0 ] || grep -qa de_stijl_set_staleness "$1" || die "H3_DS_T_US=$t needs a server build with libdestijl ($1 has none)"
  DSENV=(DS_C=$dsc DS_K=$H3_DS_K DS_GT=$H3_DS_GT DS_BUNDLE_SHA=$H3_DS_BUNDLE_SHA DS_REGION=$dsr H3_DS_T_US=$t)
  plan "De Stijl: bundle $dsc release $H3_DS_K guest tools $H3_DS_GT region $dsr T=$t us recv_mode $RECV_MODE"
}
