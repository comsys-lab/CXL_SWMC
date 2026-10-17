#!/bin/bash
# H1 main, one STAGE per invocation (reports/H1-main-packet.md §3; user decision 2026-10-17, state/TASKS.md):
#   r1-kv, r1-lmdb, r1-vdb, r1-recsys   round 1 of one workload, in this order; the main session reviews each check
#                                       and records its acceptance (h1-accept.sh) before the next stage may start
#   r2, r3                              repeats: the four workloads in the same order, each followed by its check; a
#                                       check FAIL stops the stage; r2 needs all four r1 stages accepted, r3 all r2
# Orchestration only: every VM action happens inside the workload blocks (their H1 hook, experiments/h1/README.md).
# Per workload W and round n (stage dir <E>/<W>/r<n>/, must not exist):
#   1. gate: pretouch gate (standing rule 2026-10-17) and Host gate (no build, quiet, measure-env check)
#   2. SLO phase:   hook.sh W slo <E>/<W>/r<n>/slo n          (Fig 1: one full SLO search per mix x system)
#   3. levels (n = 1 only): levels.py -> <E>/<W>/levels.tsv  (L1 = weakest system's confirm x_mean, L2 = 0.5 L1);
#      rounds 2 and 3 reuse it (same L1/L2 in every round, packet Q3)
#   4. fixed phase: hook.sh W fix <E>/<W>/r<n>/fix n          (Fig 2: L2 then L1 per mix x {hw, pop, mg, mgoff})
#   5. pretouch gate again; 6. collect.py -> r<n>/collect; 7. check.py -> r<n>/check.txt (H1CHECK PASS | FAIL)
# Stage r3 ends with collect.py over all rounds of each workload (<E>/<W>/collect-all: mean/sd over rounds).
# Holds the measurement lock (owner H1-main) for the stage; hooks run with H1_PARENT_LOCK=H1-main. Stops at the
# first failing step ("SEQUENCE STOP"); every block rolls back in its own EXIT trap; this script releases the lock.
# usage: h1-main.sh <stage> <evidence root E>
#   E: for r1-kv it must exist and be empty except sequence* files; later stages use the same E.
# env: PRETOUCH_DIR, MEASURE_ENV_DIR (required unless H1_DRY=1), H1_PLAN (default h1-plan.tsv next to this script),
#   H1_SEED_BASE (20261017: SLO round n seed = base + n, fixed rep n seed = base + 10 + n), H1_NO_FIGS (set: no
#   figures), H1_DRY=1 (Host self-test: plugin "stub", gates skipped, LOCK must be a test lock under h1-main/).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
STAGE=${1:?usage: h1-main.sh <stage> <evidence root>} E=${2:?usage: h1-main.sh <stage> <evidence root>}
H=$(cd "$(dirname "$0")" && pwd)
G=$H/../vectordb/host-gate.sh PG=$H/../vectordb/pretouch-gate.sh
PLAN=${H1_PLAN:-$H/h1-plan.tsv} DRY=${H1_DRY:-0}
export H1_SEED_BASE=${H1_SEED_BASE:-20261017}
ORDER="kv lmdb vdb recsys"   # user decision 2026-10-17
OWNER=H1-main
case $STAGE in
  r1-kv|r1-lmdb|r1-vdb|r1-recsys) N=1 WL=${STAGE#r1-};;
  r2) N=2 WL=$ORDER;;
  r3) N=3 WL=$ORDER;;
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
  r2|r3) for w in $ORDER; do accepted $w $((N - 1)) || { echo "SEQUENCE STOP: r$((N - 1)) of $w not checked PASS + accepted"; exit 2; }; done;;
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
  for f in h1-main.sh hook.sh levels.py collect.py check.py h1-accept.sh; do echo "$f sha256=$(sha256sum < $H/$f | cut -c1-64)"; done
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
  mkdir -p "$S/slo" "$S/fix" || stop "mkdir $S"
  gates "$W-r$N-start"
  log "$W r$N slo: mixes [$MIXES]"
  bash $H/hook.sh "$W" slo "$S/slo" "$N" "$MIXES" || stop "$W r$N slo"
  if [ $N = 1 ]; then
    python3 -B $H/levels.py --plan "$PLAN" --workload "$W" --out "$E/$W/levels.tsv" "$S/slo" > "$E/$W/levels.log" 2>&1 \
      || stop "$W levels: $(tail -n 1 "$E/$W/levels.log")"
    log "$W levels: $(grep -c . "$E/$W/levels.tsv") lines (levels.tsv, from r1)"
  fi
  [ -f "$E/$W/levels.tsv" ] || stop "$W: no levels.tsv"
  log "$W r$N fix"
  bash $H/hook.sh "$W" fix "$S/fix" "$N" "$E/$W/levels.tsv" || stop "$W r$N fix"
  gates "$W-r$N-end"
  nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" --levels "$E/$W/levels.tsv" ${H1_NO_FIGS:+--no-figs} "$S" \
    > "$S/collect.log" 2>&1 || stop "$W r$N collect: $(tail -n 1 "$S/collect.log")"
  python3 -B $H/check.py --plan "$PLAN" --workload "$W" --round "$N" $([ "$DRY" = 1 ] && echo --skip-fig2) "$E" > "$S/check.log" 2>&1
  CRC=$?
  log "$W r$N ($(( ($(date +%s) - T0) / 60 )) min): $(tail -n 1 "$S/check.txt" 2>/dev/null || echo 'no check.txt')"
  [ $CRC = 0 ] || stop "$W r$N check FAIL (see $S/check.txt)"
done
if [ $N = 3 ]; then
  for W in $WL; do
    nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" --levels "$E/$W/levels.tsv" --out-name collect-all \
      ${H1_NO_FIGS:+--no-figs} "$E/$W" > "$E/$W/collect-all.log" 2>&1 || stop "$W collect-all: $(tail -n 1 "$E/$W/collect-all.log")"
  done
  log "collect-all done (mean/sd over rounds in <W>/collect-all/slo-summary.csv)"
fi
if [ $N = 1 ]; then
  log "STAGE DONE $STAGE: main session reviews $E/$WL/r1/check.txt, then: bash $H/h1-accept.sh $E 1 $WL"
else
  log "STAGE DONE $STAGE: review the four r$N/check.txt, then h1-accept.sh $E $N <W> for each"
fi
