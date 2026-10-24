#!/bin/bash
# Fig 6 (Hypothesis 2): Popcorn page faults at its max-under-SLO step vs N = 2/4/8, per mix, mean over runs, log y.
#   6a: read and write faults per second (sum over the N VMs); 6b: read faults per search query (read faults/s /
#   max-under-SLO search/s).
# Inputs: stage h2-slo (summary.csv of runs 1..N). Outputs: fig6a-h2-popcorn-faults-per-s.{pdf,png},
#   fig6b-h2-popcorn-read-faults-per-search.{pdf,png}, fig6-h2-popcorn-faults.csv, numbers-fig6.json, fig6.manifest.txt.
# usage: fig6.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--evidence-map OLD=NEW]
#                [--out DIR] [--dry-run]                                     (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig6 AF_NEEDS="h2"
AF_STAGE_LIST="h2-slo:fig4,fig5,fig6,fig7,fig8"
AF_TITLE="Fig 6: H2 Popcorn faults (6a per second, 6b read faults per search)"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
