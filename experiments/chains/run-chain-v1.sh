#!/bin/bash
# eval2 run chain v1: ONE run k (k = 1, 2, 3) of the whole evaluation set under the measurement rule of 2026-10-21
# 22:4x (state/PROJECT.md: SLO confirm = 15 s unmeasured warmup + ONE continuous 90 s window, loadgen
# builds/vdb-loadgen/11, since 2026-10-22 builds/vdb-loadgen/12 with the past-the-knee steps); ramp/bisect unchanged; runs 1-3 with seeds SEED_BASE + k, same seed for every system / mix /
# N inside a run). Main session only (VM, sudo and shared-memory steps happen in the called drivers).
#   h1      new H1 on the current 2-VM topology (cxl_vm0/cxl_vm1, 16 vCPU / 96 GB), fp32 vector DB of two-workload run 1,
#           u10 u50 u90 x hw pop mg (user 2026-10-22: both hypotheses use u10 u50 u90):
#             EVAL2_H1_FIXED=1 (default, eval2.env): runset-vdb.sh <k> with eval2-h1.conf = SLO searches + the fixed-load
#               windows of two-workload run 1 (L1/L2 per mix from this run's SLO results, mgoff; no H2 level set since 2026-10-22)
#             EVAL2_H1_FIXED=0: runset-h2n.sh 2 <k> with eval2-h1-slo.conf = SLO searches only
#           evidence recovery/eval2-run<k>-h1-n2-v<V>; a failed H1 is logged (with the evidence dir) and the chain goes on
#           to h2 unless the measurement lock is still held (then it stops before any topology change)
#   h2      new H2 (SQ8, ef 24, N = 2/4/8 x u10 u50 u90 x hw mg pop): h2n-chain-v4.sh (next to this script) --run <k> with
#           eval2-h2.conf (install -> switch to VM8 -> N=2, 4, 8 blocks -> restore to 2 x 16 vCPU -> per-N export +
#           combine); evidence recovery/eval2-run<k>-h2-n<N>-v<V>, switch / restore dirs recovery/VM8-v4-eval2-run<k>(-restore)
#   export  H1 export of the newest H1 evidence of run k (again, into <DERIVED_ROOT>/vdb/<runset>/run<k>-chain) and the
#           list of registries / derived dirs in <EVAL2_RUN_DIR>/run<k>-exports.txt
# usage: run-chain-v1.sh --run K [--dry-run] [--start h1|h2|h2:<v4 start>|restore|export] [--h1-fixed 0|1]
#                        [--pretouch DIR] [--h2-args "<extra h2n-chain-v4.sh args>"] [--tree DIR (dry only)]
#                        [--h1-only] [--h1-mixes "<mixes>"] [--h1-with DIR ...]
#   split H1 of one run (2026-10-22, eval2 run 1: v1 stopped at u10 after u50/u90 completed):
#   --h1-only   --start h1 runs H1 then the export, no H2 (H2 of this run already done)
#   --h1-mixes  runset-vdb.sh env EVAL_ONLY_POINTS (subset of the conf's VDB_POINTS, e.g. "u10"): a new evidence version
#               with only these mixes, same conf / config_sha256 / seeds / per-mix order
#   --h1-with   (repeatable) an earlier evidence version of the same run holding the other mixes; the export joins it
#               (vectordb/export.py with several evidence dirs) into <DERIVED_ROOT>/vdb/vdb/run<k>-chain
#   Code changed since live-head.txt (the isca27-fix merge): a real run needs EVAL2_ALLOW_HEAD_CHANGE=1 (say so in RUNLOG).
#   --start h1 (default) | h2 (h2n-chain-v4 from install) | h2:<point> (h2n-chain-v4 --start <point>, e.g. h2:switch,
#           h2:4:up, h2:4, h2:4:mg:u50) | restore (h2n-chain-v4 --start restore: restore + H2 export) | export
#   --pretouch  PRETOUCH_DIR of the H1 part (pretouch evidence of the current 2-VM QEMU lifetimes); default: run k's own
#           H2 restore recovery/VM8-v4-eval2-run<k>-restore when it exists (H1 rerun after this run's H2), else run 1:
#           recovery/VM8-v4-h2n-sq8-run1-restore, run k >= 2: recovery/VM8-v4-eval2-run<k-1>-restore
#   --h2-args  appended to the h2n-chain-v4.sh call (e.g. "--only-n 4 --from 4:mg:u50" after a failed N)
#   --dry-run  every step printed; the run-set dry starts run (H1: runset --dry; H2: h2n-chain-v4.sh --dry-run with
#           H2N_DRY_CHECK=1 = runset-h2n.sh <N> <k> --dry per N); no lock, no VM contact, nothing written
# Launch (real): setsid nohup bash /home/comsys/sungsu/destijl-control/workspaces/eval2-chain-v2.sh --run <k> \
#   > /dev/null 2>&1 < /dev/null &        (log: <EVAL2_RUN_DIR>/run<k>.log)
# Refuses (real run) unless the live tree P/CXL_SWMC contains branch runs123 (merge it first) and is clean, and
# workspaces/MEASUREMENT.lock is absent.
# Repo copy (experiments/chains/, README.md there) of workspaces/runs123/run-chain-v1.sh as it ran for eval2 runs 1-3;
# only the paths are parameterised (same defaults):
#   DESTIJL_ROOT   [/home/comsys/sungsu/destijl-control] control root P (recovery/, workspaces/, the live tree CXL_SWMC)
#   EVAL2_RUN_DIR  [$P/workspaces/runs123] logs and state of this chain and of h2n-chain-v4.sh (run<k>.log,
#                  live-head.txt, run<k>-h1-v<V>.log, run<k>-h2.log, run<k>-exports.txt, h2n-chain-v4-*)
#   EVAL2_ENV      [<this dir>/eval2.env] the EVAL2_H1_FIXED switch file
# h2n-chain-v4.sh is the copy next to this script.
set -uo pipefail
P=${DESTIJL_ROOT:-/home/comsys/sungsu/destijl-control}
CH=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
R=${EVAL2_RUN_DIR:-$P/workspaces/runs123}
export EVAL2_RUN_DIR=$R
EV2ENV=${EVAL2_ENV:-$CH/eval2.env}
LIVE=$P/CXL_SWMC
MED=$P/recovery/HOST-measure-env-reapply-1 MPD=$P/recovery/HOST-measure-part-apply-2
K= DRY=0 START=h1 TREE=$LIVE H2ARGS= PT= FIXED= H1ONLY=0 H1MIXES= H1WITH=()
SELF=$(readlink -f "${BASH_SOURCE[0]}")
ARGS=("$@")
while [ $# -gt 0 ]; do
  case $1 in
    --h1-only) H1ONLY=1; shift;;
    --h1-mixes) H1MIXES=${2:-}; shift 2;;
    --h1-with) [ -d "${2:-}" ] || { echo "CHAIN STOP: --h1-with needs an existing evidence dir"; exit 2; }
               H1WITH+=("$(cd "$2" && pwd)"); shift 2;;
    --run) K=${2:-}; shift 2;;
    --dry-run) DRY=1; shift;;
    --start) START=${2:-}; shift 2;;
    --h1-fixed) FIXED=${2:-}; shift 2;;
    --pretouch) PT=${2:-}; shift 2;;
    --h2-args) H2ARGS=${2:-}; shift 2;;
    --tree) TREE=$(cd "${2:?--tree needs a path}" && pwd) || exit 2; shift 2;;
    *) echo "CHAIN STOP: unknown argument $1"; exit 2;;
  esac
done
[[ $K =~ ^[1-3]$ ]] || { echo "CHAIN STOP: --run 1..3 required"; exit 2; }
case $START in h1|h2|h2:*|restore|export) ;; *) echo "CHAIN STOP: bad --start $START"; exit 2;; esac
[ -n "$FIXED" ] || FIXED=$(grep -m1 '^EVAL2_H1_FIXED=' "$EV2ENV" 2>/dev/null | cut -d= -f2)
[[ $FIXED =~ ^[01]$ ]] || { echo "CHAIN STOP: EVAL2_H1_FIXED must be 0 or 1 (eval2.env or --h1-fixed; got '$FIXED')"; exit 2; }
[ $DRY = 1 ] || [ "$TREE" = "$LIVE" ] || { echo "CHAIN STOP: --tree is for --dry-run only (a real run uses $LIVE)"; exit 2; }
# real run: everything into run<k>.log (re-exec with a plain redirect: no process substitution child that carries this
# script's command line while vmN phases check for other chains)
if [ $DRY = 0 ] && [ -z "${RUNCHAIN_LOGGED:-}" ]; then
  export RUNCHAIN_LOGGED=1
  exec bash "$SELF" "${ARGS[@]}" >> "$R/run$K.log" 2>&1 < /dev/null
fi
T0=$(date +%s)
say() { echo "$(date -Is) [eval2 run $K$([ $DRY = 1 ] && echo ' DRY')] $*"; }
FAILS=()
die() { say "CHAIN STOP: $*"; say "CHAIN END rc=2 failed=[${FAILS[*]}] wall_min=$(( ($(date +%s) - T0) / 60 ))"; exit 2; }
say "start pid $$ tree $TREE start $START EVAL2_H1_FIXED=$FIXED args [${ARGS[*]}]"
EVD=$TREE/experiments/eval
if [ $FIXED = 1 ]; then H1CONF=$EVD/eval2-h1.conf H1RS=(bash "$EVD/runset-vdb.sh" "$K") H1SET=vdb
else H1CONF=$EVD/eval2-h1-slo.conf H1RS=(bash "$EVD/runset-h2n.sh" 2 "$K") H1SET=h2n-n2; fi
H2CONF=$EVD/eval2-h2.conf V4=$CH/h2n-chain-v4.sh
for f in "$H1CONF" "$H2CONF" "$EVD/runset-vdb.sh" "$EVD/runset-h2n.sh" "$V4"; do [ -f "$f" ] || die "missing $f"; done
# ---- refusals ----
BR=$(git -C "$LIVE" rev-parse -q --verify refs/heads/runs123 2>/dev/null)
if [ -n "$BR" ] && git -C "$LIVE" merge-base --is-ancestor "$BR" HEAD 2>/dev/null; then
  say "live tree $LIVE contains branch runs123 ($(git -C "$LIVE" rev-parse --short "$BR"); HEAD $(git -C "$LIVE" rev-parse --short HEAD))"
elif [ $DRY = 1 ]; then say "NOTE: live tree $LIVE lacks branch runs123 (${BR:0:9}): a real run would refuse here (merge runs123 first)"
else die "live tree $LIVE lacks branch runs123 (merge it into $LIVE first)"; fi
# same code for runs 1-3: the first real run records the live HEAD in live-head.txt; a later run with another HEAD
# refuses unless EVAL2_ALLOW_HEAD_CHANGE=1 (a deliberate harness fix between runs; then say so in RUNLOG)
LH=$(git -C "$LIVE" rev-parse HEAD)
if [ -f "$R/live-head.txt" ]; then
  RH=$(awk 'NR == 1 { print $1 }' "$R/live-head.txt")
  if [ "$RH" = "$LH" ]; then say "live HEAD $LH = the HEAD of the first eval2 run (live-head.txt)"
  elif [ $DRY = 1 ] || [ "${EVAL2_ALLOW_HEAD_CHANGE:-0}" = 1 ]; then say "NOTE: live HEAD $LH != first eval2 run's $RH (live-head.txt)$([ $DRY = 1 ] && echo ': a real run would refuse here' || echo '; allowed by EVAL2_ALLOW_HEAD_CHANGE=1')"
  else die "live HEAD $LH != the HEAD of the first eval2 run $RH (live-head.txt): runs 1-3 must use the same code (EVAL2_ALLOW_HEAD_CHANGE=1 to override)"; fi
elif [ $DRY = 0 ]; then echo "$LH run$K $(date -Is)" > "$R/live-head.txt"; say "recorded live HEAD $LH in $R/live-head.txt"
else say "live HEAD $LH (a real run records it in live-head.txt)"; fi
if [ -n "$(git -C "$LIVE" status --porcelain --untracked-files=no)" ]; then
  [ $DRY = 1 ] && say "NOTE: live tree is dirty: a real run would refuse here" || die "live tree $LIVE is dirty"
fi
if [ -e "$P/workspaces/MEASUREMENT.lock" ]; then
  [ $DRY = 1 ] || die "workspaces/MEASUREMENT.lock exists ($(cat "$P/workspaces/MEASUREMENT.lock"))"
  say "NOTE: MEASUREMENT.lock is held ($(cat "$P/workspaces/MEASUREMENT.lock")): a real run would refuse here"
else say "MEASUREMENT.lock absent"; fi
for d in "$MED" "$MPD"; do [ -d "$d" ] || die "missing $d"; done
[[ $H1MIXES =~ ^[a-z0-9\ ]*$ ]] || die "bad --h1-mixes '$H1MIXES'"
{ [ -z "$H1MIXES" ] && [ $H1ONLY = 0 ] && [ ${#H1WITH[@]} = 0 ]; } || [ $FIXED = 1 ] \
  || die "--h1-only / --h1-mixes / --h1-with need EVAL2_H1_FIXED=1 (runset-vdb.sh)"
[ ${#H1WITH[@]} = 0 ] || [ -n "$H1MIXES" ] || die "--h1-with joins a partial H1 (--h1-mixes) with earlier versions"
if [ -z "$PT" ]; then
  if [ -d "$P/recovery/VM8-v4-eval2-run$K-restore" ]; then PT=$P/recovery/VM8-v4-eval2-run$K-restore
  elif [ "$K" = 1 ]; then PT=$P/recovery/VM8-v4-h2n-sq8-run1-restore; else PT=$P/recovery/VM8-v4-eval2-run$((K - 1))-restore; fi
fi
conf() { python3 -I -B "$EVD/evalconf.py" shell --conf "$1" | sed -n "s/^$2=//p" | tr -d "'"; }
# ---- steps ----
step_h1() {
  [ -d "$PT" ] || { [ $DRY = 1 ] && say "NOTE: H1 PRETOUCH_DIR $PT does not exist yet (run $((K - 1)) restore): a real run would stop here"; } \
    || die "H1 PRETOUCH_DIR $PT missing (pass --pretouch)"
  local env1=(EVAL_CONF=$H1CONF PRETOUCH_DIR=$PT MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD) out rc E V RLOG
  [ -d "$PT" ] || env1=(EVAL_CONF=$H1CONF MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD)
  [ -z "$H1MIXES" ] || env1+=("EVAL_ONLY_POINTS=$H1MIXES")
  say "== H1 ($([ $FIXED = 1 ] && echo "SLO + fixed-load windows, runset-vdb.sh" || echo "SLO only, runset-h2n.sh 2"); conf $H1CONF)"
  say "CMD: env ${env1[*]} ${H1RS[*]} --dry"
  out=$(env "${env1[@]}" "${H1RS[@]}" --dry 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  [ $rc = 0 ] && grep -q "^DRY START OK" <<< "$out" || die "H1 run-set dry start failed (rc $rc)"
  E=$(sed -n 's/^PLAN ([^)]*): evidence dir \(\S*\) (absent: OK)$/\1/p' <<< "$out")
  [[ $E =~ ^$P/recovery/eval2-run$K-h1-n2-v([0-9]+)$ ]] || die "H1 evidence dir not recognised ('$E')"
  V=${BASH_REMATCH[1]} RLOG=$R/run$K-h1-v$V.log
  say "H1 DRY START OK; evidence dir $E"
  say "CMD: env ${env1[*]} ${H1RS[*]} --v $V > $RLOG 2>&1"
  [ $DRY = 1 ] && return 0
  env "${env1[@]}" "${H1RS[@]}" --v "$V" > "$RLOG" 2>&1; rc=$?
  say "H1 run set rc $rc: $(tail -n 1 "$RLOG")"
  if [ $rc = 0 ] && grep -q "RUNSET DONE" "$E/eval-state.txt" 2>/dev/null; then say "H1 DONE: $E (accept after review: see the RUNSET DONE line)"
  else FAILS+=("h1 (rc $rc, evidence $E, log $RLOG)"); say "H1 FAILED: $E (see $RLOG); rerun later with --start h1 --pretouch <current 2-VM pretouch dir>"; fi
  [ ! -e "$P/workspaces/MEASUREMENT.lock" ] || die "MEASUREMENT.lock still held after H1 ($(cat "$P/workspaces/MEASUREMENT.lock")): no topology switch"
}
step_h2() {  # <h2n-chain-v4 start args...>
  local env2=(EVAL_CONF=$H2CONF H2N_TREE=$TREE MEASURE_ENV_DIR=$MED MEASURE_PART_DIR=$MPD) rc
  # shellcheck disable=SC2206
  local extra=($H2ARGS)
  say "== H2 (h2n-chain-v4.sh, conf $H2CONF)"
  if [ $DRY = 1 ]; then
    say "CMD: env H2N_DRY_CHECK=1 ${env2[*]} bash $V4 --run $K $* ${extra[*]} --dry-run"
    env H2N_DRY_CHECK=1 "${env2[@]}" bash "$V4" --run "$K" "$@" "${extra[@]}" --dry-run 2>&1 | sed 's/^/  | /'
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || die "h2n-chain-v4 dry run rc $rc"
    return 0
  fi
  say "CMD: env ${env2[*]} bash $V4 --run $K $* ${extra[*]}  (log $R/run$K-h2.log)"
  env "${env2[@]}" bash "$V4" --run "$K" "$@" "${extra[@]}" >> "$R/run$K-h2.log" 2>&1 < /dev/null; rc=$?
  say "H2 chain rc $rc: $(tail -n 1 "$R/run$K-h2.log")"
  [ $rc = 0 ] || FAILS+=("h2 (rc $rc, see $R/run$K-h2.log and its RESUME lines)")
}
step_export() {
  local rr ep dr reg csha e out rc
  say "== export (H1 again from the newest H1 evidence of run $K; registries / derived dirs -> $R/run$K-exports.txt)"
  rr=$(conf "$H1CONF" RESULTS_ROOT) dr=$(conf "$H1CONF" DERIVED_ROOT) reg=$(conf "$H1CONF" REGISTRY)
  if [ $FIXED = 1 ]; then csha=$(conf "$H1CONF" CONFIG_SHA256_VDB); else csha=$(conf "$H1CONF" CONFIG_SHA256_H2N); fi
  e=$(ls -d "$rr/eval2-run$K-h1-n2-v"* 2>/dev/null | sort -V | while read -r d; do grep -q "RUNSET DONE" "$d/eval-state.txt" 2>/dev/null && echo "$d"; done | tail -1)
  out=$dr/vdb/$H1SET/run$K-chain
  local x; for x in "${H1WITH[@]}"; do [ "$x" != "$e" ] || { FAILS+=("export h1 (--h1-with $x is the newest finished H1 evidence)"); e=; }; done
  if [ $FIXED = 1 ]; then set -- python3 -I -B "$TREE/experiments/vectordb/export.py" --run "$K" --runset vdb --config-sha256 "$csha" --out "$out" "${e:-<H1 evidence>}" "${H1WITH[@]}"
  else set -- python3 -I -B "$EVD/export_h2n.py" --run "$K" --nodes 2 --config-sha256 "$csha" --out "$out" "${e:-<H1 evidence>}/block"; fi
  say "CMD: $* > $out/export.log"
  if [ $DRY = 0 ]; then
    if [ -z "$e" ]; then FAILS+=("export h1 (no finished H1 evidence of run $K)"); say "export H1: no finished H1 evidence of run $K"
    else mkdir -p "$out" && "$@" > "$out/export.log" 2>&1; rc=$?; say "export H1 rc $rc: $(tail -n 1 "$out/export.log")"
         [ $rc = 0 ] || FAILS+=("export h1 (see $out/export.log)"); fi
  fi
  local d2 r2; d2=$(conf "$H2CONF" DERIVED_ROOT) r2=$(conf "$H2CONF" REGISTRY)
  local txt="# eval2 run $K exports ($(date -Is))
h1_mode=$([ $FIXED = 1 ] && echo fixed || echo slo-only) h1_registry=$reg h1_evidence=${e:-none}${H1WITH[*]:+ + ${H1WITH[*]} (split H1: mixes [$H1MIXES] in ${e:-none}, the others in the earlier versions)}
h1_derived=$dr/vdb/$H1SET/run$K$([ -n "$H1MIXES" ] && echo "-only-${H1MIXES// /-}") (run set export) $out (chain export$([ ${#H1WITH[@]} -gt 0 ] && echo ', every mix of the run'))
h2_registry=$r2 h2_evidence=$(conf "$H2CONF" RESULTS_ROOT)/eval2-run$K-h2-n{2,4,8}-v*
h2_derived=$d2/vdb/h2n-n{2,4,8}/run$K-all (per N) $d2/vdb/h2n/run$K (combined summary.csv, steps.csv)"
  if [ $DRY = 1 ]; then say "would write $R/run$K-exports.txt:"; printf '%s\n' "$txt" | sed 's/^/  | /'
  else printf '%s\n' "$txt" > "$R/run$K-exports.txt"; say "wrote $R/run$K-exports.txt"; fi
}
case $START in
  h1) step_h1; [ $H1ONLY = 1 ] && say "H2 skipped (--h1-only)" || step_h2; step_export;;
  h2) step_h2; step_export;;
  h2:*) step_h2 --start "${START#h2:}"; step_export;;
  restore) step_h2 --start restore; step_export;;
  export) step_h2 --start export; step_export;;
esac
if [ $DRY = 1 ]; then
  # past-the-knee rule (loadgen/12, 2026-10-22): + 1 overload step per SLO search (4 instead of 3, the x2.0 one drains
  # longer), + 2 steps after a failed start rate: ~+0.5-1 min per search, ~+10 min H1 (9 searches), ~+20-30 min H2.
  # Mixes u10 u50 u90 in both hypotheses (user 2026-10-22): H1 3 mixes instead of 5
  say "ESTIMATE run $K: H1 $([ $FIXED = 1 ] && echo '~3.9-4.6 h (3 mixes x 6 lifetimes: 3 SLO ~20-23 min incl. server start (mg incl. its fix part), 3 fixed mgoff/hw/pop ~6-8 min; no H2 level set)' || echo '~3-3.3 h (9 SLO lifetimes ~20-23 min incl. server start)'); H2 ~7-8.5 h (install/switch ~0.5 h, VM start + pretouch ~0.25 h per N, 27 SLO lifetimes ~14-18 min at 4 vCPU, restore ~0.3 h); total ~11-13 h (fixed) / ~10-12 h (SLO only)"
  # split H1 (--h1-mixes): per mix 6 lifetimes (3 SLO ~20-23 min, 3 fixed ~6-8 min; run 1 v1: u50 + u90 = 2 h 25 min)
  # + gates ~5 min; collect / check / export a few minutes
  [ -z "$H1MIXES" ] || say "ESTIMATE split H1 [$H1MIXES]: ~$(( $(wc -w <<< "$H1MIXES") * 75 + 10 )) min$([ $H1ONLY = 1 ] && echo ' (no H2: --h1-only)')"
  say "DRY CHAIN OK"
fi
say "CHAIN END rc=$([ ${#FAILS[@]} = 0 ] && echo 0 || echo 1) failed=[${FAILS[*]}] wall_min=$(( ($(date +%s) - T0) / 60 ))"
[ ${#FAILS[@]} = 0 ]
