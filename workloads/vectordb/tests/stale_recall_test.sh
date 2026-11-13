#!/bin/bash
# Host test of the stale-snapshot copies (DESIGN.md §20; experiment vector-db-staleness-recall): two vdb-server
# processes (plain backend) share a scratch FILE as the "device" (HW coherent; never /dev/dax*). Node 0 = writer node
# (every update, --writer-threads WRITERS), node 1 = search node (--opt search_target=1), as the experiment's
# vm0 / vm1. Small SQ8 image built here from the data dir's pool A; writes file with every target 0 (gen_writes.py
# --vms 1); exact top-K' over pools A + B by brute force (tests/topk_bruteforce.py). One loadgen invocation, fixed
# mode: search groups SEARCH/s (each = len(STALE) requests), --fixed update=URATE, warm-up WARM_S (>= max T) before the
# measured window MEASURE_S. Checks: write_errors 0; urate_check.py (writers kept up); e1_check.py (every copy at its
# sent snapshot); staleness_recall.py --check --monotone-tol MON_TOL (every group has all T, sent non-increasing in T,
# sent(T=0) = fresh ref_w, s_used = sent, E1 0, recall_ann non-increasing in T within MON_TOL, loss > 0 at the largest
# T); server final counters (all updates on node 0, all searches on node 1, backlog 0, bad_records 0).
# usage: stale_recall_test.sh <vdb build dir> <loadgen binary> <data dir (pool_a/pool_b/queries .fbin)> <scratch dir>
# env: URATE (300 updates/s), SEARCH (20 groups/s), STALE (0,1,10,100,1000,10000), WARM_S (13 = 3 + 10 s lookback),
#      MEASURE_S (30), WRITERS (4), VEC_FORMAT (sq8), SEGMENTS (4), CHUNK (1048576), KPRIME (2000), MON_TOL (0.002),
#      CPUS0 / CPUS1 / LGCPUS (node-1 CPU sets: 18-20,50-52 / 21-23,53-55 / 18-23,50-55), PORT0 (19500)
set -euo pipefail
B=$(cd "$1" && pwd) LG=$2 D=$(cd "$3" && pwd) S=$4
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
URATE=${URATE:-300} SEARCH=${SEARCH:-20} STALE=${STALE:-0,1,10,100,1000,10000} WARM_S=${WARM_S:-13} MEASURE_S=${MEASURE_S:-30}
WRITERS=${WRITERS:-4} VF=${VEC_FORMAT:-sq8} SEG=${SEGMENTS:-4} CHUNK=${CHUNK:-1048576} KPRIME=${KPRIME:-2000} MON_TOL=${MON_TOL:-0.002}
CPUS0=${CPUS0:-18-20,50-52} CPUS1=${CPUS1:-21-23,53-55} LGCPUS=${LGCPUS:-18-23,50-55} PORT0=${PORT0:-19500}
[ -e "$S" ] && { echo "refusing: $S exists"; exit 2; }
mkdir -p "$S"
NA=$(python3 -c "import numpy as np,sys; print(np.fromfile(sys.argv[1],dtype=np.int32,count=1)[0])" "$D/pool_a.fbin")
NB=$(python3 -c "import numpy as np,sys; print(np.fromfile(sys.argv[1],dtype=np.int32,count=1)[0])" "$D/pool_b.fbin")
MAXIDS=$((NA + NB))
NEED=$(( URATE * (3 + WARM_S + MEASURE_S + 10) ))   # loadgen warm-up 3 s + step warm-up + window + drain (upper bound)
[ "$NEED" -le "$NB" ] || { echo "refusing: $NEED updates needed > pool B $NB"; exit 2; }
python3 "$ROOT/workloads/vectordb/tools/gen_writes.py" --out "$S/writes.bin" --pool-a "$NA" --pool-b "$NB" --writes $((2 * NB)) --vms 1 > "$S/gen_writes.log"
python3 "$HERE/topk_bruteforce.py" "$D" "$S/topk.npz" --kprime "$KPRIME" > "$S/topk.log"
VFARG=(); [ "$VF" = fp32 ] || VFARG=("$VF")
taskset -c "$LGCPUS" "$B/bin/vdb-build-index" "$D/pool_a.fbin" "$S/init" "$SEG" "$MAXIDS" 16 128 0 8 20261015 "$CHUNK" ${VFARG[@]+"${VFARG[@]}"} > "$S/index.log" 2>&1
PARAMS="--nodes 2 --segments $SEG --chunk-bytes $CHUNK --M 16 --efc 128 --ef 32 --max-writes $((2 * NB + 1024)) --max-ids $MAXIDS --max-deletes $((NB + 1024)) --dlog-chunk 256 --writer-threads $WRITERS"
[ "$VF" = fp32 ] || PARAMS="$PARAMS --vec-format $VF"
DEVSZ=2147483648
truncate -s "$DEVSZ" "$S/device.img"
sed -e "s|^device: .*|device: $S/device.img|" -e "s|^device_size: .*|device_size: $DEVSZ|" "$ROOT/config/cxl_region.yaml" > "$S/region.yaml"
# shellcheck disable=SC2086
APP=$("$B/bin/vdb-server" $PARAMS --print-app-bytes)
RID=0x$(printf '%x' $(( (RANDOM << 16 | RANDOM) | 1 )))
{ echo "# stale recall test $(date -Is)"; echo "build=$B $(sha256sum "$B/bin/vdb-server" | cut -c1-64)"; echo "loadgen=$LG $(sha256sum "$LG" | cut -c1-64)"
  echo "data=$D na=$NA nb=$NB params=$PARAMS"; echo "urate=$URATE search=$SEARCH stale=$STALE warm_s=$WARM_S measure_s=$MEASURE_S kprime=$KPRIME mon_tol=$MON_TOL"
  echo "cpus0=$CPUS0 cpus1=$CPUS1 lgcpus=$LGCPUS host_load=$(cut -d' ' -f1-3 /proc/loadavg)"; } > "$S/test.txt"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT
for k in 0 1; do
  EXTRA=""; [ "$k" = 0 ] && EXTRA="--init-dir $S/init"
  C=$CPUS0; [ "$k" = 1 ] && C=$CPUS1
  # shellcheck disable=SC2086
  env CXL_REGION_CONFIG=$S/region.yaml CXL_APP_HWCC_BYTES=$APP numactl --physcpubind="$C" --membind=1 "$B/bin/vdb-server" --node $k \
    --run-id "$RID" $PARAMS --port $((PORT0 + k)) --search-threads 3 --wait-timeout-ms 60000 $EXTRA > "$S/node$k.log" 2>&1 &
  PIDS+=($!)
done
for k in 0 1; do
  for _ in $(seq 300); do grep -q "vdb-server: READY" "$S/node$k.log" && break; { grep -q FATAL "$S/node$k.log" || ! kill -0 "${PIDS[$k]}" 2>/dev/null; } && { tail -n 5 "$S/node$k.log"; exit 1; }; sleep 1; done
  grep -q "vdb-server: READY" "$S/node$k.log" || { echo "node$k not READY"; exit 1; }
done
RC=0 O=$S/run
mkdir "$O"
set +e
numactl --physcpubind="$LGCPUS" --membind=1 "$LG" --workload vectordb --target 127.0.0.1:$PORT0,127.0.0.1:$((PORT0 + 1)) --out "$O/loadgen" \
  --stats-op 10 --opt data="$D" --opt writes="$S/writes.bin" --opt k=10 --opt seed=20261113 --seed 20261113 \
  --opt stale_ms="$STALE" --opt search_target=1 --mode fixed --rates "$SEARCH" --fixed update="$URATE" --mix search=1 --x-stream search \
  --warmup-s 3 --step-warmup-s "$WARM_S" --step-measure-s "$MEASURE_S" --drain-s 10 --raw > "$O/loadgen.log" 2>&1
lrc=$?
set -e
for p in "${PIDS[@]}"; do kill -TERM "$p"; done
wait || true
PIDS=()
[ $lrc = 0 ] || { echo "loadgen rc $lrc"; tail -n 5 "$O/loadgen.log"; RC=1; }
grep -qx "write_errors=0" "$O/loadgen/vectordb.txt" || { echo "write errors"; RC=1; }
python3 "$ROOT/experiments/vectordb/urate_check.py" "$O" --writers "$WRITERS" > "$O/urate-check.txt" 2>&1 || RC=1
grep -q "^STEP .* valid=True" "$O/urate-check.txt" || { echo "urate check: update rate not sustained ($(grep '^STEP' "$O/urate-check.txt" | tail -1))"; RC=1; }
python3 "$ROOT/experiments/vectordb/e1_check.py" --writes "$S/writes.bin" --na "$NA" --nb "$NB" --searches "$O/loadgen/searches.bin" \
  --out "$O/e1" > /dev/null 2>&1 && e1="E1 PASS ($(head -n 1 "$O/e1.e1.txt"))" || { e1="E1 FAIL ($(head -n 1 "$O/e1.e1.txt" 2>/dev/null))"; RC=1; }
python3 "$ROOT/experiments/vectordb/staleness_recall.py" --searches "$O/loadgen/searches.bin" --stale "$O/loadgen/stale.bin" \
  --writes "$S/writes.bin" --topk "$S/topk.npz" --out "$O/steps.csv" --run stale-recall-test --rate "$URATE" --boot 1000 \
  --check --monotone-tol "$MON_TOL" > "$O/staleness-recall.txt" 2>&1 || RC=1
for k in 0 1; do
  sed -n '/vdb-server: stopping/,$p' "$S/node$k.log" | grep -E "^(node|P|elements|updates|searches|timeouts|bad_records|writer_threads|write_backlog)=" | tr '\n' ' '; echo
done > "$S/final.txt"
python3 - "$S/final.txt" "$NA" <<'PY' || RC=1
import sys
n0, n1 = [dict(kv.split("=", 1) for kv in l.split()) for l in open(sys.argv[1]) if l.strip()]
na = int(sys.argv[2])
ok = int(n0["updates"]) > 0 and n1["updates"] == "0" and n0["searches"] == "0" and int(n1["searches"]) > 0
ok = ok and all(d["bad_records"] == "0" and d["timeouts"] == "0" and d["write_backlog"] == "0" for d in (n0, n1))
ok = ok and n0["P"] == n1["P"] == str(2 * int(n0["updates"])) and n0["elements"] == n1["elements"] == str(na + int(n0["updates"]))
print(f"final: node0 updates {n0['updates']} searches {n0['searches']} writer_threads {n0['writer_threads']}; node1 updates "
      f"{n1['updates']} searches {n1['searches']}; P {n0['P']}/{n1['P']} elements {n0['elements']}/{n1['elements']}: "
      + ("CONSISTENT" if ok else "INCONSISTENT"))
sys.exit(0 if ok else 1)
PY
echo "$(grep '^STEP' "$O/urate-check.txt" | tail -1)"
echo "$e1"
cat "$O/staleness-recall.txt"
echo "$(grep -E '^(searches_made|stale_groups|stale_records|stale_answered|updates_made)=' "$O/loadgen/vectordb.txt" | tr '\n' ' ')"
echo "STALE RECALL TEST $([ $RC = 0 ] && echo PASS || echo FAIL) -> $S"
exit $RC
