#!/bin/bash
# Fig 3 (Hypothesis 1): average flushed cache lines per search query at L1 and L2 (two figures), Megalon and Popcorn
#   per mix, log y (All-HWcc = 0, stated in the caption). fixed.csv fig3_lines_per_rop (search-only attribution):
#   Megalon = search stale/concurrent read events x read-side flush bytes per flush / 64; Popcorn = search I->S faults
#   x 4096 / 64. Mean over runs.
# Inputs: stage h1-slo-fixed (fixed.csv of runs 1..N). Outputs: fig3-h1-flushed-lines-per-search-{L1,L2}.{pdf,png},
#   fig3-h1-flushed-lines-per-search.csv, numbers-fig3.json, fig3.manifest.txt.
# usage: fig3.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--evidence-map OLD=NEW]
#                [--out DIR] [--dry-run]                                     (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig3 AF_NEEDS="h1"
AF_STAGE_LIST="h1-slo-fixed:fig1,fig2,fig3"
AF_TITLE="Fig 3: H1 flushed cache lines per search at L1 and L2"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
