#!/bin/bash
# Dry test of the eval3 L1 lookup through runset-h2n.sh -> h2n-block.sh (H2N_BLOCK_DRY): fake mg evidence dirs in a temp
# root (mg-u10 pass in v1 and v2, mg-u90 start fail), a temp copy of eval3-b1.conf whose H2N_L1_FROM points there, then
# dry starts of pop:u10 (expect L1 = v2's 99.0 / 0.9 = 110.00, appended), hw:u90 (expect 10, not appended) and hw:u50
# (no mg row: none, not appended). Host only, no VM contact. usage: bash experiments/eval/test/test_l1_block_dry.sh
set -uo pipefail
EV=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/l1-dry-XXXXXX); trap 'rm -rf "$T"' EXIT
H=$'# name\tsystem\tmix\tU\tnodes\tvcpus_per_vm\tmax_offered_x_pass\tconfirm_x_mean\tconfirmed\tnote\trun_dir\topcoh_check'
mk() { mkdir -p "$T/$1/block"; printf '%s\n%s\n' "$H" "$2" > "$T/$1/block/h2n-results.tsv"; }
mk eval3-b1-mg-u10-n2-v1 $'mg-u10-n2\tmg\tu10\t10\t2\t4\t108.0\t97.7114\tTrue\t\tmg-u10-n2/slo\tPASS'
mk eval3-b1-mg-u10-n2-v2 $'mg-u10-n2\tmg\tu10\t10\t2\t4\t120\t99.0\tTrue\t\tmg-u10-n2/slo\tPASS'
mk eval3-b1-mg-u90-n2-v1 $'mg-u90-n2\tmg\tu90\t90\t2\t4\t\t\t\tthe start rate already violates the SLO; lower --start\tmg-u90-n2/slo\tPASS'
grep -v '^H2N_L1_FROM=' "$EV/eval3-b1.conf" > "$T/c.conf"
echo "H2N_L1_FROM=\"$T/eval3-b1-mg-{MIX}-n{N}-v*/block/h2n-results.tsv\"" >> "$T/c.conf"
fails=0
chk() {  # <lifetime> <expected L1 line fragment>
  local out; out=$(EVAL_CONF=$T/c.conf bash "$EV/runset-h2n.sh" 2 1 --dry --only "$1" 2>&1)
  if echo "$out" | grep -q "DRY START OK" && echo "$out" | grep -qF "BLOCK PLAN: L1 $1: $2"; then echo "PASS  $1: $(echo "$out" | grep -F "BLOCK PLAN: L1 $1:" | cut -c1-140)"
  else echo "FAIL  $1 (want '$2'):"; echo "$out" | grep -E 'L1|STOP' | sed 's/^/    /'; fails=$((fails + 1)); fi
}
chk pop:u10 "110.00 append=1"
chk hw:u90 "10 append=0"
chk hw:u50 "none append=0"
echo "L1 BLOCK DRY TEST $([ $fails = 0 ] && echo PASS || echo FAIL) ($fails failures)"
exit $fails
