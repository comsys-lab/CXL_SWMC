#!/bin/bash
# H1 main sequencer (reports/H1-main-packet.md; MOT1 v6 §1-§3 as decided; grant F). Orchestration only: every VM
# action happens inside the workload blocks (their H1 hook, contract in experiments/h1/README.md), one block at a time.
# Per workload W, in plan order (h1-plan.tsv; WORKLOADS overrides the order/subset):
#   1. gate: pretouch gate (both VMs pre-touched after their last QEMU start; standing rule 2026-10-17) and Host gate
#      (no build, quiet, measure-env check against MEASURE_ENV_DIR)
#   2. SLO phase, rounds r = 1..SLO_ROUNDS: hook.sh W slo <E>/W/slo-r<r>   (Fig 1: full SLO search per mix x system)
#   3. levels.py: per mix L1 = weakest system's confirm x_mean, L2 = 0.5 x L1 (user decision 2026-10-17)
#   4. fixed phase, reps k = 1..FIX_REPS: hook.sh W fix <E>/W/fix-r<k>       (Fig 2: L2 and L1 windows per mix x system)
#   5. collect.py: CSVs (runs-index, steps-all, slo-summary, fix-steps), Fig 1 / Fig 2 inputs, coherence CPU
#   6. pretouch gate again (a QEMU restart during the workload voids its results: stop)
# Holds the measurement lock (owner H1-main) for the whole sequence; hooks run with H1_PARENT_LOCK=H1-main and check it
# instead of locking themselves. Stops at the first non-zero step ("SEQUENCE STOP"); every block rolls back in its own
# EXIT trap (servers, cxl_shm teardown, dax0.0 root:root 600); this script only releases the lock.
# usage: h1-main.sh <evidence root (exists; empty except sequence*)>
# env: PRETOUCH_DIR, MEASURE_ENV_DIR (required unless H1_DRY=1), H1_PLAN (default h1-plan.tsv next to this script),
#   WORKLOADS (default: plan order), SLO_ROUNDS (1), FIX_REPS (1), H1_SEED_BASE (20261017; request seed of round r /
#   rep k = base + r / base + 10 + k, passed to the hooks), START_AT (skip workloads before it, e.g. after a stop and
#   a fixed rerun in a NEW evidence root; recorded), H1_DRY=1 (Host self-test: every workload uses plugin "stub",
#   gates are skipped, LOCK must point to a test lock file).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
E=${1:?usage: h1-main.sh <evidence root>}
H=$(cd "$(dirname "$0")" && pwd) P=/home/comsys/sungsu/destijl-control
G=$H/../vectordb/host-gate.sh PG=$H/../vectordb/pretouch-gate.sh
PLAN=${H1_PLAN:-$H/h1-plan.tsv} SLO_ROUNDS=${SLO_ROUNDS:-1} FIX_REPS=${FIX_REPS:-1} DRY=${H1_DRY:-0}
export H1_SEED_BASE=${H1_SEED_BASE:-20261017}
OWNER=H1-main
[[ $SLO_ROUNDS =~ ^[1-3]$ ]] && [[ $FIX_REPS =~ ^[1-3]$ ]] || { echo "SEQUENCE STOP: SLO_ROUNDS / FIX_REPS must be 1..3"; exit 2; }
[ -d "$E" ] && [ -z "$(ls -A "$E" | grep -v '^sequence')" ] || { echo "SEQUENCE STOP: $E missing or not empty"; exit 2; }
[ -f "$PLAN" ] || { echo "SEQUENCE STOP: no plan $PLAN"; exit 2; }
if [ "$DRY" = 1 ]; then
  case "${LOCK:-}" in */h1-main/*) ;; *) echo "SEQUENCE STOP: H1_DRY=1 needs LOCK=<test lock under workspaces/h1-main/>"; exit 2;; esac
else
  : "${PRETOUCH_DIR:?PRETOUCH_DIR = ENV-pretouch evidence dir of the current QEMU lifetime}" "${MEASURE_ENV_DIR:?}"
  export PRETOUCH_DIR MEASURE_ENV_DIR
fi
ALL=$(awk -F'\t' '!/^#/ && NF { if (!s[$1]++) printf "%s ", $1 }' "$PLAN")
WL=${WORKLOADS:-$ALL}
for w in $WL; do [[ " $ALL " == *" $w "* ]] || { echo "SEQUENCE STOP: workload $w not in the plan"; exit 2; }; done
if [ -n "${START_AT:-}" ]; then
  [[ " $WL " == *" $START_AT "* ]] || { echo "SEQUENCE STOP: START_AT $START_AT not in [$WL]"; exit 2; }
  WL=$(echo "$WL" | awk -v s="$START_AT" '{ for (i = 1; i <= NF; i++) if ($i == s) f = 1; if (f) printf "%s ", $i }' RS=' ')
fi
log() { echo "$(date -Is) $*" | tee -a "$E/h1-state.txt"; }
stop() { log "SEQUENCE STOP $*"; exit 1; }
bash $G lock $OWNER || { echo "SEQUENCE STOP: lock"; exit 2; }
trap 'bash $G unlock $OWNER' EXIT
{ echo "# H1 main manifest"; echo "start=$(date -Is)"; echo "cxl_swmc_commit=$(git -C $H rev-parse HEAD 2>/dev/null)"
  echo "cxl_swmc_dirty_h1=$(git -C $H status --porcelain -- . | wc -l)"; echo "plan=$PLAN sha256=$(sha256sum < "$PLAN" | cut -c1-64)"
  echo "h1_main_sha256=$(sha256sum < "$0" | cut -c1-64) hook_sha256=$(sha256sum < $H/hook.sh | cut -c1-64)"
  echo "levels_sha256=$(sha256sum < $H/levels.py | cut -c1-64) collect_sha256=$(sha256sum < $H/collect.py | cut -c1-64)"
  echo "workloads=$WL start_at=${START_AT:-} slo_rounds=$SLO_ROUNDS fix_reps=$FIX_REPS seed_base=$H1_SEED_BASE dry=$DRY"
  echo "pretouch_dir=${PRETOUCH_DIR:-} measure_env_dir=${MEASURE_ENV_DIR:-}"
  for w in $WL; do f=$H/plugins/pins-$w.sh; [ "$DRY" = 1 ] && f=$H/plugins/pins-stub.sh
    echo "pins.$w=$f sha256=$(sha256sum < "$f" 2>/dev/null | cut -c1-64)"; done; } > "$E/h1-manifest.txt"
gates() {  # tag
  if [ "$DRY" = 1 ]; then log "gate $1: DRY (pretouch and Host gates skipped)"; return 0; fi
  bash $PG "$PRETOUCH_DIR" "$E/pretouch-gate.txt" > /dev/null || stop "pretouch gate ($1; see pretouch-gate.txt)"
  MEASURE_ENV_DIR=$MEASURE_ENV_DIR bash $G check "$E/gate-$1.txt" || stop "host gate ($1)"
  log "gate $1: PASS"
}
log "H1 main start: workloads [$WL] slo_rounds=$SLO_ROUNDS fix_reps=$FIX_REPS"
for W in $WL; do
  T0=$(date +%s)
  MIXES=$(awk -F'\t' -v w="$W" '!/^#/ && $1 == w { printf "%s=%s ", $2, $3 }' "$PLAN")
  mkdir "$E/$W" || stop "mkdir $E/$W"
  gates "$W-start"
  for r in $(seq 1 $SLO_ROUNDS); do
    log "$W slo round $r: mixes [$MIXES]"
    mkdir "$E/$W/slo-r$r" && bash $H/hook.sh "$W" slo "$E/$W/slo-r$r" "$r" "$MIXES" || stop "$W slo round $r"
  done
  python3 -B $H/levels.py --plan "$PLAN" --workload "$W" --out "$E/$W/levels.tsv" $(for r in $(seq 1 $SLO_ROUNDS); do echo "$E/$W/slo-r$r"; done) \
    > "$E/$W/levels.log" 2>&1 || stop "$W levels: $(tail -n 1 "$E/$W/levels.log")"
  log "$W levels: $(grep -c . "$E/$W/levels.tsv") lines (levels.tsv)"
  for k in $(seq 1 $FIX_REPS); do
    log "$W fix rep $k"
    mkdir "$E/$W/fix-r$k" && bash $H/hook.sh "$W" fix "$E/$W/fix-r$k" "$k" "$E/$W/levels.tsv" || stop "$W fix rep $k"
  done
  gates "$W-end"
  nice -n 19 python3 -B $H/collect.py --plan "$PLAN" --workload "$W" ${H1_NO_FIGS:+--no-figs} "$E/$W" > "$E/$W/collect.log" 2>&1 \
    || stop "$W collect: $(tail -n 1 "$E/$W/collect.log")"
  log "$W DONE ($(( ($(date +%s) - T0) / 60 )) min): $(tail -n 1 "$E/$W/collect.log")"
done
log "SEQUENCE DONE $OWNER"
