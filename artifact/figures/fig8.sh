#!/bin/bash
# Fig 8 (Hypothesis 2): Popcorn search time by cause, 100 % stacked, vs N = 2/4/8 per mix, at Popcorn's own max under
#   SLO (its 90 s confirm window at the confirmed rate: steps.csv at_result). Server search time W split into search
#   page faults (C + NT), segment write-lock wait, E1 (write-order) wait, run-queue delay, query processing (rest);
#   per run by plot/cause_agg.py from the evidence counters (opsplit-steps.csv, stats-steps.csv), mean shares over runs
#   renormalized to 100. Secondary variants: the same load in every run (-common-load) and each run's per_n step
#   (-perrun-load).
# Inputs: stage h2-slo (steps.csv of runs 1..N + the Popcorn evidence counters behind summary.csv source_dir).
# Outputs: fig8-h2-popcorn-search-time-share{,-common-load,-perrun-load}.{pdf,png,csv},
#   fig8-h2-loads{,-common-load,-perrun-load}.csv, numbers-fig8.json, fig8.manifest.txt.
# usage: fig8.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--evidence-map OLD=NEW]
#                [--out DIR] [--dry-run]                                     (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig8 AF_NEEDS="h2"
AF_STAGE_LIST="h2-slo:fig4,fig5,fig6,fig7,fig8"
AF_TITLE="Fig 8: H2 Popcorn search-time shares at Popcorn's max under SLO"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
