#!/bin/bash
# Offline recall@10 per lifetime of an update-rate block (verifier LOW-1; DESIGN.md §17): with several writer threads
# the HNSW graphs are not reproducible record by record, so recall is measured for every system and rung on its own
# searches. For every <E>/<sys>-u<R>/slo with e1.sample.bin (m4-run.sh: 500 measured OK searches drawn by e1_check.py),
# tools/compute_gt.py on the run's own data dir and writes file (from loadgen_args in the lifetime manifest) ->
# <life>/slo/recall.{recall.txt,gt.npy,manifest.txt}. Host only, after the block (never while workspaces/MEASUREMENT.lock
# exists), node 1, nice 19. Existing outputs are kept (skipped).
# usage: urate-recall.sh <evidence dir>
set -uo pipefail
E=${1:?evidence dir}
X=$(cd "$(dirname "$0")" && pwd); GT=$X/../../workloads/vectordb/tools/compute_gt.py
LOCK=/home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock
rc=0
for S in "$E"/*-u*/slo; do
  [ -f "$S/e1.sample.bin" ] || { echo "$S: no e1.sample.bin"; rc=1; continue; }
  [ -f "$S/recall.recall.txt" ] && { echo "$S: done ($(grep '^recall_measured_ok' "$S/recall.recall.txt"))"; continue; }
  [ ! -e "$LOCK" ] || { echo "STOP: $LOCK exists"; exit 2; }
  args=$(sed -n 's/^loadgen_args=//p' "$S/../manifest.txt")
  D=$(echo "$args" | grep -o 'data=[^ ]*' | head -1 | cut -d= -f2) W=$(echo "$args" | grep -o 'writes=[^ ]*' | head -1 | cut -d= -f2)
  [ -d "$D" ] && [ -f "$W" ] || { echo "$S: data/writes not found ($D, $W)"; rc=1; continue; }
  nice -n 19 numactl --cpunodebind=1 --membind=1 python3 "$GT" --data "$D" --writes "$W" --searches "$S/e1.sample.bin" \
    --out "$S/recall" > "$S/recall.log" 2>&1 || { echo "$S: compute_gt failed (see recall.log)"; rc=1; continue; }
  echo "$S: $(grep '^recall_measured_ok\|^recall_tie_aware_measured_ok' "$S/recall.recall.txt" | tr '\n' ' ')"
done
exit $rc
