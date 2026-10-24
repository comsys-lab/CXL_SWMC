#!/bin/bash
# Fig 7 (Hypothesis 2): Megalon stale-object fetches per operation (megalon.read_retry_incoherent / achieved ops) at
#   its max-under-SLO step, or at the lowest ramp step where no rate met the SLO (hatched when that holds in at least one
#   run), vs N = 2/4/8 per mix, mean over runs, log y.
# Inputs: stage h2-slo (summary.csv of runs 1..N). Outputs: fig7-h2-megalon-fetches-per-op.{pdf,png,csv},
#   numbers-fig7.json, fig7.manifest.txt.
# usage: fig7.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--evidence-map OLD=NEW]
#                [--out DIR] [--dry-run]                                     (options: common.sh / README.md)
set -euo pipefail
AF_SELF=$0 AF_FIG=fig7 AF_NEEDS="h2"
AF_STAGE_LIST="h2-slo:fig4,fig5,fig6,fig7,fig8"
AF_TITLE="Fig 7: H2 Megalon stale-object fetches per operation vs N"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
