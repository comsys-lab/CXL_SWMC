#!/bin/bash
# Dry test of H2N_WARMUP (run-2 §6 fair trio: the DAMON warmup segment for lifetimes without DAMON) through
# runset-h2n.sh -> h2n-block.sh (block dry start): temp copies of eval-run2-vdb.conf (hw:u50 only)
#   1. H2N_WARMUP="rate=300 learn_s=30 part_s=60 parts=10" -> block plan parts wa wb01..wb10, duration_s=630
#   2. a bad spec (parts=0) -> BLOCK STOP "out of range"
#   3. a spec without part_s -> BLOCK STOP "lacks part_s"
#   4. H2N_WARMUP together with H2N_DS_DAMON_WARMUP (+ the DAMON keys) -> BLOCK STOP "one warmup rule per block"
# Host only, no VM contact. usage: bash experiments/eval/test/test_warmup_block_dry.sh
set -uo pipefail
EV=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/warmup-dry-XXXXXX); trap 'rm -rf "$T"' EXIT
fails=0
run() {  # <name> <extra conf lines> <expected fragment>
  { grep -v -e '^H2N_WARMUP=' -e '^H2N_PMAX' "$EV/eval-run2-vdb.conf"; printf '%s\n' "$2"; } > "$T/$1.conf"
  local out; out=$(EVAL_CONF=$T/$1.conf bash "$EV/runset-h2n.sh" 2 1 --dry --only hw:u50 2>&1)
  if echo "$out" | grep -qF -- "$3"; then echo "PASS  $1: $(echo "$out" | grep -m1 -F -- "$3" | cut -c1-160)"
  else echo "FAIL  $1 (want '$3'):"; echo "$out" | grep -E 'warmup|WARMUP|STOP' | sed 's/^/    /' | cut -c1-200; fails=$((fails + 1)); fi
}
run ok 'H2N_WARMUP="rate=300 learn_s=30 part_s=60 parts=10"' \
  "parts=[wa wb01 wb02 wb03 wb04 wb05 wb06 wb07 wb08 wb09 wb10] nogate=[wb01 wb02 wb03 wb04 wb05 wb06 wb07 wb08 wb09 wb10] duration_s=630"
run range 'H2N_WARMUP="rate=300 learn_s=30 part_s=60 parts=0"' "H2N_WARMUP out of range"
run keys 'H2N_WARMUP="rate=300 learn_s=30 parts=10 x=1"' "H2N_WARMUP lacks part_s"
run both 'H2N_WARMUP="rate=300 learn_s=30 part_s=60 parts=10"
H2N_DS_REPLICA_MODE=damon
H2N_DS_REPLICA_POOL_BYTES=12884901888
H2N_DS_DAMON="sample_us=100000 aggr_us=2000000 update_us=2000000 min_regions=500 max_regions=1000 min_acc=2 quota_ms=20 quota_bytes=4194304 reset_ms=1000"
H2N_DS_DAMON_EXTRA="range=index action=replicate min_age=1 w_acc=800 w_age=200 w_sz=0 nice=19"
H2N_DS_DAMON_AT=ready
H2N_DS_DAMON_WARMUP="rate=300 learn_s=30 part_s=60 max_parts=10 min_fill_s=120 end_pps=256 end_n=3 fill_ms=500 fill_bytes=268435456"' \
  "one warmup rule per block"
echo "WARMUP BLOCK DRY TEST $([ $fails = 0 ] && echo PASS || echo FAIL) ($fails failures)"
exit $fails
