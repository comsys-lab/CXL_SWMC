#!/bin/bash
# Record the main session's acceptance of one H1 main stage result (user decision 2026-10-17: each workload's round-1
# result is checked by the main session before the next workload starts; rounds 2/3 of a workload only after its r1
# is accepted, H1 v0.6.5).
# usage: h1-accept.sh <evidence root E> <round n> <workload W> [<free-text remark>] [--user-ack "<state/TASKS.md ref>"]
# check.txt REPORT lines (separate vs continuous beyond the run-to-run spread, user decision 2026-10-18) must be seen
# by the user before r3: with REPORT lines the record needs --user-ack naming the user's decision in state/TASKS.md.
# Refuses unless <E>/<W>/r<n>/check.txt ends with "H1CHECK PASS" and no accept record exists yet. Writes
# <E>/accept/r<n>-<W>.txt with the check.txt sha256 (h1-main.sh re-verifies it) and the WARN lines it accepted.
# Run only by the main session after reading check.txt (WARN lines are judgment items for the main session/user).
#        h1-accept.sh <E> 1 <W> --skip "<reason>"   (user decision 2026-10-18: overnight runs never sit idle)
# --skip (round 1 only): the r1 stage of W ended in STOP / check FAIL / REPORT / an unexplained WARN and main moves on
# to the next r1 stage. Writes <E>/accept/r1-<W>-skip.txt (reason, time, check.txt sha256 or "none", stage log
# references); never the acceptance record. Refused if r1-<W>.txt (accepted) or a skip record already exists.
# h1-main.sh lets the NEXT r1 stage start on it; r2/r3 refuse a skipped workload (r1 accepted for each chosen workload;
# a skipped workload's r1 is re-run in a new evidence root).
# v0.6.8: <E>/<W>/r<n> means the CURRENT attempt of the round (attempts.py; <E>/<W>/r<n>-a<k> after
# `h1-main.sh --retry`); the record names the attempt dir (attempt=...). The record path stays <E>/accept/r<n>-<W>.txt.
#        h1-accept.sh <E> <n> <W> --invalid "<reason>"   (v0.6.9, user decision 2026-10-18: H1 RecSys r2 at T = 60 s
#                                                     recorded invalid, a round-phase artifact)
# --invalid (any round): records that round n of W is NOT used (e.g. measured under conditions the user has since
# replaced). Writes <E>/accept/r<n>-<W>-invalid.txt (reason, time, attempt, check.txt sha256 or "none", last check
# line, state tail); nothing is deleted. Refused if the round is accepted (an accepted r1 is superseded instead:
# h1-main.sh --from-root) or already has an invalid record. An invalid round is never accepted afterwards, and
# h1-main.sh's accepted() is false for it (r<n+1> of W refused in E). Acceptance and --skip are refused for a round
# with a supersession or invalid record.
set -uo pipefail
E=${1:?} N=${2:?} W=${3:?} REMARK=${4:-} ACK=
H=$(cd "$(dirname "$0")" && pwd)
RD=$(python3 -I -B $H/attempts.py dir "$E" "$W" "$N" 2>&1); ARC=$?
[ $ARC != 2 ] || { echo "REFUSED: $RD"; exit 1; }
[ $ARC = 0 ] || RD=$E/$W/r$N
for x in superseded invalid; do
  if [ -e "$E/accept/r$N-$W-$x.txt" ]; then
    [ "$REMARK" = --invalid ] && [ $x = superseded ] && { echo "INVALID REFUSED: r$N $W is superseded ($E/accept/r$N-$W-$x.txt)"; exit 1; }
    echo "REFUSED: r$N $W has a $x record ($E/accept/r$N-$W-$x.txt)"; exit 1
  fi
done
if [ "$REMARK" = --invalid ]; then
  R=${5:?--invalid needs a reason}
  A=$E/accept/r$N-$W.txt I=$E/accept/r$N-$W-invalid.txt C=$RD/check.txt
  [ ! -e "$A" ] || { echo "INVALID REFUSED: $A exists (r$N $W is accepted; an accepted r1 is superseded with h1-main.sh --from-root)"; exit 1; }
  [ -d "$RD" ] || { echo "INVALID REFUSED: $RD missing"; exit 1; }
  mkdir -p "$E/accept"
  ( set -o noclobber
    { echo "INVALID r$N $W $(date -Is) by main session (not used; nothing deleted)"; echo "reason=$R"
      echo "attempt=${RD#$E/}"; echo "check_sha256=$([ -f "$C" ] && sha256sum < "$C" | cut -c1-64 || echo none)"
      echo "check_last=$([ -f "$C" ] && tail -n 1 "$C" || echo none)"
      echo "files=$(find "$RD" -type f | wc -l) listing_sha256=$(cd "$RD" && find . -type f -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -c1-64)"
      grep "\[r$N\(-$W\)\?\]" "$E/h1-state.txt" 2>/dev/null | tail -n 3 | sed 's/^/state_tail: /'; } > "$I" ) \
    || { echo "INVALID REFUSED: cannot write $I"; exit 1; }
  echo "INVALID r$N $W -> $I"; exit 0
fi
if [ "$REMARK" = --skip ]; then
  R=${5:?--skip needs a reason}
  [ "$N" = 1 ] || { echo "SKIP REFUSED: --skip is for round 1 only (r2/r3 need r1 accepted for each chosen workload)"; exit 1; }
  A=$E/accept/r1-$W.txt S=$E/accept/r1-$W-skip.txt C=$RD/check.txt
  [ ! -e "$A" ] || { echo "SKIP REFUSED: $A exists (r1 $W is accepted)"; exit 1; }
  [ ! -e "$S" ] || { echo "SKIP REFUSED: $S exists"; exit 1; }
  [ -d "$RD" ] || { echo "SKIP REFUSED: $RD missing (stage never started)"; exit 1; }
  mkdir -p "$E/accept"
  { echo "SKIP r1 $W $(date -Is) by main session (not accepted)"; echo "reason=$R"
    echo "attempt=${RD#$E/}"; echo "check_sha256=$([ -f "$C" ] && sha256sum < "$C" | cut -c1-64 || echo none)"
    echo "check_last=$([ -f "$C" ] && tail -n 1 "$C" || echo none)"
    echo "stage_log=$E/sequence-r1-$W.log state_log=$E/h1-state.txt"
    grep "\[r1-$W\]" "$E/h1-state.txt" 2>/dev/null | tail -n 3 | sed 's/^/state_tail: /'; } > "$S"
  echo "SKIPPED r1 $W -> $S"; exit 0
fi
[ "${5:-}" = --user-ack ] && ACK=${6:?--user-ack needs a reference}
C=$RD/check.txt A=$E/accept/r$N-$W.txt
[ -f "$C" ] && tail -n 1 "$C" | grep -q "^H1CHECK PASS" || { echo "ACCEPT REFUSED: $C missing or not PASS"; exit 1; }
[ ! -e "$A" ] || { echo "ACCEPT REFUSED: $A exists"; exit 1; }
[ ! -e "$E/accept/r$N-$W-skip.txt" ] || { echo "ACCEPT REFUSED: r$N $W was skipped ($E/accept/r$N-$W-skip.txt)"; exit 1; }
if grep -q "^REPORT" "$C" && [ -z "$ACK" ]; then
  echo "ACCEPT REFUSED: $C has REPORT lines (separate vs continuous); report to the user, then --user-ack \"<TASKS.md ref>\""; exit 1
fi
mkdir -p "$E/accept"
{ echo "ACCEPT r$N $W $(date -Is) by main session check_sha256=$(sha256sum < "$C" | cut -c1-64)"
  echo "remark=$REMARK"; echo "attempt=${RD#$E/}"; [ -z "$ACK" ] || echo "user_ack=$ACK"
  grep "^WARN\|^REPORT" "$C" | sed 's/^/accepted: /'; } > "$A"
echo "ACCEPTED r$N $W -> $A"
