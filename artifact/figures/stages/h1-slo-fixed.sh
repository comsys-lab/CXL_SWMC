#!/bin/bash
# Stage h1-slo-fixed: Hypothesis 1 SLO searches + fixed-load windows (L1, L2 = L1/2) of runs 1..N.
#   Feeds Fig 1 (curves below 0.9 x base, max under SLO, band variant), Fig 2, Fig 3, and the knee-sweep plan base.
#   Topology: cxl_vm0 + cxl_vm1, 16 vCPU / 96 GB each (the 2-VM state); fp32 index; u10 u50 u90 x All-HWcc, Popcorn,
#   Megalon (+ Megalon without section timers in the fixed windows). ~3.9-4.6 h per run.
#   Per run k: <RUNS123_CHAIN> --run k --h1-only = experiments/eval/runset-vdb.sh k with eval2-h1.conf (loadgen seed
#   SEED_BASE + k), evidence recovery/eval2-run<k>-h1-n2-v<V>, export experiments/vectordb/export.py ->
#   $EVAL2_DERIVED/h1/vdb/vdb/run<k>-chain (slo_summary.csv, fixed.csv). Log: <EVAL2_RUN_DIR>/run<k>.log
#   (EVAL2_RUN_DIR [$DESTIJL_ROOT/workspaces/runs123], experiments/chains/README.md).
#   A run whose export exists is skipped (--redo: measured again as a new evidence version).
# usage: h1-slo-fixed.sh [--runs N] [--dry-run] [--redo]
# Main session only (VMs, sudo, CXL device inside the approved experiment); the chain refuses with MEASUREMENT.lock,
# a dirty live tree, or a live HEAD other than runs 1-3's (EVAL2_ALLOW_HEAD_CHANGE=1).
set -uo pipefail
AF_SELF=$0
# shellcheck source=../common.sh
. "$(dirname "$(readlink -f "$0")")/../common.sh"
af_stage_parse "$@"
af_stage_pre "$RUNS123_CHAIN"
for k in $(af_runs); do
  if af_have_h1 "$k" && [ "$AF_REDO" = 0 ]; then
    af_say "run $k: H1 export present ($EVAL2_DERIVED/h1/vdb/vdb/run$k-chain): skipped"; continue
  fi
  af_chain_run_ok "$k"
  af_say "run $k: H1 SLO + fixed windows (2-VM topology, ~3.9-4.6 h; seed SEED_BASE + $k)"
  af_run bash "$RUNS123_CHAIN" --run "$k" --h1-only || af_die "run $k: H1 chain failed (see ${EVAL2_RUN_DIR:-$DESTIJL_ROOT/workspaces/runs123}/run$k.log)"
  [ "$AF_DRY" = 1 ] || af_have_h1 "$k" || af_die "run $k: chain ended but $EVAL2_DERIVED/h1/vdb/vdb/run$k-chain is incomplete"
done
af_say "stage h1-slo-fixed $([ "$AF_DRY" = 1 ] && echo 'planned (dry run)' || echo done)"
