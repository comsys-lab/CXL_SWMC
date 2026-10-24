#!/bin/bash
# Stage h2-slo: Hypothesis 2 SLO searches at N = 2, 4, 8 VMs of runs 1..N.
#   Feeds Fig 4 (curves below 0.9 x base, band variant), Fig 5, Fig 6a/6b, Fig 7, Fig 8, and the knee-sweep plan base.
#   Topology: switch to the VM8 XMLs (cxl_vm0..7, 4 vCPU / 24 GB each), blocks N = 2, 4, 8, restore to cxl_vm0/cxl_vm1
#   16 vCPU at the end; SQ8 index, ef 24; u10 u50 u90 x All-HWcc, Megalon, Popcorn. ~7-8.5 h per run.
#   Per run k: env EVAL_CONF=eval2-h2.conf H2N_TREE=<MEASURE_TREE> <H2N_CHAIN> --run k (install, switch, N = 2/4/8
#   blocks = runset-h2n.sh N k, loadgen seed SEED_BASE + k, restore, export_h2n.py per N + --combine) -> evidence
#   recovery/eval2-run<k>-h2-n<N>-v<V>, export $EVAL2_DERIVED/h2/vdb/h2n/run<k> (summary.csv, steps.csv, fig8.csv).
#   Log: $ARTIFACT_LOG_DIR/run<k>-h2.log. A run whose combined export exists is skipped (--redo: measured again).
# usage: h2-slo.sh [--runs N] [--dry-run] [--redo]
# Main session only. The chain is fail-closed on switch / restore (operator rollback) and resumable with --start
# (see its header); a failed N block is logged with its RESUME line.
set -uo pipefail
AF_SELF=$0
# shellcheck source=../common.sh
. "$(dirname "$(readlink -f "$0")")/../common.sh"
af_stage_parse "$@"
af_stage_pre "$H2N_CHAIN"
for k in $(af_runs); do
  if af_have_h2 "$k" && [ "$AF_REDO" = 0 ]; then
    af_say "run $k: H2 export present ($EVAL2_DERIVED/h2/vdb/h2n/run$k): skipped"; continue
  fi
  af_chain_run_ok "$k"
  af_say "run $k: H2 N = 2/4/8 (VM8 switch + restore, ~7-8.5 h; seed SEED_BASE + $k); log $AF_LOGDIR/run$k-h2.log"
  if [ "$AF_DRY" = 1 ]; then
    af_run env EVAL_CONF="$MEASURE_TREE/experiments/eval/eval2-h2.conf" H2N_TREE="$MEASURE_TREE" bash "$H2N_CHAIN" --run "$k"
  else
    af_run env EVAL_CONF="$MEASURE_TREE/experiments/eval/eval2-h2.conf" H2N_TREE="$MEASURE_TREE" bash "$H2N_CHAIN" --run "$k" \
      >> "$AF_LOGDIR/run$k-h2.log" 2>&1 < /dev/null || af_die "run $k: H2 chain failed (see $AF_LOGDIR/run$k-h2.log)"
    af_have_h2 "$k" || af_die "run $k: chain ended but $EVAL2_DERIVED/h2/vdb/h2n/run$k is incomplete"
  fi
done
af_say "stage h2-slo $([ "$AF_DRY" = 1 ] && echo 'planned (dry run)' || echo done)"
