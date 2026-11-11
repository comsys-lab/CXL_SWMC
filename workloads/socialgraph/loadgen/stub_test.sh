#!/bin/bash
# Protocol test of the socialgraph loadgen plugin against two stub servers on Host loopback (own processes only).
# Run A: rw=100, image= + gen= (id2 from the build-time adjacency), --stats-op 20. Run B: rw=470, no image.
# Run C: rw=100, no image, write_route=range (stubs check the range owner).
# Each: --mode fixed, 2 rates, --slo feed:99:10; then checks loadgen rc, sg.txt (mix_ok=1, bad_responses=0,
# wseq_mismatch=0, id2 source) and the stubs' exit codes (protocol violations, owner routing, w_seq order).
# usage: stub_test.sh <build dir> <out dir (new)> [graph.img gen.json]
set -uo pipefail
B=$(cd "$1" && pwd); OUT=$2; IMG=${3:-}; GEN=${4:-}
mkdir "$OUT" || exit 2
OUT=$(cd "$OUT" && pwd)
PIN=(nice -n 19 ionice -c3 numactl --membind=1)
N_ORIG=3072626; BASE=1; FAIL=0
# node-1 CPUs (env overrides; defaults fit the session partition 18-23,50-55)
CPU_S0=${CPU_S0:-18,50}; CPU_S1=${CPU_S1:-19,51}; CPU_LG=${CPU_LG:-20-23,52-55}
run() {  # <name> <rw> <port0> [opts...]
  local name=$1 rw=$2 p0=$3; shift 3
  local d=$OUT/$name p1=$((p0 + 1))
  mkdir "$d"
  "${PIN[@]}" --physcpubind="$CPU_S0" "$B/bin/sg-loadgen-stub" "$p0" 0 2 $N_ORIG $BASE 45 ${ROUTE:-} > "$d/stub0.txt" 2>&1 & local s0=$!
  "${PIN[@]}" --physcpubind="$CPU_S1" "$B/bin/sg-loadgen-stub" "$p1" 1 2 $N_ORIG $BASE 45 ${ROUTE:-} > "$d/stub1.txt" 2>&1 & local s1=$!
  sleep 1
  "${PIN[@]}" --physcpubind="$CPU_LG" "$B/loadgen" --workload socialgraph --target 127.0.0.1:$p0,127.0.0.1:$p1 \
    --out "$d/loadgen" --mode fixed --rates 10000,40000 --mix "$("$B/bin/sg-loadgen-mix" "$rw")" --slo feed:99:10 \
    --warmup-s 2 --step-warmup-s 1 --step-measure-s 4 --drain-s 2 --opt rw="$rw" "$@" > "$d/loadgen.log" 2>&1
  local rc=$?
  wait $s0; local r0=$?; wait $s1; local r1=$?
  echo "$name: loadgen rc=$rc stub rc=$r0,$r1"
  cat "$d/stub0.txt" "$d/stub1.txt"
  local t=$d/loadgen/sg.txt
  grep -E '^(mix_|made\.|wseq|id2_|feed_ok|write_records|resp\.)' "$t"
  [ $rc -eq 0 ] && [ $r0 -eq 0 ] && [ $r1 -eq 0 ] || FAIL=1
  grep -qx 'mix_ok=1' "$t" && grep -q '^wseq_mismatch=0 bad_responses=0 ' "$t" || FAIL=1
}
run A 100 19331 --stats-op 20 ${IMG:+--opt image=$IMG} ${GEN:+--opt gen=$GEN}
[ -z "$IMG" ] || grep -q '^id2_from_image=[1-9]' "$OUT/A/loadgen/sg.txt" || FAIL=1
grep -q '^resp.feed .* busy=[1-9]' "$OUT/A/loadgen/sg.txt" || FAIL=1  # stub answers ~0.1 % of feeds Busy
[ -z "$IMG" ] || ls "$OUT"/A/loadgen/stats/*.txt > /dev/null 2>&1 || FAIL=1
run B 470 19341
grep -q '^id2_from_image=0 .* id2_no_image=[1-9]' "$OUT/B/loadgen/sg.txt" || FAIL=1
# Run C: write_route=range (stubs check owner = slot / ceil(n_orig / 2), layout.h slot_owner)
ROUTE=range run C 100 19351 --opt write_route=range
grep -rqs 'write_route=range' "$OUT/C" || { echo "C: write_route=range not in the plugin description"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "STUB TEST PASS" || echo "STUB TEST FAIL"
exit $FAIL
