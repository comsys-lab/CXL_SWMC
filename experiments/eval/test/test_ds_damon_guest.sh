#!/bin/bash
# Host-side test of experiments/eval/ds-damon-guest.sh against a fake DAMON / De Stijl sysfs tree (plain files; no
# kernel, no sudo): start writes the expected values, refuses a second kdamond / replica_mode != damon / bad arguments,
# stats and stop print their lines. usage: bash test_ds_damon_guest.sh   (PASS / FAIL on the last line)
set -u
G=$(cd "$(dirname "$0")/.." && pwd)/ds-damon-guest.sh
T=$(mktemp -d /tmp/ds-damon-test-XXXXXX); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
A=$T/sys/kernel/mm/damon/admin/kdamonds DS=$T/sys/kernel/swmc/destijl
C=$A/0/contexts/0 H=$A/0/contexts/0/schemes/0
mkdir -p $DS $C/monitoring_attrs/intervals $C/monitoring_attrs/nr_regions $C/targets/0/regions/0 \
  $H/access_pattern/sz $H/access_pattern/nr_accesses $H/access_pattern/age $H/quotas/weights $H/watermarks $H/stats
echo 0 > $A/nr_kdamonds; echo off > $A/0/state; echo 0 > $A/0/pid; echo "vaddr fvaddr paddr" > $C/avail_operations
for f in nr_tried sz_tried nr_applied sz_applied qt_exceeds; do echo 7 > $H/stats/$f; done
echo damon > $DS/replica_mode; echo 12 > $DS/replica_pages; echo 3 > $DS/replica_create
g() { DS_DAMON_TEST_ROOT=$T sh "$G" "$@" 2>&1; }
ARGS="4294967296 103079215104 50000 1000000 1000000 1000 10000 2 100 1073741824 1000"
out=$(g start $ARGS); [[ $out == "DAMON ON range=4294967296-103079215104 "* ]] || fail "start: $out"
[ "$(cat $A/nr_kdamonds)" = 1 ] && [ "$(cat $A/0/state)" = on ] && [ "$(cat $C/operations)" = paddr ] || fail "kdamond / ops"
[ "$(cat $C/targets/0/regions/0/start)" = 4294967296 ] && [ "$(cat $C/targets/0/regions/0/end)" = 103079215104 ] || fail "region"
[ "$(cat $H/action)" = replicate ] && [ "$(cat $H/access_pattern/nr_accesses/min)" = 2 ] && [ "$(cat $H/access_pattern/nr_accesses/max)" = 20 ] || fail "scheme"
[ "$(cat $H/quotas/ms)" = 100 ] && [ "$(cat $H/quotas/bytes)" = 1073741824 ] && [ "$(cat $H/quotas/reset_interval_ms)" = 1000 ] || fail "quota"
[ "$(cat $C/monitoring_attrs/intervals/sample_us)" = 50000 ] && [ "$(cat $C/monitoring_attrs/nr_regions/max)" = 10000 ] || fail "attrs"
out=$(g start $ARGS); [[ $out == "DAMON FAIL: a kdamond exists already"* ]] || fail "second start not refused: $out"
out=$(g stats); [[ $out == "DAMON STATS nr_tried=7 "*"sz_applied=7 "*"cpu_ticks="*" replica_pages=12 replica_create=3 replica_evict=absent "*"replica_mode=damon" ]] || fail "stats: $out"
out=$(g stop); [[ $out == "DAMON OFF (nr_kdamonds 0, was 1)" ]] && [ "$(cat $A/0/state)" = off ] || fail "stop: $out"
out=$(g stop); [[ $out == "DAMON OFF (nr_kdamonds 0, was 0)" ]] || fail "idempotent stop: $out"
out=$(g stats); [[ $out == "DAMON STATS scheme=none "* ]] || fail "stats without kdamond: $out"
out=$(g start 1 2 3); [[ $out == "DAMON FAIL: start needs 11"* ]] || fail "argc: $out"
out=$(g start ${ARGS/ 2 / 30 }); [[ $out == "DAMON FAIL: min_acc 30 outside 1..20"* ]] || fail "min_acc: $out"
[ "$(cat $A/nr_kdamonds)" = 0 ] || fail "failed start left a kdamond"
echo off > $DS/replica_mode; out=$(g start $ARGS); [[ $out == "DAMON FAIL: replica_mode is 'off'"* ]] || fail "mode check: $out"
# damon-policy-exploration keys: action / min_age / weights / nice, min_acc 0 only with stat, commit, regions
echo damon > $DS/replica_mode
out=$(g start ${ARGS/ 2 / 0 } action=replicate); [[ $out == "DAMON FAIL: min_acc 0 outside 1..20"* ]] || fail "min_acc 0 with replicate: $out"
out=$(g start $ARGS bogus=1); [[ $out == "DAMON FAIL: unknown start key 'bogus=1'"* ]] || fail "unknown key: $out"
out=$(g start $ARGS nice=25); [[ $out == "DAMON FAIL: bad nice=25"* ]] || fail "nice range: $out"
[ "$(cat $A/nr_kdamonds)" = 0 ] || fail "refused start left a kdamond"
X="105497231360 167203831808 100000 2000000 2000000 500 1000 2 20 4194304 1000"
out=$(g start $X action=stat min_age=5 w_acc=800 w_age=200 w_sz=0 nice=19)
[[ $out == "DAMON ON range=105497231360-167203831808 "*"age_min=5 "*"weights=0/800/200 action=stat "* ]] || fail "start extra: $out"
[ "$(cat $H/action)" = stat ] && [ "$(cat $H/access_pattern/age/min)" = 5 ] && [ "$(cat $H/quotas/weights/age_permil)" = 200 ] \
  && [ "$(cat $H/quotas/weights/nr_accesses_permil)" = 800 ] && [ "$(cat $C/monitoring_attrs/nr_regions/min)" = 500 ] || fail "extra values"
out=$(g commit replicate 500 268435456 1000); [[ $out == "DAMON COMMIT action=replicate quota_ms=500 quota_bytes=268435456 reset_ms=1000 "* ]] || fail "commit: $out"
[ "$(cat $A/0/state)" = commit ] || fail "commit not written to state"
echo on > $A/0/state
out=$(g commit evict 1 1 1); [[ $out == "DAMON FAIL: commit: bad action 'evict'"* ]] || fail "commit action check: $out"
D=$H/tried_regions; mkdir -p $D/0 $D/1; echo 1000 > $D/total_bytes
for i in 0 1; do echo $((i * 500)) > $D/$i/start; echo $((i * 500 + 500)) > $D/$i/end; echo $((i + 3)) > $D/$i/nr_accesses; echo 7 > $D/$i/age; done
out=$(g regions); [[ $out == "DAMON REGIONS t="*" n=2 total_bytes=1000"$'\n'"0 500 3 7"$'\n'"500 1000 4 7" ]] || fail "regions: $out"
[ "$(cat $A/0/state)" = update_schemes_tried_regions ] || fail "regions did not request an update"
echo on > $A/0/state
out=$(g stats); [[ $out == "DAMON STATS "*" action=replicate kdamond_pid="* ]] || fail "stats action: $out"
out=$(g stop); [[ $out == "DAMON OFF (nr_kdamonds 0, was 1)" ]] || fail "stop 2: $out"
out=$(g regions); [[ $out == "DAMON FAIL: regions: no running kdamond"* ]] || fail "regions without kdamond: $out"
out=$(g start $X action=stat); [[ $out == "DAMON ON "* ]] || fail "min_acc 2 stat: $out"; g stop > /dev/null
out=$(g start ${X/ 2 / 0 } action=stat); [[ $out == "DAMON ON "*"nr_accesses=0-20 "* ]] || fail "min_acc 0 stat: $out"; g stop > /dev/null
echo "PASS test_ds_damon_guest.sh"
