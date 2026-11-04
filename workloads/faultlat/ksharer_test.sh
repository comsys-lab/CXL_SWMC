#!/usr/bin/env bash
# Host test of faultlat access --thread-stat / --gap-us (no DAX device, no coherence kernel): the region device is a
# sparse regular file, /proc/thread-self/swmc is replaced by a fixed file (FAULTLAT_THREAD_STAT_PATH), so every delta
# is 0 and the test checks the plumbing: raw CSV columns, JSON summaries, refusal of unknown keys / bad options, and
# that --gap-us spaces the accesses (wall time >= pages x gap) without entering the timed interval.
# Then ksharer_summary.py (its own test) and ksharer.sh print mode.
#   ksharer_test.sh <faultlat binary>     -> "ksharer_test: all PASS"
set -euo pipefail
BIN=$(readlink -f "${1:?faultlat binary}")
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d /tmp/ksharer-test-XXXXXX)
trap 'rm -rf "$t"' EXIT
dev=$t/dev.img
truncate -s $((512 * 1024 * 1024)) "$dev"
cat > "$t/region.yaml" <<EOF
device: $dev
map_va: 0x600000000000
device_size: $((512 * 1024 * 1024))
align: 2097152
hwcc_offset: 0
hwcc_size: 268435456
msg_ring: [268300288, 135168]
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
printf 'read_faults 7\nwrite_faults 11\nwrite_transactions 3\nwrite_msg_wait_ns 123456\nfoo_ns 1\n' > "$t/swmc"
export CXL_REGION_CONFIG=$t/region.yaml FAULTLAT_THREAD_STAT_PATH=$t/swmc
fail() { echo "ksharer_test: FAIL: $*"; exit 1; }
# 1. thread-stat columns + JSON
"$BIN" access --op write --pages 64 --page-offset 0 --thread-stat write_faults,write_transactions,write_msg_wait_ns \
  --acct 0 --out "$t/a.json" --raw "$t/a.csv"
[ "$(head -1 "$t/a.csv")" = "pass,index,ns,write_faults,write_transactions,write_msg_wait_ns" ] || fail "raw header: $(head -1 "$t/a.csv")"
[ "$(tail -n +2 "$t/a.csv" | wc -l)" = 64 ] || fail "raw rows"
[ -z "$(tail -n +2 "$t/a.csv" | awk -F, '$4 != 0 || $5 != 0 || $6 != 0')" ] || fail "fixed stat file gave non-zero deltas"
python3 -I -c '
import json, sys
j = json.load(open(sys.argv[1]))
k = j["ksharer"]
assert k["keys"] == ["write_faults", "write_transactions", "write_msg_wait_ns"], k
s = k["steps"]["pass0_write"]
assert s["write_msg_wait_ns"]["count"] == 64 and s["write_msg_wait_ns"]["max_ns"] == 0, s
assert k["gap_us"] == 0 and k["thread_stat_path"] == sys.argv[2], k
' "$t/a.json" "$t/swmc" || fail "JSON ksharer object"
# 2. without the options: old raw layout, no ksharer object
"$BIN" access --op read --pages 8 --page-offset 64 --acct 0 --out "$t/b.json" --raw "$t/b.csv"
[ "$(head -1 "$t/b.csv")" = "pass,index,ns" ] || fail "raw header without --thread-stat"
python3 -I -c 'import json,sys; j=json.load(open(sys.argv[1])); assert "ksharer" not in j' "$t/b.json" || fail "ksharer object without options"
# 3. refusals
! "$BIN" access --op write --pages 4 --page-offset 80 --thread-stat no_such_key --acct 0 --out "$t/c.json" 2> "$t/c.err" || fail "unknown key accepted"
grep -q "key no_such_key not in" "$t/c.err" || fail "unknown key message: $(cat "$t/c.err")"
! "$BIN" access --op write --pages 4 --thread-stat "bad-key" 2> /dev/null || fail "bad key syntax accepted"
! "$BIN" access --op write --pages 4 --thread-stat a,a 2> /dev/null || fail "duplicate key accepted"
! "$BIN" pingpong --role 0 --nonce 1 --gap-us 5 2> /dev/null || fail "--gap-us accepted for pingpong"
! "$BIN" access --op write --pages 4 --gap-us 2000000 2> /dev/null || fail "--gap-us > 1 s accepted"
# 4. --gap-us: 200 accesses x 1000 us >= 0.2 s wall; the timed interval stays small (p50 < 500 us on a plain file)
s0=$(date +%s%N)
"$BIN" access --op write --pages 200 --page-offset 100 --gap-us 1000 --thread-stat write_faults --acct 0 --out "$t/d.json" --raw "$t/d.csv"
el=$(( ($(date +%s%N) - s0) / 1000000 ))
[ "$el" -ge 199 ] || fail "--gap-us 1000 x 200 took only $el ms"
python3 -I -c '
import json, sys
j = json.load(open(sys.argv[1]))
assert j["ksharer"]["gap_us"] == 1000
assert j["passes"]["pass0_write"]["p50_ns"] < 500000, j["passes"]["pass0_write"]
' "$t/d.json" || fail "gap leaked into the timed interval"
# 5. summary unit test + ksharer.sh print mode
python3 -I -B "$here/ksharer_summary_test.py"
out=$(NODE_HOSTS="comsys@10.0.0.1 comsys@10.0.0.2 comsys@10.0.0.3 comsys@10.0.0.4" FL_BIN=/g/faultlat RUNSH=/g/run.sh \
  CXL_REGION_CONFIG=/g/r.yaml PAGES=16 ROUNDS=2 GAP_US=1000 bash "$here/ksharer.sh" t1 1000 3 idle)
[ "$(grep -c 'access --op read' <<< "$out")" = 6 ] && [ "$(grep -c 'access --op write' <<< "$out")" = 2 ] || fail "ksharer.sh plan: $out"
grep -q "comsys@10.0.0.4 .*k3_idle_r1_read_n3 access --op read --pages 16 --page-offset 1016 --cpu 2" <<< "$out" || fail "ksharer.sh reader 3 round 1"
grep -q "comsys@10.0.0.1 .*k3_idle_r0_write access --op write --pages 16 --page-offset 1000 --thread-stat .* --gap-us 1000 --cpu 2" <<< "$out" || fail "ksharer.sh writer round 0"
grep -qx "next free base page: 1032" <<< "$out" || fail "ksharer.sh next base"
! NODE_HOSTS="a b c d" FL_BIN=x RUNSH=y CXL_REGION_CONFIG=z bash "$here/ksharer.sh" t1 0 4 idle > /dev/null 2>&1 || fail "k = N accepted"
echo "ksharer_test: all PASS"
