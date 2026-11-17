#!/bin/bash
# Host test of u0 (experiments/recsys/main-block.sh header "U0"; recsys-amx-2way widening 2026-11-17): serving with NO
# update samples on the windowed-publication train-mode servers, through session.sh with SESSION_LOCAL=1 as
# tests/window_host_test.sh (two local recsys-server processes on a /dev/shm file region, scaled v7 image, node 0
# --update-mode train --publish-window-s PW, node 1 serving). Loadgen options = main-block.sh v7_lgc at rate 0:
# --fixed update=0, prequential with --opt query_window_samples=N. Parts: warmup (1 q/s as main-block.sh, short), an
# idle wait of 2 W + 1 s (the publisher would have published twice), part fix (--raw fixed 2 rates). Proves zero row
# writes: (1) node 0 stats publish_started=0 published_rows=0 samples=0 rows_written=0 update_accepted_seq=0 after the
# parts, (2) sha256 of the shared table bytes (plain swcc area of the region file) identical after READY and after the
# parts, (3) stream_check.py: every measured step valid (the u0 rule: zero accepted / published / written), (4) final
# node logs samples=0 rows_written=0 published_rows=0 (node 0) and rows_written=0 (node 1), as main-block.sh u0_check,
# (5) node 0 stale log has no record (no row became visible), (6) node 1 served queries, (7) v7_metrics.py runs on the
# u0 part (empty node-0 stale log).
# usage: u0_host_test.sh <server build dir> <loadgen build dir> <work dir (new)>
# env: PW (3), ROW_CAP (20000), PORT (27650), QWIN (12000), LG_CPUS (22-23), V7_DATA (workspaces/recsys-data),
#      UPD (0; > 0 = negative control: the same parts with --fixed update=UPD must FAIL the zero-write checks)
set -uo pipefail
B=$(cd "$1" && pwd); LGB=$(cd "$2" && pwd); WD=$3
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd); X=$ROOT/experiments/recsys
P=/home/comsys/sungsu/destijl-control DATA=${V7_DATA:-$P/workspaces/recsys-data}
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
ROW_CAP=${ROW_CAP:-20000} PORT=${PORT:-27650} PW=${PW:-3} QWIN=${QWIN:-12000}
export LG_CPUS=${LG_CPUS:-22-23}
IMG=/dev/shm/recsys-u0-test-$$.img
python3 -I -B "$HERE/make_test_image.py" --out "$WD/emb.img" --row-cap $ROW_CAP --row-div 1 \
  --src "$DATA/v7-ckpt-fp16/emb-fp16.img" || { echo "HOST TEST FAIL: test image"; exit 1; }
SA="--nodes 2 --row-cap $ROW_CAP --row-div 1 --serve-threads 4 --update-threads 2 --load-threads 4 --verify-rows 1
 --start-timeout-ms 900000 --update-mode train --image $WD/emb.img --model-dense $DATA/v7-ckpt-fp16/dense.bin
 --lr 0.0004 --acc-init 0 --train-batch 8 --train-threads 2 --stale-sample 1 --stale-log $WD/stale-n1.stl
 --publish-window-s $PW --split-ways 2 --min-chunk 100"
SA=$(echo $SA)
swcc_need=$("$B/bin/recsys-server" $SA --print-layout | sed -n 's/.* swcc_bytes=\([0-9]*\).*/\1/p')
[ -n "$swcc_need" ] || { echo "HOST TEST FAIL: print-layout"; exit 1; }
HW=$((256 << 20)) AL=$((2 << 20))
ARENA=$(( (swcc_need + AL - 1) / AL * AL ))
DEV=$(( HW + ARENA + (64 << 20) + 8 * AL ))
V=$WD/v; mkdir -p "$V/bin" "$V/cfg" "$V/lib"
cp "$B/bin/recsys-server" "$V/bin/"; cp "$ROOT/scripts/guest/recsys-node.sh" "$V/bin/"
[ -d "$B/lib" ] && cp "$B"/lib/* "$V/lib/"
cat > "$V/cfg/cxl_region.yaml" <<EOF
device: $IMG
map_va: 0x600000000000
device_size: $DEV
align: $AL
hwcc_offset: 0
hwcc_size: $HW
msg_ring: [$((HW - 135168)), 135168]
swcc_offset: auto
swcc_size: auto
reserved: []
EOF
truncate -s "$DEV" "$IMG"
FAIL=0
bad() { echo "CHECK FAIL: $*"; FAIL=1; }
cleanup() { SESSION_LOCAL=1 bash "$X/session.sh" stop "$WD/s" > /dev/null 2>&1; rm -f "$IMG"; }
trap cleanup EXIT
SE=(SESSION_LOCAL=1 PORT=$PORT T_MS=0 V=$V HOST_SERVER=$B/bin/recsys-server READY_TIMEOUT=900
    "NODE0_ARGS=--update-threads 2 --serve-threads 1 --stale-log $WD/stale-n0.stl"
    SYSTEM=all-HWcc "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=3600")
S=$WD/s
env "${SE[@]}" bash "$X/session.sh" start "$S" || { echo "HOST TEST FAIL: session start"; exit 1; }
GRUN=$(sed -n "s/^GRUN='\(.*\)'$/\1/p" "$S/session.env")   # node logs live here until session.sh stop fetches them
off=$(sed -n 's/.*plain swcc_offset=\([0-9]*\).*/\1/p' "$GRUN/node0.log" | head -1)
[ -n "$off" ] || { echo "HOST TEST FAIL: no swcc_offset in $GRUN/node0.log"; exit 1; }
tab() { tail -c +$((off + 1)) "$IMG" | head -c "$swcc_need" | sha256sum | cut -c1-64; }   # the shared table bytes
H0=$(tab); echo "table sha256 after READY: $H0 (swcc_offset $off, $swcc_need B)"
export LOADGEN=$LGB/loadgen PROFILE=pilot RUN_KIND=functional STATS_OP=10 IDLE_WAIT_S=120
SMP=$DATA/v7-samples/day23-0-2M.v3.smp
# = main-block.sh v7_lgc 0
LGC=(--opt samples=$SMP --opt queries=$SMP --opt quantiles=$W/tools/dist_quantile.txt --fixed update=${UPD:-0} --mix query=1
     --x-stream query --opt prequential=1 --opt query_window_samples=$QWIN)
SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" warmup -- "${LGC[@]}" --opt seed=7 --seed 7 --mode fixed --rates 1 \
  --warmup-s 1 --step-warmup-s 0 --step-measure-s 6 --drain-s 2; rc=$?
[ $rc = 0 ] || bad "warmup part rc $rc"
sleep $((2 * PW + 1))   # with an update stream the publisher would have published twice by now
SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" fix -- "${LGC[@]}" --opt seed=9 --seed 9 --raw --mode fixed --rates 2,4 \
  --warmup-s 1 --step-warmup-s 1 --step-measure-s 4 --drain-s 2; rc=$?
[ $rc = 0 ] || bad "fix part rc $rc"
python3 "$X/stats_snap.py" 127.0.0.1:$PORT "$WD/end-n0.txt" > /dev/null || bad "stats node 0"
kv() { sed -n "s/^$1=//p" "$2" | tail -1; }
for k in publish_started published_rows samples rows_written update_accepted_seq published_seq window_distinct; do
  v=$(kv $k "$WD/end-n0.txt"); echo "node 0 stats $k=${v:-missing}"; [ "$v" = 0 ] || bad "node 0 stats $k=${v:-missing} (want 0)"
done
H1=$(tab); echo "table sha256 after the parts: $H1"
[ "$H0" = "$H1" ] || bad "shared table bytes changed during the u0 parts"
for part in warmup fix; do
  python3 -I -B "$X/stream_check.py" "$S/$part" > "$S/$part/stream-check.txt" 2>&1
  grep -m1 '^STREAMCHECK' "$S/$part/stream-check.txt"
  n=$(awk -F, 'NR > 1' "$S/$part/stream-check.csv" | wc -l); nv=$(awk -F, 'NR > 1 && $5 == "True"' "$S/$part/stream-check.csv" | wc -l)
  [ "$n" -gt 0 ] && [ "$n" = "$nv" ] || bad "$part: $nv of $n measured steps valid under the u0 rule"
done
SESSION_LOCAL=1 bash "$X/session.sh" stop "$S"; rc=$?
[ $rc = 0 ] || bad "stop rc $rc"
for k in samples rows_written published_rows; do v=$(kv $k "$S/node0.log"); echo "node0.log $k=${v:-missing}"; [ "$v" = 0 ] || bad "node0.log $k=${v:-missing}"; done
v=$(kv rows_written "$S/node1.log"); echo "node1.log rows_written=${v:-missing}"; [ "$v" = 0 ] || bad "node1.log rows_written=${v:-missing}"
q=$(kv queries "$S/node1.log"); echo "node1.log queries=${q:-missing}"; [ "${q:-0}" -gt 0 ] || bad "node 1 served no query"
s0=$(stat -c %s "$WD/stale-n0.stl" 2>/dev/null); echo "stale-n0.stl $s0 B (64 B header = no record)"; [ "$s0" = 64 ] || bad "node 0 stale log has records (${s0:-missing} B)"
F=$S/fix
python3 -I -B "$W/tools/v7_metrics.py" "$F" --stale0 "$WD/stale-n0.stl" --stale1 "$WD/stale-n1.stl" \
  --frozen "$DATA/v7-ckpt-fp16/frozen-day23-0-2M.scr" --trace-n "$(kv trace_samples "$F/loadgen/recsys.txt")" \
  --steps-out "$WD/v7-steps.csv" --auc-run "$WD/auc_run.csv" --system hw --update-rate 0 --T 0 --run 1 > "$WD/v7-metrics.txt" 2>&1 \
  || bad "v7_metrics.py: $(tail -2 "$WD/v7-metrics.txt")"
tail -1 "$WD/auc_run.csv" 2>/dev/null
[ $FAIL = 0 ] && echo "U0 HOST TEST PASS -> $WD" || { echo "U0 HOST TEST FAIL -> $WD"; exit 1; }
