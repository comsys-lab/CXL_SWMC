#!/bin/bash
# H1-HOOK v2, r1 Megalon lifetime (v6-block.sh h1_life ... cb; run.sh PART_RATES_CMD): called inside the mg lifetime
# after its slo part ended. Appends the slo line of that part to <dir>/h1-runs.tsv (the levels callback reads the hw,
# pop and mg SLO lines of the mix), then runs "$H1_LEVELS_CMD <mix>" and passes its single stdout line "<L2> <L1>" on.
# Non-zero exit (missing slo output or a LEVELS STOP of the callback) = run.sh stops the lifetime (LEVELS STOP).
# usage: h1-rates.sh <dir> <sys> <mix> <lifetime> <sep|cont> <round>      env: H1_LEVELS_CMD (+ its own env)
set -uo pipefail
D=${1:?} S=${2:?} M=${3:?} L=${4:?} LIFE=${5:?} N=${6:?}
: "${H1_LEVELS_CMD:?}"
[ -s "$D/$L/slo/loadgen/summary.json" ] && [ -s "$D/$L/slo/loadgen/steps.jsonl" ] || { echo "h1-rates: no slo output in $D/$L/slo" >&2; exit 1; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$S-$M-slo-r$N" "$S" "$M" slo "$N" "$L/slo" - "$LIFE" >> "$D/h1-runs.tsv"
echo "$(date -Is) h1-rates $L: slo line appended, levels callback $H1_LEVELS_CMD $M" >> "$D/h1-rates.log"
out=$("$H1_LEVELS_CMD" "$M" 2>> "$D/h1-rates.log"); rc=$?
echo "$(date -Is) h1-rates $L: rc=$rc out=[$out]" >> "$D/h1-rates.log"
[ $rc = 0 ] || exit $rc
echo "$out"
