#!/bin/bash
# Host test of the windowed update publisher (server --publish-window-s W; reports/experiments/recsys-windowed-update.md)
# through session.sh with SESSION_LOCAL=1, as tests/v7_host_test.sh: two local recsys-server processes on a /dev/shm
# file region, a scaled v7 image, node 0 --update-mode train with --publish-window-s PW and --publish-trace, node 1
# serving with every row sampled in its stale log. One part with the update stream and queries for TRAIN_S seconds
# (several windows), then 3 windows without updates (the last lists drain), stop, then tests/window_check.py:
# (1) rows published per window = distinct rows of the previous window, evenly spread per second; (2) published
# values = the trainer's DRAM value, node 1 reads only initial or published values, plain: the shared table equals
# the last published records. Also checks the stats keys of the window mode and torn_rows / update_misses 0.
# usage: window_host_test.sh <server build dir> <loadgen build dir> <work dir (new)> [plain|megalon]
# env: PW (3), TRAIN_S (14), ROW_CAP (20000), PORT (27600), UPD_RATE (200), Q_RATE (2), MG_RPO (1), LG_CPUS (22-23),
#      V7_DATA (workspaces/recsys-data), DELAY_NS (0; > 0 = catch-up test: --publish-test-row-delay-ns, the publisher
#      falls behind; window_check.py --catchup), DRAIN_MAX_S (180). Run pinned to the Host session CPU set (nice 19, ionice idle).
set -uo pipefail
B=$(cd "$1" && pwd); LGB=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd); X=$ROOT/experiments/recsys
P=/home/comsys/sungsu/destijl-control DATA=${V7_DATA:-$P/workspaces/recsys-data}
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
ROW_CAP=${ROW_CAP:-20000} PORT=${PORT:-27600} R=${UPD_RATE:-200} Q=${Q_RATE:-2} PW=${PW:-3} TRAIN_S=${TRAIN_S:-14}
export LG_CPUS=${LG_CPUS:-22-23}
IMG=/dev/shm/recsys-window-test-$$.img
python3 -I -B "$HERE/make_test_image.py" --out "$WD/emb.img" --row-cap $ROW_CAP --row-div 1 \
  --src "$DATA/v7-ckpt-fp16/emb-fp16.img" || { echo "HOST TEST FAIL: test image"; exit 1; }
SA="--nodes 2 --row-cap $ROW_CAP --row-div 1 --serve-threads 4 --update-threads 2 --load-threads 4 --verify-rows 1
 --start-timeout-ms 900000 --update-mode train --image $WD/emb.img --model-dense $DATA/v7-ckpt-fp16/dense.bin
 --lr 0.0004 --acc-init -1 --train-batch 8 --train-threads 2 --stale-sample 1 --stale-log $WD/stale-n1.stl
 --publish-window-s $PW --publish-trace $WD/trace-n1.txt$([ "${DELAY_NS:-0}" = 0 ] || echo " --publish-test-row-delay-ns $DELAY_NS")"
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
# node 0: its own trace / stale log (later values win); node 1 has no window mode (win_on: node 0 only)
SE=(SESSION_LOCAL=1 PORT=$PORT T_MS=0 V=$V HOST_SERVER=$B/bin/recsys-server READY_TIMEOUT=900
    "NODE0_ARGS=--update-threads 2 --serve-threads 1 --stale-log $WD/stale-n0.stl --publish-trace $WD/trace-n0.txt")
if [ "$BACKEND" = megalon ]; then
  sed -e "s/^object_arena_size:.*/object_arena_size: $ARENA/" -e "s/^logical_scr_size:.*/logical_scr_size: 64MB/" \
      "$W/tests/megalon-host.yaml" > "$V/cfg/megalon.yaml"
  SE+=(SYSTEM=Megalon "SERVER_ARGS=--backend megalon --mg-rows-per-object ${MG_RPO:-1} $SA" "NODE_ENV=ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml ENV:XTIMEOUT=3600"
       "NODE0_ENV=ENV:MEGALON_REINIT=1")
else
  SE+=(SYSTEM=all-HWcc "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=3600")
fi
S=$WD/s
env "${SE[@]}" bash "$X/session.sh" start "$S" || { echo "HOST TEST FAIL: session start"; exit 1; }
grep -h "windowed publication" "$S"/*.log /dev/null 2>/dev/null | head -2
export LOADGEN=$LGB/loadgen PROFILE=pilot RUN_KIND=functional STATS_OP=10 IDLE_WAIT_S=120
SMP=$DATA/v7-samples/day23-0-2M.v3.smp
LGC=(--opt samples=$SMP --opt quantiles=$W/tools/dist_quantile.txt --fixed update=$R --mix query=1 --x-stream query
     --opt prequential=1 --opt update_rate=$R --opt query_window_s=60 --drain-s 2)
# as main-block.sh pub_train: the update stream alone (--rates 0, no queries) for W + 2 s, then publish_started=1
SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" pubtrain -- "${LGC[@]}" --mode fixed --rates 0 --warmup-s 0 \
  --step-warmup-s 0 --step-measure-s $((PW + 2)) --drain-s 2; rc=$?
[ $rc = 0 ] || bad "pubtrain part rc $rc"
[ "$(sed -n 's/^publish_started=//p' "$S/pubtrain/post-t0.txt")" = 1 ] || bad "publish_started != 1 after pubtrain"
[ "$(sed -n 's/^queries=//p' "$S/pubtrain/post-t1.txt")" = 0 ] || bad "queries during pubtrain"
SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" train -- "${LGC[@]}" --raw --mode fixed --rates "$Q" --warmup-s 2 \
  --step-warmup-s 0 --step-measure-s "$TRAIN_S"; rc=$?
[ $rc = 0 ] || bad "train part rc $rc"
# stats-steps.csv: the window gauges keep their end value (stats_delta.py), published_rows is a delta
python3 -I -c 'import csv,sys
r=list(csv.DictReader(open(sys.argv[1])))
r=[x for x in r if x.get("published_rows")]
assert r, "no node-0 row with published_rows"
x=r[-1]
assert int(x["publish_started"])==1 and int(x["dram_rows"])>0 and int(x["published_rows"])>0, x
print("stats-steps.csv node 0: published_rows(delta)=%s window_distinct=%s publish_backlog=%s dram_rows=%s" % (x["published_rows"], x["window_distinct"], x["publish_backlog"], x["dram_rows"]))' \
  "$S/train/stats-steps.csv" || bad "stats-steps.csv window columns"
sleep $((3 * PW + 2))   # the lists of the last windows with updates drain (no updates now)
# catch-up (DELAY_NS > 0): the slow publisher may still hold queued rows; wait until none is queued (bounded)
for i in $(seq 1 $(( ${DRAIN_MAX_S:-180} / 2 ))); do
  python3 "$X/stats_snap.py" 127.0.0.1:$PORT "$WD/final-n0.txt" > /dev/null || bad "stats node 0"
  [ "$(sed -n 's/^publish_queued=//p' "$WD/final-n0.txt")" = 0 ] && break
  [ $i = 1 ] && echo "catch-up: $(grep -h '^publish_queued=\|^publish_backlog=\|^publish_carryover_rows=' "$WD/final-n0.txt" | tr '\n' ' ')"
  sleep 2
done
sleep $((PW + 1)); python3 "$X/stats_snap.py" 127.0.0.1:$PORT "$WD/final-n0.txt" > /dev/null || bad "stats node 0"
SESSION_LOCAL=1 bash "$X/session.sh" stop "$S"; rc=$?
[ $rc = 0 ] || bad "stop rc $rc"
kv() { sed -n "s/^$1=//p" "$2" | tail -1; }
for k in publish_window_s publish_started publish_window published_rows publish_backlog window_distinct \
         publish_lag_ns_sum publish_lag_ns_count publish_lag_ns_max dram_rows dram_capacity dram_bytes; do
  [ -n "$(kv $k "$WD/final-n0.txt")" ] || bad "stats key $k missing on node 0"
done
[ "$(kv publish_started "$WD/final-n0.txt")" = 1 ] || bad "publish_started != 1"
[ "$(kv publish_backlog "$WD/final-n0.txt")" = 0 ] || bad "publish_backlog != 0 after the drain"
[ "$(kv publish_queued "$WD/final-n0.txt")" = 0 ] || bad "publish_queued != 0 after the drain"
grep -q "^recsys-server: publishing started" "$S/node0.log" || bad "no 'publishing started' line"
[ -z "$(grep -h '^published_rows=' "$S/node1.log")" ] || bad "node 1 has window keys"
[ "$(grep -h '^torn_rows=' "$S"/node*.log | grep -vc '=0$')" = 0 ] || bad "torn rows"
[ "$(grep -h '^update_misses=' "$S"/node*.log | grep -vc '=0$')" = 0 ] || bad "update misses"
grep -h "^recsys-server: publish window\|^recsys-server: publishing started\|^recsys-server: windowed" "$S/node0.log"
grep -h "^published_rows=\|^dram_rows=\|^dram_bytes=\|^dram_updates=\|^train_dram_hits=\|^rows_written=\|^publish_lag_ns_sum=\|^publish_lag_ns_count=\|^publish_sections=\|^megalon.write_sections=" "$S/node0.log"
CK=(--trace "$WD/trace-n0.txt" --W "$PW" --image "$WD/emb.img" --stale1 "$WD/stale-n1.stl")
if [ "${DELAY_NS:-0}" != 0 ]; then
  CK+=(--catchup)
  c=$(sed -n 's/^publish_carryover_rows=//p' "$WD/final-n0.txt"); [ "${c:-0}" -gt 0 ] || bad "catch-up: no row carried over (publisher never fell behind)"
  echo "catch-up: publish_carryover_rows=$c (rows still queued when a later list arrived)"
fi
if [ "$BACKEND" = plain ]; then
  off=$(sed -n 's/.*plain swcc_offset=\([0-9]*\).*/\1/p' "$S/node0.log" | head -1)
  [ -n "$off" ] || bad "no swcc_offset in node0.log"
  CK+=(--region "$IMG" --swcc-offset "${off:-0}")
fi
python3 -I -B "$HERE/window_check.py" "${CK[@]}" > "$WD/window-check.txt" 2>&1
cat "$WD/window-check.txt"
grep -q "^WINDOW CHECK PASS" "$WD/window-check.txt" || bad "window_check.py"
[ $FAIL = 0 ] && echo "WINDOW HOST TEST PASS ($BACKEND) -> $WD" || { echo "WINDOW HOST TEST FAIL ($BACKEND) -> $WD"; exit 1; }
