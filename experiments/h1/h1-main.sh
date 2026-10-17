#!/bin/bash
# H1 main, one STAGE per invocation (reports/H1-main-packet.md §3; user decision 2026-10-17, state/TASKS.md):
#   r1-kv, r1-lmdb, r1-vdb, r1-recsys   round 1 of one workload, in this order; the main session reviews each check
#                                       and records its acceptance (h1-accept.sh) before the next stage may start
#   r2, r3 [--workloads w1,w2]          repeats for all four or a user-chosen subset (plan change 2026-10-18), fixed
#                                       order, each followed by its check; a check FAIL stops the stage; r2 needs all
#                                       four r1 stages accepted, r3 additionally r2 accepted for each chosen workload
# Orchestration only: every VM action happens inside the workload blocks (their H1 hook, experiments/h1/README.md).
# Lifetimes (H1-HOOK v2, user decision 2026-10-18): no server lifetime only for the fixed phase except r1 hw/pop.
#   r1 (per mix): hw, pop SLO-only lifetimes (Latin order between them), then mg: SLO -> levels-cb.sh (L1/L2 of the
#      mix from hw, pop, mg maxima) -> settle -> L2 -> L1 in the same lifetime, then hw and pop separate fixed lifetimes
#      (settle -> L2 -> L1) = the "separate" sample.
#   mgoff (Megalon timers off, Fig 2 C_diff; user decision 2026-10-18: Megalon 77, no runtime switch): its own lifetime
#      settle -> L2 -> L1 (no SLO search) right after the mg lifetime of the mix, in every round.
#   r2, r3 (per mix): hw, pop, mg Latin square, each one lifetime SLO -> settle -> L2 -> L1 = the "continuous" sample.
#   check.py r2 compares hw/pop r1 separate vs r2 continuous against the run-to-run spread (mg, continuous in both
#   rounds); REPORT lines block the r2 acceptance (r3) until the user has seen them.
# Per workload W and round n (stage dir <E>/<W>/r<n>/run/, must not exist):
#   1. gate: pretouch gate (standing rule 2026-10-17) and Host gate (no build, quiet, measure-env check)
#   2. hook.sh W r1|cont <E>/<W>/r<n>/run (one block call per workload and round; r1 writes <E>/<W>/levels.tsv
#      through levels-cb.sh inside each mg lifetime; r2/r3 reuse it, dec Q3)
#   5. pretouch gate again; 6. collect.py -> r<n>/collect; 7. check.py -> r<n>/check.txt (H1CHECK PASS | FAIL)
# Every stage ends with collect.py over all rounds present of its workloads (<E>/<W>/collect-all-r<n>).
# Holds the measurement lock (owner H1-main) for the stage; hooks run with H1_PARENT_LOCK=H1-main. Stops at the
# first failing step ("SEQUENCE STOP"); every block rolls back in its own EXIT trap; this script releases the lock.
# usage: h1-main.sh <stage> <evidence root E>
#   E: for r1-kv it must exist and be empty except sequence* files; later stages use the same E.
# env: PRETOUCH_DIR, MEASURE_ENV_DIR (required unless H1_DRY=1), H1_PLAN (default h1-plan.tsv next to this script),
#   settle_s per workload from the plan (column 8),
#   H1_SEED_BASE (20261017: loadgen seed of round n = base + n), H1_NO_FIGS (set: no
#   figures), H1_DRY=1 (Host self-test: plugin "stub", gates skipped, LOCK must be a test lock under h1-main/).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
STAGE=${1:?usage: h1-main.sh <stage> <evidence root> [--workloads w1,w2]} E=${2:?usage: h1-main.sh <stage> <evidence root>}
SUBSET=
if [ -n "${3:-}" ]; then
  [ "$3" = --workloads ] && [ -n "${4:-}" ] || { echo "SEQUENCE STOP: usage: h1-main.sh r2|r3 <E> --workloads w1,w2"; exit 2; }
  SUBSET=${4//,/ }
fi
H=$(cd "$(dirname "$0")" && pwd)
G=$H/../vectordb/host-gate.sh PG=$H/../vectordb/pretouch-gate.sh
PLAN=${H1_PLAN:-$H/h1-plan.tsv} DRY=${H1_DRY:-0}
export H1_SEED_BASE=${H1_SEED_BASE:-20261017}
ORDER="kv lmdb vdb recsys"   # user decision 2026-10-17
OWNER=H1-main
case $STAGE in
  r1-kv|r1-lmdb|r1-vdb|r1-recsys) N=1 WL=${STAGE#r1-}
         [ -z "$SUBSET" ] || { echo "SEQUENCE STOP: --workloads is for r2/r3 only"; exit 2; };;
  r2|r3) N=${STAGE#r} WL=
         # subset (plan change 2026-10-18: r1 for all four now, the user picks workloads for r2; r3 later): kept in
         # the fixed order; default all four
         for w in $ORDER; do [ -z "$SUBSET" ] || [[ " $SUBSET " == *" $w "* ]] && WL="$WL $w"; done
         for w in $SUBSET; do [[ " $ORDER " == *" $w "* ]] || { echo "SEQUENCE STOP: unknown workload $w"; exit 2; }; done
         WL=${WL# };;
  *) echo "SEQUENCE STOP: bad stage $STAGE (r1-kv r1-lmdb r1-vdb r1-recsys r2 r3)"; exit 2;;
esac
[ -f "$PLAN" ] || { echo "SEQUENCE STOP: no plan $PLAN"; exit 2; }
for w in $ORDER; do grep -q "^$w	" "$PLAN" || { echo "SEQUENCE STOP: workload $w not in the plan"; exit 2; }; done
if [ "$STAGE" = r1-kv ]; then
  [ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
else
  [ -f "$E/h1-manifest.txt" ] || { echo "SEQUENCE STOP: $E has no h1-manifest.txt (start with r1-kv)"; exit 2; }
fi
# stage preconditions: acceptance records of the previous stage(s) (h1-accept.sh; the check.txt sha256 must still match)
accepted() {  # W n -> 0 if r<n> of W has check PASS and an acceptance record matching the check file
  local c=$E/$1/r$2/check.txt a=$E/accept/r$2-$1.txt
  [ -f "$c" ] && tail -n 1 "$c" | grep -q "^H1CHECK PASS" && [ -f "$a" ] \
    && grep -q "check_sha256=$(sha256sum < "$c" | cut -c1-64)" "$a"
}
case $STAGE in
  r1-lmdb) accepted kv 1 || { echo "SEQUENCE STOP: r1-kv not checked PASS + accepted"; exit 2; };;
  r1-vdb) accepted lmdb 1 || { echo "SEQUENCE STOP: r1-lmdb not checked PASS + accepted"; exit 2; };;
  r1-recsys) accepted vdb 1 || { echo "SEQUENCE STOP: r1-vdb not checked PASS + accepted"; exit 2; };;
  r2|r3) for w in $ORDER; do accepted $w 1 || { echo "SEQUENCE STOP: r1 of $w not checked PASS + accepted (r2/r3 need all four r1)"; exit 2; }; done
         if [ $N = 3 ]; then for w in $WL; do accepted $w 2 || { echo "SEQUENCE STOP: r2 of $w not checked PASS + accepted"; exit 2; }; done; fi;;
esac
if [ "$DRY" = 1 ]; then
  case "${LOCK:-}" in */h1-main/*) ;; *) echo "SEQUENCE STOP: H1_DRY=1 needs LOCK=<test lock under workspaces/h1-main/>"; exit 2;; esac
else
  : "${PRETOUCH_DIR:?PRETOUCH_DIR = ENV-pretouch evidence dir of the current QEMU lifetime}" "${MEASURE_ENV_DIR:?}"
  export PRETOUCH_DIR MEASURE_ENV_DIR
fi
log() { echo "$(date -Is) [$STAGE] $*" | tee -a "$E/h1-state.txt"; }
stop() { log "SEQUENCE STOP $*"; exit 1; }
bash $G lock $OWNER || { echo "SEQUENCE STOP: lock"; exit 2; }
trap 'bash $G unlock $OWNER' EXIT
{ echo "# H1 main stage $STAGE"; echo "start=$(date -Is)"; echo "cxl_swmc_commit=$(git -C $H rev-parse HEAD 2>/dev/null)"
  echo "cxl_swmc_dirty_h1=$(git -C $H status --porcelain -- . | wc -l)"; echo "plan=$PLAN sha256=$(sha256sum < "$PLAN" | cut -c1-64)"
  for f in h1-main.sh hook.sh levels.py levels-cb.sh collect.py check.py h1-accept.sh; do echo "$f sha256=$(sha256sum < $H/$f | cut -c1-64)"; done
  for f in v6_fig2_split.py v6_common.py v6_fig1_curves.py; do echo "analysis/$f sha256=$(sha256sum < $H/../analysis/$f | cut -c1-64)"; done
  echo "stage=$STAGE round=$N workloads=$WL seed_base=$H1_SEED_BASE dry=$DRY"
  echo "pretouch_dir=${PRETOUCH_DIR:-} measure_env_dir=${MEASURE_ENV_DIR:-}"
  for w in $WL; do f=$H/plugins/pins-$w.sh; [ "$DRY" = 1 ] && f=$H/plugins/pins-stub.sh
    echo "pins.$w=$f sha256=$(sha256sum < "$f" 2>/dev/null | cut -c1-64)"; done; } >> "$E/h1-manifest.txt"
gates() {  # tag
  if [ "$DRY" = 1 ]; then log "gate $1: DRY (pretouch and Host gates skipped)"; return 0; fi
  bash $PG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" > /dev/null || stop "pretouch gate ($1; see pretouch-gate.txt)"
  MEASURE_ENV_DIR=$MEASURE_ENV_DIR bash $G check "$E/gate-$1.txt" || stop "host gate ($1)"
  log "gate $1: PASS"
}
log "stage start: round $N, workloads [$WL]"
for W in $WL; do
  T0=$(date +%s) S=$E/$W/r$N
  MIXES=$(awk -F'\t' -v w="$W" '!/^#/ && $1 == w { printf "%s=%s ", $2, $3 }' "$PLAN")
  [ ! -e "$S" ] || stop "$S exists (stage dirs are immutable; use a new evidence root for a rerun)"
  SETTLE=$(awk -F'\t' -v w="$W" '!/^#/ && $1 == w { print $8; exit }' "$PLAN")
  [[ $SETTLE =~ ^[1-9][0-9]*$ ]] || stop "$W: no settle_s in the plan"
  mkdir -p "$S/run" || stop "mkdir $S"
  gates "$W-r$N-start"
  if [ $N = 1 ]; then  # r1: per mix hw/pop SLO-only lifetimes, mg SLO -> levels (callback) -> settle -> L2 -> L1,
                       # then hw/pop separate fixed lifetimes (dec 2026-10-18)
    [ ! -e "$E/$W/levels.tsv" ] || stop "$W: levels.tsv exists before r1"
    log "$W r1: mixes [$MIXES], settle ${SETTLE}s"
    env H1_SETTLE_S=$SETTLE H1_LEVELS_CMD=$H/levels-cb.sh H1_PLAN="$PLAN" H1_W=$W H1_LEVELS_OUT="$E/$W/levels.tsv"       bash $H/hook.sh "$W" r1 "$S/run" 1 "$MIXES" || stop "$W r1"
    for m in $MIXES; do grep -q "^${m%%=*}	" "$E/$W/levels.tsv" 2>/dev/null || stop "$W: levels.tsv has no row for ${m%%=*}"; done
    log "$W levels: $(($(grep -c . "$E/$W/levels.tsv") - 1)) mixes (levels.tsv, computed in the mg lifetimes of r1)"
  else                 # r2/r3: every system one lifetime SLO -> settle -> L2 -> L1 at the r1 levels
    [ -f "$E/$W/levels.tsv" ] || stop "$W: no levels.tsv"
    log "$W r$N: mixes [$MIXES], settle ${SETTLE}s"
    env H1_SETTLE_S=$SETTLE bash $H/hook.sh "$W" cont "$S/run" "$N" "$MIXES" "$E/$W/levels.tsv" || stop "$W r$N"
  fi
  gates "$W-r$N-end"
  nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" --levels "$E/$W/levels.tsv" ${H1_NO_FIGS:+--no-figs} "$S" \
    > "$S/collect.log" 2>&1 || stop "$W r$N collect: $(tail -n 1 "$S/collect.log")"
  python3 -B $H/check.py --plan "$PLAN" --workload "$W" --round "$N" $([ "$DRY" = 1 ] && echo --skip-fig2) "$E" > "$S/check.log" 2>&1
  CRC=$?
  log "$W r$N ($(( ($(date +%s) - T0) / 60 )) min): $(tail -n 1 "$S/check.txt" 2>/dev/null || echo 'no check.txt')"
  [ $CRC = 0 ] || stop "$W r$N check FAIL (see $S/check.txt)"
  grep -q "^REPORT" "$S/check.txt" && log "$W r$N: REPORT lines (separate vs continuous beyond the run-to-run spread): report to the user before r3; h1-accept.sh needs --user-ack"
done
# collect-all after every stage, per workload of the stage: every round present so far (r1 only = single round, no
# variance; r1 + r2 for a subset; ...) into <W>/collect-all-r<n> (immutable; one per round count)
for W in $WL; do
  nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" --levels "$E/$W/levels.tsv" --out-name collect-all-r$N \
    ${H1_NO_FIGS:+--no-figs} "$E/$W" > "$E/$W/collect-all-r$N.log" 2>&1 || stop "$W collect-all-r$N: $(tail -n 1 "$E/$W/collect-all-r$N.log")"
done
log "collect-all-r$N done for [$WL] (rounds 1..$N; slo-summary.csv states single round / mean and sd)"
if [ $N = 1 ]; then
  log "STAGE DONE $STAGE: main session reviews $E/$WL/r1/check.txt, then: bash $H/h1-accept.sh $E 1 $WL"
else
  log "STAGE DONE $STAGE [$WL]: review each r$N/check.txt (REPORT lines -> user first), then h1-accept.sh $E $N <W> [--user-ack ...]"
fi
