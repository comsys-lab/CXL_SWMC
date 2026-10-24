#!/bin/bash
# Fig 4 (Hypothesis 2): normalized p99 search latency vs aggregate searches/s, 3 x 3 panels (mix u10/u50/u90 x
#   N = 2/4/8 VMs of 4 vCPU, SQ8 vector DB), All-HWcc / Popcorn / Megalon. Also the requests/s variant and the band
#   variant (mean of all runs; secondary). Curve rule as Fig 1 (run 1 below 0.9 x base, knee sweep above); x range
#   shared per row; vertical unmarked segment where the curve ended at a collapsed step above the y top (main sweep, else
#   the addendum lifetime: Popcorn u90 N = 4/8).
# Inputs: stage h2-slo (runs 1..N: summary.csv + the run-1 loadgen steps) and stage knee-sweep (main H2 groups +
#   addendum + plan). Outputs: fig4-h2-latency{,-req,-band}.{pdf,png,csv}, numbers-fig4.json, fig4.manifest.txt.
# usage: fig4.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--knee DIR] [--plan CSV]
#                [--evidence-map OLD=NEW] [--out DIR] [--dry-run]          (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig4 AF_NEEDS="h2 knee"
AF_STAGE_LIST="h2-slo:fig4,fig5,fig6,fig7,fig8 knee-sweep:fig1,fig4"
AF_TITLE="Fig 4: H2 latency-throughput 3 x 3 (search/s and requests/s; band variant)"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
