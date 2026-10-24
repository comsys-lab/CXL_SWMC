# shellcheck shell=bash
# Common library of artifact/figures/fig<N>.sh and stages/*.sh (sourced, not run). See README.md.
#
# Paths (environment overrides; resolved by af_resolve):
#   DESTIJL_ROOT    control root holding workspaces/ and recovery/ (default: the first parent of this repo that has
#                   workspaces/eval2-derived, e.g. /home/comsys/sungsu/destijl-control)
#   EVAL2_DERIVED   derived root of the eval2 runs [$DESTIJL_ROOT/workspaces/eval2-derived] (= DERIVED_ROOT of
#                   experiments/eval/eval2-h1.conf / eval2-h2.conf without the /h1, /h2 suffix): per run k
#                   h1/vdb/vdb/run<k>-chain/{slo_summary,fixed}.csv, h2/vdb/h2n/run<k>/{summary,steps,fig8}.csv
#   KNEE_DERIVED    knee-sweep exports [$DESTIJL_ROOT/workspaces/knee-sweep/derived]: <group>/knee-pilot.csv
#   KNEE_PLAN       knee-sweep plan [<repo>/experiments/eval/knee-sweep-plan.csv]
#   EVIDENCE_ROOT   raw evidence root [$DESTIJL_ROOT/recovery] (knee-sweep re-export only; the eval2 exports carry
#                   absolute source_dir paths, rewritten with --evidence-map OLD=NEW when the evidence moved)
#   MEASURE_TREE    code tree the measurement chains run [$DESTIJL_ROOT/CXL_SWMC] (the live tree; chains refuse others)
#   RUNS123_CHAIN   [$DESTIJL_ROOT/workspaces/runs123/run-chain-v1.sh]  eval2 run chain (H1 part)
#   H2N_CHAIN       [$DESTIJL_ROOT/workspaces/runs123/h2n-chain-v4.sh]  eval2 H2 chain (VM8 topology)
#   KNEE_CHAIN_V1   [$DESTIJL_ROOT/workspaces/knee-sweep-chain-v1.sh]   knee sweep (H1 + H2 N = 2/4/8)
#   KNEE_CHAIN_V2   [$DESTIJL_ROOT/workspaces/knee-sweep-chain-v2.sh]   knee-sweep addendum (Popcorn H2 u90 N = 4/8)
#   ARTIFACT_PY     python command [nice -n 19 numactl --cpunodebind=1 --membind=1 python3 -I -B, without numactl
#                   when it is missing]
# Options of every fig<N>.sh (af_main):
#   --reprocess        plot from existing exports (default)
#   --reexport         first re-run the exporters over the raw evidence behind the exports (into <out>/derived), then
#                      plot from those (checks that evidence -> CSV is reproducible; read only on the evidence)
#   --measure          run the missing measurement stages (stages/*.sh; shared by several figures, each skips runs whose
#                      exports exist), then plot. Main session only: VMs, sudo and the CXL device are used by the chains.
#   --redo             with --measure: measure every requested run again (new evidence versions) even if exports exist
#   --runs N           runs 1..N (default 3); seeds SEED_BASE + k from the confs (eval2-h1.conf, eval2-h2.conf)
#   --data DIR         EVAL2_DERIVED=DIR (and KNEE_DERIVED=DIR/knee-sweep when that exists)
#   --knee DIR | --plan CSV | --evidence-map OLD=NEW (repeatable)
#   --out DIR          output dir [$PWD/artifact-figures-out]
#   --dry-run          print every command, run nothing, write nothing

AF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AF_REPO=$(cd "$AF_DIR/../.." && pwd)
AF_PLOT=$AF_DIR/plot
AF_STAGES=$AF_DIR/stages
KNEE_MAIN_GROUPS="knee-sweep-h1 knee-sweep-h2-n2 knee-sweep-h2-n4 knee-sweep-h2-n8"
KNEE_ADD_GROUPS="knee-sweep-h2-n4-v2 knee-sweep-h2-n8-v2"

af_say() { echo "[$(basename "${AF_SELF:-$0}")] $*"; }
af_die() { echo "[$(basename "${AF_SELF:-$0}")] STOP: $*" >&2; exit 2; }

af_resolve() {
  if [ -z "${DESTIJL_ROOT:-}" ]; then
    local d=$AF_REPO
    while [ "$d" != / ]; do
      d=$(dirname "$d")
      if [ -d "$d/workspaces/eval2-derived" ]; then DESTIJL_ROOT=$d; break; fi
    done
  fi
  DESTIJL_ROOT=${DESTIJL_ROOT:-}
  local R=${DESTIJL_ROOT:-/nonexistent-DESTIJL_ROOT}
  EVAL2_DERIVED=${EVAL2_DERIVED:-$R/workspaces/eval2-derived}
  KNEE_DERIVED=${KNEE_DERIVED:-$R/workspaces/knee-sweep/derived}
  KNEE_PLAN=${KNEE_PLAN:-$AF_REPO/experiments/eval/knee-sweep-plan.csv}
  EVIDENCE_ROOT=${EVIDENCE_ROOT:-$R/recovery}
  MEASURE_TREE=${MEASURE_TREE:-$R/CXL_SWMC}
  RUNS123_CHAIN=${RUNS123_CHAIN:-$R/workspaces/runs123/run-chain-v1.sh}
  H2N_CHAIN=${H2N_CHAIN:-$R/workspaces/runs123/h2n-chain-v4.sh}
  KNEE_CHAIN_V1=${KNEE_CHAIN_V1:-$R/workspaces/knee-sweep-chain-v1.sh}
  KNEE_CHAIN_V2=${KNEE_CHAIN_V2:-$R/workspaces/knee-sweep-chain-v2.sh}
  if [ -z "${ARTIFACT_PY:-}" ]; then
    if command -v numactl > /dev/null 2>&1; then ARTIFACT_PY="nice -n 19 numactl --cpunodebind=1 --membind=1 python3 -I -B"
    else ARTIFACT_PY="nice -n 19 python3 -I -B"; fi
  fi
}

# af_run CMD...: print (always) and run (unless dry-run)
af_run() {
  printf '+ %s\n' "$(printf '%q ' "$@")"
  [ "${AF_DRY:-0}" = 1 ] || "$@"
}

af_runs() { seq 1 "$AF_NRUNS"; }

# ---------------------------------------------------------------- data presence per part and run
af_have_h1() { [ -s "$EVAL2_DERIVED/h1/vdb/vdb/run$1-chain/slo_summary.csv" ] && [ -s "$EVAL2_DERIVED/h1/vdb/vdb/run$1-chain/fixed.csv" ]; }
af_have_h2() { local d=$EVAL2_DERIVED/h2/vdb/h2n/run$1; [ -s "$d/summary.csv" ] && [ -s "$d/steps.csv" ] && [ -s "$d/fig8.csv" ]; }
af_have_knee() {  # [main|addendum|h1]
  local g gs
  case ${1:-all} in h1) gs=knee-sweep-h1;; main) gs=$KNEE_MAIN_GROUPS;; addendum) gs=$KNEE_ADD_GROUPS;;
    *) gs="$KNEE_MAIN_GROUPS $KNEE_ADD_GROUPS";; esac
  for g in $gs; do [ -s "$KNEE_DERIVED/$g/knee-pilot.csv" ] || return 1; done
  [ -s "$KNEE_PLAN" ]
}
af_missing() {  # list of missing inputs of the parts in $AF_NEEDS
  local p k
  for p in $AF_NEEDS; do
    case $p in
      h1) for k in $(af_runs); do af_have_h1 "$k" || echo "h1 run $k ($EVAL2_DERIVED/h1/vdb/vdb/run$k-chain)"; done;;
      h2) for k in $(af_runs); do af_have_h2 "$k" || echo "h2 run $k ($EVAL2_DERIVED/h2/vdb/h2n/run$k)"; done;;
      knee-h1) af_have_knee h1 || echo "knee sweep H1 ($KNEE_DERIVED/knee-sweep-h1, plan $KNEE_PLAN)";;
      knee) af_have_knee all || echo "knee sweep H1+H2+addendum ($KNEE_DERIVED/{${KNEE_MAIN_GROUPS// /,},${KNEE_ADD_GROUPS// /,}})";;
    esac
  done
}

# ---------------------------------------------------------------- re-export (evidence -> CSVs) into $AF_OUT/derived
af_emap_args() { local m; for m in "${AF_EMAP[@]}"; do printf '%s\n' --map "$m"; done; }
af_reexport_h1() {  # run k
  local k=$1 src=$EVAL2_DERIVED/h1/vdb/vdb/run$1-chain out=$AF_OUT/derived/h1/vdb/vdb/run$1-chain ds sha
  mapfile -t ds < <($ARTIFACT_PY "$AF_PLOT/evidence_dirs.py" $(af_emap_args) h1 "$src")
  [ ${#ds[@]} -gt 0 ] || af_die "no evidence dirs in $src/slo_summary.csv"
  sha=$($ARTIFACT_PY "$AF_PLOT/evidence_dirs.py" sha "${ds[0]}")
  [ "${AF_DRY:-0}" = 1 ] || mkdir -p "$out"
  af_run $ARTIFACT_PY "$AF_REPO/experiments/vectordb/export.py" --run "$k" --runset vdb --config-sha256 "$sha" --out "$out" "${ds[@]}"
}
af_reexport_h2() {  # run k: per N every evidence version with results (as h2n-chain-v4.sh export), then --combine
  local k=$1 src=$EVAL2_DERIVED/h2/vdb/h2n/run$1 n e ds outs=() sha=
  for n in 2 4 8; do
    ds=()
    while read -r e; do
      local g
      for g in "${e%-v*}"-v*; do
        if [ -s "$g/block/h2n-results.tsv" ] && [ "$(grep -vc '^#' "$g/block/h2n-results.tsv")" -gt 0 ]; then
          ds+=("$g/block")
        fi
      done
    done < <($ARTIFACT_PY "$AF_PLOT/evidence_dirs.py" $(af_emap_args) h2 "$src" "$n")
    [ ${#ds[@]} -gt 0 ] || af_die "run $k N=$n: no evidence with results"
    mapfile -t ds < <(printf '%s\n' "${ds[@]}" | sort -uV)
    sha=$($ARTIFACT_PY "$AF_PLOT/evidence_dirs.py" sha "${ds[0]%/block}")
    local o=$AF_OUT/derived/h2/vdb/h2n-n$n/run$k-all
    [ "${AF_DRY:-0}" = 1 ] || mkdir -p "$o"
    af_run $ARTIFACT_PY "$AF_REPO/experiments/eval/export_h2n.py" --run "$k" --nodes "$n" --config-sha256 "$sha" --out "$o" "${ds[@]}"
    outs+=("$o")
  done
  af_run $ARTIFACT_PY "$AF_REPO/experiments/eval/export_h2n.py" --combine --out "$AF_OUT/derived/h2/vdb/h2n/run$k" "${outs[@]}"
}
af_reexport_knee() {  # [h1|all]
  local g gs ds e
  if [ "${1:-all}" = h1 ]; then gs=knee-sweep-h1; else gs="$KNEE_MAIN_GROUPS $KNEE_ADD_GROUPS"; fi
  for g in $gs; do
    ds=()
    while read -r e; do ds+=("$EVIDENCE_ROOT/$e"); done < <($ARTIFACT_PY "$AF_PLOT/evidence_dirs.py" knee "$KNEE_DERIVED/$g/knee-pilot.csv")
    [ "${AF_DRY:-0}" = 1 ] || mkdir -p "$AF_OUT/derived/knee-sweep/$g"
    af_run $ARTIFACT_PY "$AF_REPO/experiments/eval/knee_pilot_export.py" "${ds[@]}" --out "$AF_OUT/derived/knee-sweep/$g"
  done
}

# ---------------------------------------------------------------- plot
af_plot() {
  local eval2=$EVAL2_DERIVED knee=$KNEE_DERIVED m args=()
  if [ "$AF_REEXPORT" = 1 ]; then eval2=$AF_OUT/derived; knee=$AF_OUT/derived/knee-sweep; fi
  for m in "${AF_EMAP[@]}"; do args+=(--evidence-map "$m"); done
  if [ "$AF_REEXPORT" = 1 ]; then args=(); fi  # re-exported source_dirs already point at the mapped evidence
  [ "${AF_DRY:-0}" = 1 ] || mkdir -p "$AF_OUT"
  # shellcheck disable=SC2046
  af_run $ARTIFACT_PY "$AF_PLOT/final.py" --out "$AF_OUT" --runs $(af_runs) --figs "$AF_FIG" --eval2 "$eval2" \
    --knee "$knee" --plan "$KNEE_PLAN" "${args[@]}"
}

af_manifest() {  # <out>/<fig>.manifest.txt: code commit, inputs, sha256 of every output of the figure
  local mf=$AF_OUT/$AF_FIG.manifest.txt commit dirty f pat=$AF_FIG
  [ "$AF_FIG" != all ] || pat="fig[0-9]"
  commit=$(git -C "$AF_REPO" rev-parse HEAD 2>/dev/null || echo unknown)
  dirty=$(git -C "$AF_REPO" diff HEAD -- artifact/figures 2>/dev/null | sha256sum | cut -c1-16)
  {
    echo "figure=$AF_FIG runs=$(af_runs | tr '\n' ' ')mode=$AF_MODE reexport=$AF_REEXPORT date=$(date -Is)"
    echo "code=$AF_REPO commit=$commit artifact_diff_sha256_16=$dirty"
    echo "eval2_derived=$EVAL2_DERIVED knee_derived=$KNEE_DERIVED knee_plan=$KNEE_PLAN evidence_map=${AF_EMAP[*]:-none}"
    for f in "$AF_OUT"/$pat[-a-z]*.csv "$AF_OUT"/$pat[-a-z]*.pdf "$AF_OUT"/$pat[-a-z]*.png; do
      if [ -f "$f" ]; then echo "$(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"; fi
    done
  } > "$mf"
  af_say "outputs: $(cd "$AF_OUT" && ls $pat[-a-z]*.{csv,pdf} 2>/dev/null | tr '\n' ' ')"
  af_say "manifest: $mf"
}

# ---------------------------------------------------------------- stages (measure)
af_stage() {  # <stage> : stages/<stage>.sh with the common options
  local a=(--runs "$AF_NRUNS")
  [ "${AF_DRY:-0}" = 1 ] && a+=(--dry-run)
  [ "$AF_REDO" = 1 ] && a+=(--redo)
  echo "== stage $1 (stages/$1.sh; shared with: $2)"
  bash "$AF_STAGES/$1.sh" "${a[@]}" || af_die "stage $1 failed (rc $?)"
}

# ---------------------------------------------------------------- stage scripts (stages/*.sh)
af_stage_parse() {  # --runs N --dry-run --redo
  AF_SELF=${AF_SELF:-$0} AF_NRUNS=3 AF_DRY=0 AF_REDO=0
  while [ $# -gt 0 ]; do
    case $1 in
      --runs) AF_NRUNS=${2:-}; shift 2;; --dry-run) AF_DRY=1; shift;; --redo) AF_REDO=1; shift;;
      -h|--help) sed -n '2,/^set /p' "$AF_SELF" | sed '$d'; exit 0;;
      *) af_die "unknown argument $1";;
    esac
  done
  [[ $AF_NRUNS =~ ^[1-9][0-9]*$ ]] || af_die "--runs needs a positive integer"
  af_resolve
  AF_LOGDIR=${ARTIFACT_LOG_DIR:-${DESTIJL_ROOT:-.}/workspaces/artifact-measure}
}
af_stage_pre() {  # <chain>...: checks before a real measurement
  local c
  for c in "$@"; do [ -f "$c" ] || af_die "missing chain $c (set the *_CHAIN variables, common.sh)"; done
  [ "$AF_DRY" = 1 ] && return 0
  [ -d "$MEASURE_TREE" ] || af_die "MEASURE_TREE $MEASURE_TREE missing"
  [ ! -e "$DESTIJL_ROOT/workspaces/MEASUREMENT.lock" ] || af_die "MEASUREMENT.lock exists: another measurement runs"
  mkdir -p "$AF_LOGDIR"
}
af_chain_run_ok() {  # run k within the chains' --run range (1..3)
  [ "$1" -le 3 ] && return 0
  if [ "$AF_DRY" = 1 ]; then af_say "NOTE run $1: the eval2 chains accept --run 1..3 only (run-chain-v1.sh, h2n-chain-v4.sh: [[ \$K =~ ^[1-3]\$ ]]); widen that check (and the confs' RUNS) before a real run"; return 0; fi
  af_die "run $1: the eval2 chains accept --run 1..3 only (widen run-chain-v1.sh / h2n-chain-v4.sh first)"
}

af_parse() {
  AF_MODE=reprocess AF_REEXPORT=0 AF_REDO=0 AF_DRY=0 AF_NRUNS=3 AF_OUT=${ARTIFACT_OUT:-$PWD/artifact-figures-out}
  AF_EMAP=()
  while [ $# -gt 0 ]; do
    case $1 in
      --reprocess) AF_MODE=reprocess; shift;;
      --measure) AF_MODE=measure; shift;;
      --reexport) AF_REEXPORT=1; shift;;
      --redo) AF_REDO=1; shift;;
      --dry-run) AF_DRY=1; shift;;
      --runs) AF_NRUNS=${2:-}; shift 2;;
      --data) EVAL2_DERIVED=$(cd "${2:?}" && pwd) || exit 2; [ -d "$2/knee-sweep" ] && KNEE_DERIVED=$EVAL2_DERIVED/knee-sweep; shift 2;;
      --knee) KNEE_DERIVED=$(cd "${2:?}" && pwd) || exit 2; shift 2;;
      --plan) KNEE_PLAN=$(readlink -f "${2:?}"); shift 2;;
      --evidence-map) AF_EMAP+=("${2:?}"); shift 2;;
      --out) AF_OUT=$(readlink -m "${2:?}"); shift 2;;
      -h|--help) sed -n '2,/^set /p' "$AF_SELF" | sed '$d'; echo; sed -n '/^# Options of every/,/^$/p' "$AF_DIR/common.sh"; exit 0;;
      *) af_die "unknown argument $1 (--help)";;
    esac
  done
  [[ $AF_NRUNS =~ ^[1-9][0-9]*$ ]] || af_die "--runs needs a positive integer"
  [ "$AF_REDO" = 0 ] || [ "$AF_MODE" = measure ] || af_die "--redo needs --measure"
}

# af_main "$@": the body of every fig<N>.sh. Caller sets AF_FIG (fig1..fig8), AF_NEEDS (parts: h1 h2 knee-h1 knee),
# AF_STAGE_LIST ("<stage>:<shared with>" ...), AF_TITLE.
af_main() {
  AF_SELF=${AF_SELF:-$0}
  af_resolve
  af_parse "$@"
  af_say "$AF_TITLE"
  af_say "mode $AF_MODE$([ "$AF_REEXPORT" = 1 ] && echo ' + re-export')$([ "$AF_DRY" = 1 ] && echo ' (dry run: nothing is run or written)'); runs 1..$AF_NRUNS; out $AF_OUT"
  af_say "data: eval2 $EVAL2_DERIVED; knee $KNEE_DERIVED; plan $KNEE_PLAN"
  if [ "$AF_MODE" = measure ]; then
    local s
    for s in $AF_STAGE_LIST; do af_stage "${s%%:*}" "${s#*:}"; done
  fi
  local miss
  miss=$(af_missing)
  if [ -n "$miss" ]; then
    if [ "$AF_DRY" = 1 ]; then
      af_say "NOTE: inputs missing now ($([ "$AF_MODE" = measure ] && echo 'the stages above create them first' || echo 'a real run stops here')):"
      printf '%s\n' "$miss" | sed 's/^/  missing: /'
    else printf '%s\n' "$miss" | sed 's/^/  missing: /' >&2; af_die "inputs missing: give --data/--knee/--plan, or run with --measure (README.md)"; fi
  fi
  if [ "$AF_REEXPORT" = 1 ]; then
    local k p
    echo "== re-export from the evidence into $AF_OUT/derived"
    for p in $AF_NEEDS; do
      case $p in
        h1) for k in $(af_runs); do af_reexport_h1 "$k"; done;;
        h2) for k in $(af_runs); do af_reexport_h2 "$k"; done;;
        knee-h1) af_reexport_knee h1;;
        knee) af_reexport_knee all;;
      esac
    done
  fi
  echo "== plot ($AF_FIG)"
  af_plot
  [ "$AF_DRY" = 1 ] || af_manifest
}
