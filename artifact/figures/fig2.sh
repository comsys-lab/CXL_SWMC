#!/bin/bash
# Fig 2 (Hypothesis 1): normalized search latency at the fixed loads L1 and L2 (two figures), per mix, All-HWcc /
#   Megalon / Popcorn bars split into coherence management and query processing. L1 = Megalon's max under SLO of that
#   run, L2 = L1/2; per run normalized to that run's All-HWcc time per search, then the mean over runs. Megalon = its
#   run without section timers (coherence = its time - All-HWcc's, upper bound); Popcorn = kernel counters.
# Inputs: stage h1-slo-fixed (fixed.csv of runs 1..N). Outputs: fig2-h1-search-breakdown-{L1,L2}.{pdf,png},
#   fig2-h1-search-breakdown.csv, numbers-fig2.json, fig2.manifest.txt.
# usage: fig2.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--evidence-map OLD=NEW]
#                [--out DIR] [--dry-run]                                     (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig2 AF_NEEDS="h1"
AF_STAGE_LIST="h1-slo-fixed:fig1,fig2,fig3"
AF_TITLE="Fig 2: H1 normalized search latency breakdown at L1 and L2"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
