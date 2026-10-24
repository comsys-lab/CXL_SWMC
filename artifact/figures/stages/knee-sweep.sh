#!/bin/bash
# Stage knee-sweep: fixed-rate points past the knee for the latency-throughput curves (reports/experiments/knee-sweep.md).
#   Feeds Fig 1 (group knee-sweep-h1) and Fig 4 (knee-sweep-h2-n2/4/8 + addendum knee-sweep-h2-n4-v2/-n8-v2). One
#   repetition (seed of run 1), not per run: --runs only checks that the plan's base was built from runs 1..N.
#   Needs the plan KNEE_PLAN (experiments/eval/knee-sweep-plan.csv: base = mean confirmed max under SLO of runs 1-3 from
#   stages h1-slo-fixed + h2-slo; its rates are in the H2N_FIXED tokens of knee-sweep-h1.conf / knee-sweep-h2.conf).
#   main      <KNEE_CHAIN_V1>: H1 on the 2-VM topology (cxl_vm0/1 16 vCPU), then VM8 switch, N = 2/4/8, restore,
#             knee_pilot_export.py -> $KNEE_DERIVED/<group>/knee-pilot.csv. ~7.6 h (2026-10-24: 7 h 35 min).
#             Needs KS_H1_PRETOUCH_DIR = the pretouch evidence of the current 2-VM QEMU lifetime (e.g. the newest
#             recovery/VM8-v4-*-restore dir).
#   addendum  <KNEE_CHAIN_V2>: Popcorn H2 u90 N = 4 and 8 only, factors 1.00-1.30 (knee-sweep-h2-addendum.conf); VM8
#             switch + restore. ~35 min (2026-10-24: 33 min). Supplies the collapse step of Fig 4 u90 N=4/8 Popcorn.
#   A part whose exports exist is skipped (--redo: measured again; the chains write new evidence versions).
# Regenerating the plan for other runs (methodology input; not automated here): cross-run bases
#   (<DESTIJL_ROOT>/workspaces/knee-sweep-design/cross_runs.py, reads runs 1-3) -> experiments/eval/knee_sweep_plan.py
#   <cross_runs.csv> <plan csv> -> paste its printed H2N_FIXED tokens into knee-sweep-h1.conf / knee-sweep-h2.conf.
# usage: knee-sweep.sh [--runs N] [--dry-run] [--redo]        (Main session only.)
set -uo pipefail
AF_SELF=$0
# shellcheck source=../common.sh
. "$(dirname "$(readlink -f "$0")")/../common.sh"
af_stage_parse "$@"
af_stage_pre "$KNEE_CHAIN_V1" "$KNEE_CHAIN_V2"
[ -s "$KNEE_PLAN" ] || af_die "knee-sweep plan $KNEE_PLAN missing (see the header: regenerate from the SLO runs)"
pr=$(awk -F, 'NR > 1 { print $7 }' "$KNEE_PLAN" | sort -u | tr '\n' ' ')
if [ "$pr" != "$AF_NRUNS " ]; then
  if [ "$AF_DRY" = 1 ] || [ "${KNEE_PLAN_ACCEPT:-0}" = 1 ]; then
    af_say "NOTE: plan $KNEE_PLAN was built from runs [${pr% }], not 1..$AF_NRUNS: regenerate it first (header) or set KNEE_PLAN_ACCEPT=1"
  else af_die "plan $KNEE_PLAN was built from runs [${pr% }], not 1..$AF_NRUNS (regenerate it, or KNEE_PLAN_ACCEPT=1)"; fi
else af_say "plan $KNEE_PLAN: base from runs 1..$AF_NRUNS"; fi
if af_have_knee main && [ "$AF_REDO" = 0 ]; then
  af_say "main sweep: exports present ($KNEE_DERIVED/{${KNEE_MAIN_GROUPS// /,}}): skipped"
else
  if [ -z "${KS_H1_PRETOUCH_DIR:-}" ]; then
    [ "$AF_DRY" = 1 ] || af_die "set KS_H1_PRETOUCH_DIR (pretouch evidence of the current 2-VM QEMU lifetime)"
    af_say "NOTE: a real run needs KS_H1_PRETOUCH_DIR (pretouch evidence of the current 2-VM QEMU lifetime)"
  fi
  af_say "main sweep: H1 2-VM + H2 N = 2/4/8 (VM8 switch + restore), ~7.6 h; log $AF_LOGDIR/knee-sweep-main.log"
  if [ "$AF_DRY" = 1 ]; then
    af_run env LS_TREE="$MEASURE_TREE" KS_H1_PRETOUCH_DIR="${KS_H1_PRETOUCH_DIR:-<required>}" bash "$KNEE_CHAIN_V1"
  else
    af_run env LS_TREE="$MEASURE_TREE" KS_H1_PRETOUCH_DIR="$KS_H1_PRETOUCH_DIR" bash "$KNEE_CHAIN_V1" \
      >> "$AF_LOGDIR/knee-sweep-main.log" 2>&1 < /dev/null
    tail -n 1 "$AF_LOGDIR/knee-sweep-main.log" | grep -q "CHAIN DONE" || af_die "main sweep: $(tail -n 1 "$AF_LOGDIR/knee-sweep-main.log")"
  fi
fi
if af_have_knee addendum && [ "$AF_REDO" = 0 ]; then
  af_say "addendum: exports present ($KNEE_DERIVED/{${KNEE_ADD_GROUPS// /,}}): skipped"
else
  af_say "addendum: Popcorn H2 u90 N = 4/8 (VM8 switch + restore), ~35 min; log $AF_LOGDIR/knee-sweep-addendum.log"
  if [ "$AF_DRY" = 1 ]; then
    af_run env LS_TREE="$MEASURE_TREE" bash "$KNEE_CHAIN_V2"
  else
    af_run env LS_TREE="$MEASURE_TREE" bash "$KNEE_CHAIN_V2" >> "$AF_LOGDIR/knee-sweep-addendum.log" 2>&1 < /dev/null
    tail -n 1 "$AF_LOGDIR/knee-sweep-addendum.log" | grep -q "CHAIN DONE" || af_die "addendum: $(tail -n 1 "$AF_LOGDIR/knee-sweep-addendum.log")"
  fi
fi
af_say "stage knee-sweep $([ "$AF_DRY" = 1 ] && echo 'planned (dry run)' || echo done)"
