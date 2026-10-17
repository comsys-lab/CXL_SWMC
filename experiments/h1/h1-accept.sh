#!/bin/bash
# Record the main session's acceptance of one H1 main stage result (user decision 2026-10-17: each workload's round-1
# result is checked by the main session before the next workload starts; rounds 2/3 only after all four r1 pass).
# usage: h1-accept.sh <evidence root E> <round n> <workload W> [<free-text remark>] [--user-ack "<state/TASKS.md ref>"]
# check.txt REPORT lines (separate vs continuous beyond the run-to-run spread, user decision 2026-10-18) must be seen
# by the user before r3: with REPORT lines the record needs --user-ack naming the user's decision in state/TASKS.md.
# Refuses unless <E>/<W>/r<n>/check.txt ends with "H1CHECK PASS" and no accept record exists yet. Writes
# <E>/accept/r<n>-<W>.txt with the check.txt sha256 (h1-main.sh re-verifies it) and the WARN lines it accepted.
# Run only by the main session after reading check.txt (WARN lines are judgment items for the main session/user).
set -uo pipefail
E=${1:?} N=${2:?} W=${3:?} REMARK=${4:-} ACK=
[ "${5:-}" = --user-ack ] && ACK=${6:?--user-ack needs a reference}
C=$E/$W/r$N/check.txt A=$E/accept/r$N-$W.txt
[ -f "$C" ] && tail -n 1 "$C" | grep -q "^H1CHECK PASS" || { echo "ACCEPT REFUSED: $C missing or not PASS"; exit 1; }
[ ! -e "$A" ] || { echo "ACCEPT REFUSED: $A exists"; exit 1; }
if grep -q "^REPORT" "$C" && [ -z "$ACK" ]; then
  echo "ACCEPT REFUSED: $C has REPORT lines (separate vs continuous); report to the user, then --user-ack \"<TASKS.md ref>\""; exit 1
fi
mkdir -p "$E/accept"
{ echo "ACCEPT r$N $W $(date -Is) by main session check_sha256=$(sha256sum < "$C" | cut -c1-64)"
  echo "remark=$REMARK"; [ -z "$ACK" ] || echo "user_ack=$ACK"
  grep "^WARN\|^REPORT" "$C" | sed 's/^/accepted: /'; } > "$A"
echo "ACCEPTED r$N $W -> $A"
