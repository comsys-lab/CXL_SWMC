#!/bin/bash
# H1 r1 in-lifetime levels callback (H1-HOOK v2, H1_LEVELS_CMD; user decision 2026-10-18): the block calls it inside
# the Megalon lifetime of mix <mix>, right after mg's SLO search ended and its "slo" line was appended to
# <stage dir>/h1-runs.tsv (hw and pop SLO lines of the mix are already there); for a workload without Megalon (recsys,
# h1sys.py, v0.6.7) right after the hw and pop SLO-only lifetimes of the mix, outside any lifetime. It computes L1 =
# min over the workload's systems (hw, pop[, mg]) of the confirm x_mean and L2 = 0.5 x L1 for this mix (levels.py --mix, appended to the workload's levels.tsv) and prints
# one line "<L2_rate> <L1_rate>" (the block's rate arguments) on stdout. Non-zero exit = LEVELS STOP (noted or missing
# SLO run, dec Q4): the block must stop that workload (no fixed windows), roll back, and report.
# usage: levels-cb.sh <mix>     env: H1_PLAN H1_W H1_LEVELS_OUT H1_STAGE_DIR (set by h1-main.sh through the hook)
set -uo pipefail
M=${1:?mix}
: "${H1_PLAN:?}" "${H1_W:?}" "${H1_LEVELS_OUT:?}" "${H1_STAGE_DIR:?}"
H=$(cd "$(dirname "$0")" && pwd)
LOG=$(dirname "$H1_LEVELS_OUT")/levels-$M.log
python3 -I -B $H/levels.py --plan "$H1_PLAN" --workload "$H1_W" --mix "$M" --out "$H1_LEVELS_OUT" "$H1_STAGE_DIR" > "$LOG" 2>&1 \
  || { echo "LEVELS STOP $M: $(tail -n 1 "$LOG")" >&2; exit 1; }
awk -F'\t' -v m="$M" 'NR > 1 && $1 == m { print $10, $9; f = 1 } END { exit f ? 0 : 1 }' "$H1_LEVELS_OUT" \
  || { echo "LEVELS STOP $M: no row in $H1_LEVELS_OUT" >&2; exit 1; }
