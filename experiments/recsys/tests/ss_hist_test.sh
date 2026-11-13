#!/bin/bash
# Host-only test of the De Stijl SS-residence capture (session.sh ss_snap + ss_hist.py delta): the real ss_snap
# function body is taken from session.sh and run with rx = local shell (as SESSION_LOCAL=1) against a fake sysfs dir
# (SS_HIST_DIR, 40 "<lo_us> <count>" lines as kernel/swmc/destijl.c ds_hist_emit). No VM, no guest.
# Checks: DeStijl-* system = pre/post files per node + ss-residence.csv deltas; any other system (all-HWcc, Popcorn,
# Megalon) = no file and no guest call; missing sysfs file = no file, no error; ss_hist.py --selftest.
# usage: ss_hist_test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); X=$(cd "$HERE/.." && pwd)
T=$(mktemp -d /tmp/ss-hist-test-XXXXXX); trap 'rm -rf "$T"' EXIT
FAIL=0; bad() { echo "FAIL: $*"; FAIL=1; }
python3 -I -B "$X/ss_hist.py" --selftest | grep -qx 'SSHIST SELFTEST PASS' || bad "ss_hist.py --selftest"
eval "$(sed -n '/^ss_snap() {/,/^}/p' "$X/session.sh")"
declare -F ss_snap > /dev/null || { echo "FAIL: no ss_snap in session.sh"; exit 1; }
CALLS=0
rx() { CALLS=$((CALLS + 1)); bash -c "$2" < /dev/null; }
mk() {  # <dir> <count at bucket 3> <count at bucket 5>
  mkdir -p "$1"; local i lo
  : > "$1/ss_residence_hist"; : > "$1/ss_residence_window_hist"
  for i in $(seq 0 39); do lo=$((i == 0 ? 0 : 1 << (i - 1))); c=0
    [ $i = 3 ] && c=$2; [ $i = 5 ] && c=$3
    echo "$lo $c" >> "$1/ss_residence_hist"; echo "$lo $((c / 2))" >> "$1/ss_residence_window_hist"; done; }
NODE=(a b)
# De Stijl lifetime: both nodes, pre then post with more residences
SYSTEM=DeStijl-adaptive-T1000000 M=$T/m1 SS_HIST_DIR=$T/sys; mkdir -p "$M"
mk "$SS_HIST_DIR" 4 0; ss_snap pre
mk "$SS_HIST_DIR" 10 7; ss_snap post
for k in 0 1; do for w in pre post; do [ -s "$M/ss-residence-$w-t$k.txt" ] || bad "no $w snapshot of node $k"; done; done
grep -qx '# ss_residence_window_hist' "$M/ss-residence-post-t0.txt" || bad "window histogram not captured"
python3 -I -B "$X/ss_hist.py" delta "$M" > "$M/ss-residence.txt" 2>&1 || bad "ss_hist.py delta rc"
grep -q '^SSHIST node0: 13 SS residences, p50 bucket 16 us, p95 bucket 16 us, max bucket 16 us' "$M/ss-residence.txt" || bad "summary: $(cat "$M/ss-residence.txt")"
[ "$(grep -c '^0,ss_residence_hist,' "$M/ss-residence.csv")" = 40 ] || bad "node 0 cumulative rows != 40"
grep -qx '1,ss_residence_hist,4,4,10,6' "$M/ss-residence.csv" || bad "node 1 bucket 4 us delta row"
grep -qx '0,ss_residence_window_hist,16,0,3,' "$M/ss-residence.csv" || bad "window row (no delta)"
# other systems: no guest call, no file
for s in all-HWcc Popcorn-adaptive Megalon; do
  CALLS=0 SYSTEM=$s M=$T/m-$s; mkdir -p "$M"; ss_snap pre; ss_snap post
  [ $CALLS = 0 ] && [ -z "$(ls "$M")" ] || bad "$s: $CALLS guest calls, files [$(ls "$M")]"
done
# De Stijl but no histogram file (older kernel): no file, rc 0, delta prints "no snapshot"
SYSTEM=DeStijl-sleep-T0 M=$T/m2 SS_HIST_DIR=$T/none; mkdir -p "$M"
ss_snap pre && ss_snap post || bad "ss_snap rc without the sysfs file"
[ -z "$(ls "$M")" ] || bad "files without the sysfs file: $(ls "$M")"
python3 -I -B "$X/ss_hist.py" delta "$M" | grep -qx 'SSHIST no snapshot' || bad "delta without snapshots"
[ $FAIL = 0 ] && echo "SS HIST TEST PASS" || { echo "SS HIST TEST FAIL"; exit 1; }
