#!/bin/bash
# Fig 5 (Hypothesis 2): maximum aggregate searches/s under the SLO (p99 <= 100 ms) vs N = 2/4/8, per mix, All-HWcc /
#   Megalon / Popcorn bars (mean over runs). Megalon cells where no rate met the SLO show the achieved search/s of the
#   lowest ramp step, hatched, with the p99 range over runs written above.
# Inputs: stage h2-slo (summary.csv of runs 1..N). Outputs: fig5-h2-max-search-under-slo.{pdf,png,csv},
#   numbers-fig5.json, fig5.manifest.txt.
# usage: fig5.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--evidence-map OLD=NEW]
#                [--out DIR] [--dry-run]                                     (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig5 AF_NEEDS="h2"
AF_STAGE_LIST="h2-slo:fig4,fig5,fig6,fig7,fig8"
AF_TITLE="Fig 5: H2 max searches/s under SLO vs N"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
