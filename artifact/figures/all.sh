#!/bin/bash
# Every figure of de-stijl-motivation-isca27 (Figs 1-8 with their variants) in one plot pass, plus index.md and
#   all-final.html (captions with the numbers) and numbers.json. Same options as fig<N>.sh; with --measure each stage
#   (h1-slo-fixed, h2-slo, knee-sweep) runs once for all figures and skips what exists.
# usage: all.sh [--reprocess | --measure [--redo]] [--reexport] [--runs N] [--data DIR] [--knee DIR] [--plan CSV]
#               [--evidence-map OLD=NEW] [--out DIR] [--dry-run]
set -euo pipefail
AF_SELF=$0 AF_FIG=all AF_NEEDS="h1 h2 knee"
AF_STAGE_LIST="h1-slo-fixed:fig1,fig2,fig3 h2-slo:fig4,fig5,fig6,fig7,fig8 knee-sweep:fig1,fig4"
AF_TITLE="All figures (Figs 1-8) + index.md"
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
af_main "$@"
echo "== index"
af_run $ARTIFACT_PY "$AF_PLOT/gen_index_final.py" "$AF_OUT"
