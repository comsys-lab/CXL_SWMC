#!/bin/bash
# Host-side test of experiments/eval/damonx-hook.sh (DAMONX_HOOK_DRY=1: guest commands printed, layout / registered /
# MemAvailable stand-ins; no ssh, no VM): start at the first part (index extent), phase B commit at wb01, skip decisions
# from synthetic sampler lines (min_fill_s, end_n consecutive rates < end_pps), warmup end summary + csv, timeout path.
# usage: bash test_damonx_hook.sh   (PASS / FAIL on the last line)
set -u
HK=$(cd "$(dirname "$0")/.." && pwd)/damonx-hook.sh
T=$(mktemp -d /tmp/damonx-hook-test-XXXXXX); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export DAMONX_HOOK_DRY=1 DAMONX_SETTLE_S=0 DAMONX_E=$T DAMONX_NAME=ds-u50-n2 DAMONX_IPS="10.0.0.1 10.0.0.2" DAMONX_GUEST=/dev/null \
  DAMONX_ARGS="100000 2000000 2000000 500 1000 2 20 4194304 1000" DAMONX_START_EXTRA="action=replicate min_age=5 w_acc=800 w_age=200 w_sz=0 nice=19" \
  DAMONX_RANGE=index DAMONX_POOL=12884901888 DAMONX_V=/home/comsys/vdb22ds \
  DAMONX_WARM="rate=300 learn_s=30 part_s=60 max_parts=10 min_fill_s=120 end_pps=256 end_n=3 fill_ms=500 fill_bytes=268435456"
h() { bash "$HK" "$@" 2>&1; }
DF=$T/ds-damon-ds-u50-n2.txt
out=$(h skip wa); rc=$?; [ $rc = 1 ] || fail "skip wa rc $rc ($out)"
out=$(h pre wa) || fail "pre wa: $out"
grep -q "start 10.0.0.1: DRY 10.0.0.1: sudo -n sh -s -- start 105497231360 167203831808 100000 2000000 2000000 500 1000 2 20 4194304 1000 action=replicate min_age=5 w_acc=800 w_age=200 w_sz=0 nice=19 action=stat" $DF \
  || fail "start line (index extent, phase A action=stat): $(grep ' start ' $DF)"
grep -q "^started " $T/damonx-ds-u50-n2.state && grep -q "^phaseA " $T/damonx-ds-u50-n2.state || fail "state after pre wa"
out=$(h pre wb01) || fail "pre wb01: $out"
grep -q "fill 10.0.0.2: DRY 10.0.0.2: sudo -n sh -s -- commit replicate 500 268435456 1000" $DF || fail "fill commit"
pb=$(sed -n 's/^phaseB //p' $T/damonx-ds-u50-n2.state); [ -n "$pb" ] || fail "no phaseB"
out=$(h skip wb02); rc=$?; [ $rc = 1 ] && [[ $out == *"< min_fill_s 120"* ]] || fail "skip wb02 before min_fill: rc $rc $out"
# pretend phase B started 200 s ago; sampler lines: vm1 slows down to < 256 pages/s in the last 3 intervals, vm2 not yet
sed -i "s/^phaseB .*/phaseB $((pb - 200))/; s/^phaseA .*/phaseA $((pb - 230))/" $T/damonx-ds-u50-n2.state   # test fixture only (temp dir)
s0=$((pb - 190))
line() { echo "$(date -Is -d @$1) ds-u50-n2 run $2: DAMON STATS nr_tried=1 sz_tried=1 nr_applied=1 sz_applied=$4 qt_exceeds=0 action=replicate kdamond_pid=9 state=on cpu_ticks=1 nice=19 clk_tck=100 mem_available_kb=1 replica_pages=$3 replica_create=$3 replica_evict=0 replica_lru_evict=0 replica_writeback=0 replica_refresh=0 replica_pool_full=0 replica_pool_max_bytes=12884901888 replica_mode=damon" >> $DF; }
c1=0 c2=0
for i in 0 1 2 3 4 5; do
  t=$((s0 + 10 * i)); [ $i -le 2 ] && c1=$((c1 + 50000)) || c1=$((c1 + 1000)); c2=$((c2 + 50000))
  line $t 10.0.0.1 $c1 $((c1 * 4096)); line $t 10.0.0.2 $c2 $((c2 * 4096))
done
out=$(h skip wb03); rc=$?; [ $rc = 1 ] && [[ $out == *"10.0.0.1=[100,100,100] 10.0.0.2=[5000,5000,5000]"* ]] || fail "skip wb03 (vm2 still filling): rc $rc $out"
for i in 6 7 8; do t=$((s0 + 10 * i)); c1=$((c1 + 1000)); c2=$((c2 + 2000)); line $t 10.0.0.1 $c1 $((c1 * 4096)); line $t 10.0.0.2 $c2 $((c2 * 4096)); done
out=$(h skip wb04); rc=$?; [ $rc = 0 ] && [[ $out == *"end condition met"* ]] || fail "skip wb04 (both < 256/s): rc $rc $out"
grep -q "steady 10.0.0.1: DRY 10.0.0.1: sudo -n sh -s -- commit replicate 20 4194304 1000" $DF || fail "steady commit"
grep -q "reason=condition" $T/damonx-warmup-ds-u50-n2.txt || fail "summary: $(cat $T/damonx-warmup-ds-u50-n2.txt)"
[ "$(head -n 1 $T/damonx-warmup-ds-u50-n2.csv)" = "t_epoch,vm,phase,replica_pages,create_per_s,applied_pages_per_s,pool_fill_pct" ] \
  && [ "$(grep -c ',10.0.0.1,B,' $T/damonx-warmup-ds-u50-n2.csv)" = 9 ] && grep -q ',10.0.0.2,B,.*,200.0,200.0,' $T/damonx-warmup-ds-u50-n2.csv || fail "csv: $(cat $T/damonx-warmup-ds-u50-n2.csv)"
out=$(h skip wb05); rc=$?; [ $rc = 0 ] && [[ $out == *"warmup ended"* ]] || fail "skip after end: rc $rc $out"
n=$(grep -c ' commit ' $DF); out=$(h pre slo) || fail "pre slo: $out"; [ "$(grep -c ' commit ' $DF)" = "$n" ] || fail "slo pre committed again"
out=$(h skip slo); rc=$?; [ $rc = 1 ] || fail "skip slo rc $rc"
# timeout path: a second lifetime whose phase B never meets the condition
export DAMONX_NAME=ds-u50-n2-b
out=$(h pre wa) && out=$(h pre wb01) && out=$(h pre slo) || fail "timeout path: $out"
grep -q "reason=timeout" $T/damonx-warmup-ds-u50-n2-b.txt && grep -q "^WARMUP_TIMEOUT" $T/damonx-warmup-ds-u50-n2-b.txt || fail "timeout summary"
# managed range without warmup (fixed lifetime, E0b): start once, no commit, fixed-part-hook not called without a key
export DAMONX_NAME=ds-u50-n2-c DAMONX_RANGE=managed DAMONX_WARM= DAMONX_START_EXTRA="action=stat nice=19"
out=$(h pre hot) || fail "pre hot: $out"; out=$(h pre hot) || fail "pre hot 2: $out"; DF=$T/ds-damon-ds-u50-n2-c.txt
[ "$(grep -c 'ds-u50-n2-c start 10.0.0.1:' $DF)" = 1 ] && grep -q "start 105497231360 208289136640 .* action=stat nice=19$" $DF || fail "managed start: $(grep 'n2-c start' $DF)"
out=$(h skip hot); rc=$?; [ $rc = 1 ] || fail "skip without warmup rc $rc"
echo "PASS test_damonx_hook.sh"
