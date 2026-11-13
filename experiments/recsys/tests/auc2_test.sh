#!/bin/bash
# Host-only test of main-block.sh stream_auc2 (STREAM_AUC2 fixed-rate parts after part auc): the real function body is
# taken from main-block.sh and run with a fake measure (records its arguments, writes a loadgen summary) and fake
# stream_check.py / check_breakdown.py. Checks: one part fix2-<k> per listed rate with the planned loadgen options and
# seed SEED + 10 + k, --drain-full-s only when STREAM_DRAIN_FULL_S is set, stream-fix2.tsv rows, no part for a rate
# without an entry / with STREAM_AUC2 unset, rc 1 with a note recorded, rc 3 = stop. No VM, no server.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); MB=$(cd "$HERE/.." && pwd)/main-block.sh
T=$(mktemp -d /tmp/auc2-test-XXXXXX); trap 'rm -rf "$T"' EXIT
FAIL=0; bad() { echo "FAIL: $*"; FAIL=1; }
eval "$(sed -n '/^stream_auc2() {/,/^}/p' "$MB")"
declare -F stream_auc2 > /dev/null || { echo "FAIL: no stream_auc2 in main-block.sh"; exit 1; }
X=$T/x; mkdir -p "$X"
printf 'print("STREAMCHECK PASS fake")\n' > "$X/stream_check.py"; printf 'print("BREAKDOWN PASS fake")\n' > "$X/check_breakdown.py"
RC=0
measure() {  # <LS> <part> <loadgen args...>
  local d=$1/$2; mkdir -p "$d/loadgen"; shift 2; echo "$*" > "$d/args.txt"
  if [ $RC = 1 ]; then echo '{"workload_finish":"ok","note":"fake note"}' > "$d/loadgen/summary.json"
  else echo '{"workload_finish":"ok"}' > "$d/loadgen/summary.json"; fi
  return $RC; }
stop() { echo "STOPPED: $*"; exit 7; }
SEED=100 NAME=pop-u50-auc LGC=(--lgc x) E=$T/e LS=$T/e/pop-u50-auc; mkdir -p "$LS"
STREAM_AUC2="50=10.6,11.9,13.2,14.5 100=9.8" STREAM_DRAIN_FULL_S=120 STREAM_AUC2_S=120
stream_auc2 pop 50 > "$T/o1.txt" || bad "rc"
for k in 1 2 3 4; do [ -f "$LS/fix2-$k/args.txt" ] || bad "no part fix2-$k"; done
[ ! -e "$LS/fix2-5" ] || bad "fifth part"
a=$(cat "$LS/fix2-1/args.txt")
[ "$a" = "--lgc x --opt seed=111 --seed 111 --raw --mode fixed --rates 10.6 --warmup-s 0 --step-warmup-s 5 --step-measure-s 120 --drain-s 10 --drain-full-s 120" ] || bad "args fix2-1 [$a]"
grep -q -- '--seed 114 .*--rates 14.5 ' "$LS/fix2-4/args.txt" || bad "fix2-4 seed / rate"
[ "$(grep -vc '^#' "$E/stream-fix2.tsv")" = 4 ] && grep -qx $'pop-u50-auc\tpop\t50\tfix2-3\t13.2\tok' "$E/stream-fix2.tsv" || bad "stream-fix2.tsv: $(cat "$E/stream-fix2.tsv")"
# rate 200 has no entry: nothing; STREAM_AUC2 unset: nothing
LS=$T/e/pop-u200-auc; mkdir -p "$LS"; stream_auc2 pop 200; [ -z "$(ls "$LS")" ] || bad "part for a rate without entry"
unset STREAM_AUC2; LS=$T/e/pop-u50b; mkdir -p "$LS"; stream_auc2 pop 50; [ -z "$(ls "$LS")" ] || bad "part with STREAM_AUC2 unset"
# no drain-full key: no --drain-full-s; rc 1 with a note = recorded status
STREAM_AUC2="100=9.8" STREAM_DRAIN_FULL_S= RC=1 LS=$T/e/ds-u100-auc NAME=ds-u100-auc; mkdir -p "$LS"
stream_auc2 ds 100 > "$T/o2.txt" || bad "rc (rc 1 case)"
! grep -q -- --drain-full-s "$LS/fix2-1/args.txt" || bad "--drain-full-s without STREAM_DRAIN_FULL_S"
grep -qx $'ds-u100-auc\tds\t100\tfix2-1\t9.8\tloadgen-rc1' "$E/stream-fix2.tsv" || bad "rc 1 row"
# rc 3 (precondition) = stop
( RC=3 LS=$T/e/ds-u100-c; mkdir -p "$LS"; stream_auc2 ds 100 > "$T/o3.txt" ); [ $? = 7 ] && grep -q 'STOPPED: ds-u100-auc fix2-1 rc 3' "$T/o3.txt" || bad "rc 3 not a stop"
[ $FAIL = 0 ] && echo "AUC2 TEST PASS" || { echo "AUC2 TEST FAIL"; exit 1; }
