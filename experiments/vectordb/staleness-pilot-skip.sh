#!/bin/bash
# run.sh PART_SKIP_CMD of the vector-db-staleness-recall pilot (h2n-block.sh H2N_FIXED_SKIP_CMD): the pilot's update
# steps run in order inside ONE server lifetime and stop at the first step whose update stream was not sustained.
# usage: staleness-pilot-skip.sh <part>   env: FIXED_RUN_DIR (run.sh run dir), FIXED_PARTS (the lifetime's parts in order)
# rc 0 = skip <part> (the previous part was skipped, its loadgen failed, or urate_check.py judged its measured step
# invalid); rc 1 = run it (the first part, or the previous part's step is valid); rc 2 = bad input (run.sh stops).
# Host only: reads the previous part's loadgen output and stats snapshots (urate_check.py), never contacts a VM.
set -uo pipefail
P_=${1:?part}
: "${FIXED_RUN_DIR:?}" "${FIXED_PARTS:?}"
XV=$(cd "$(dirname "$0")" && pwd)
prev=
for q in $FIXED_PARTS; do [ "$q" = "$P_" ] && break; prev=$q; done
[[ " $FIXED_PARTS " == *" $P_ "* ]] || { echo "skip-hook: $P_ is not one of [$FIXED_PARTS]"; exit 2; }
if [ -z "$prev" ]; then echo "skip-hook $(date -Is) $P_: first part, run"; exit 1; fi
if grep -q "^part_$prev=skipped" "$FIXED_RUN_DIR/manifest.txt" 2>/dev/null; then
  echo "skip-hook $(date -Is) $P_: SKIP (previous part $prev was skipped)"; exit 0
fi
rc=$(sed -n "s/^part_${prev}_loadgen_rc=\([0-9]*\) .*/\1/p" "$FIXED_RUN_DIR/manifest.txt" | tail -n 1)
[ "$rc" = 0 ] || { echo "skip-hook $(date -Is) $P_: SKIP (previous part $prev loadgen rc '${rc:-none}')"; exit 0; }
out=$(python3 -I -B "$XV/urate_check.py" "$FIXED_RUN_DIR/$prev" --writers 4 2>&1)  # 4 writer threads (as the final judging)
echo "$out" > "$FIXED_RUN_DIR/$prev/urate-check-pilot.txt"
st=$(echo "$out" | grep '^STEP ' | tail -n 1)
if [[ $st == *" valid=True "* ]]; then echo "skip-hook $(date -Is) $P_: run (previous part $prev: $st)"; exit 1; fi
echo "skip-hook $(date -Is) $P_: SKIP (previous part $prev not sustained: ${st:-no STEP line})"; exit 0
