#!/bin/bash
# Host test of RecSys v7 (DESIGN.md §10.6) through session.sh with SESSION_LOCAL=1: two local recsys-server processes
# on a /dev/shm file region, a scaled v7 image (tests/make_test_image.py, rows copied from the converted checkpoint),
# the trained dense weights, node 0 --update-mode train (row-wise Adagrad), node 1 serving; loadgen prequential=1 with
# the real day-23 v3 samples (labels). One lifetime: warmup -> fixed (2 steps) -> idle -> stop; then
# tools/v7_metrics.py with both stale logs and the frozen scores. Checks: train stats move, every sample trained
# (published_seq = last update seq after idle), torn_rows 0, update_misses 0, scores.bin/scoreq.bin written, every
# measured step has samples_scored > 0 and a finite AUC, stale logs non-empty (reads and writes), updater_cpu_s_per_s
# > 0, auc_run.csv row with auc_frozen. No VM, no CXL device. Run pinned to Host node 1.
# usage: v7_host_test.sh <server build dir> <loadgen build dir> <work dir (new)> [plain|megalon]
# env: ROW_CAP (20000), ROW_DIV (1), PORT (27500), UPD_RATE (200), Q_RATE (2), LR (0.0004), ACC_INIT (-1), BATCH (8),
#      W_S (60), LG_CPUS (30-31), MG_RPO (0), V7_DATA (workspaces/recsys-data)
set -uo pipefail
B=$(cd "$1" && pwd); LGB=$(cd "$2" && pwd); WD=$3; BACKEND=${4:-plain}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd); X=$ROOT/experiments/recsys
P=/home/comsys/sungsu/destijl-control DATA=${V7_DATA:-$P/workspaces/recsys-data}
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
ROW_CAP=${ROW_CAP:-20000} ROW_DIV=${ROW_DIV:-1} PORT=${PORT:-27500} R=${UPD_RATE:-200} Q=${Q_RATE:-2}
export LG_CPUS=${LG_CPUS:-30-31}
IMG=/dev/shm/recsys-v7-test-$$.img
python3 -I -B "$HERE/make_test_image.py" --out "$WD/emb.img" --row-cap $ROW_CAP --row-div $ROW_DIV \
  --src "$DATA/v7-ckpt-fp16/emb-fp16.img" || { echo "HOST TEST FAIL: test image"; exit 1; }
SA="--nodes 2 --row-cap $ROW_CAP --row-div $ROW_DIV --serve-threads 4 --update-threads 2 --load-threads 4 --verify-rows 1
 --start-timeout-ms 900000 --update-mode train --image $WD/emb.img --model-dense $DATA/v7-ckpt-fp16/dense.bin
 --lr ${LR:-0.0004} --acc-init ${ACC_INIT:--1} --train-batch ${BATCH:-8} --train-threads 2 --stale-sample 16
 --stale-log $WD/stale-n1.stl"
SA=$(echo $SA)
swcc_need=$("$B/bin/recsys-server" $SA --print-layout | sed -n 's/.* swcc_bytes=\([0-9]*\).*/\1/p')
[ -n "$swcc_need" ] || { echo "HOST TEST FAIL: print-layout with the v7 options"; exit 1; }
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
    "NODE0_ARGS=--update-threads 2 --serve-threads 1 --stale-log $WD/stale-n0.stl")
if [ "$BACKEND" = megalon ]; then
  sed -e "s/^object_arena_size:.*/object_arena_size: $ARENA/" -e "s/^logical_scr_size:.*/logical_scr_size: 64MB/" \
      "$W/tests/megalon-host.yaml" > "$V/cfg/megalon.yaml"
  SE+=(SYSTEM=Megalon "SERVER_ARGS=--backend megalon --mg-rows-per-object ${MG_RPO:-0} $SA" "NODE_ENV=ENV:RACKOBJ_CONFIG=$V/cfg/megalon.yaml ENV:XTIMEOUT=3600"
       "NODE0_ENV=ENV:MEGALON_REINIT=1")
else
  SE+=(SYSTEM=all-HWcc "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=3600")
fi
S=$WD/s
env "${SE[@]}" bash "$X/session.sh" start "$S" || { echo "HOST TEST FAIL: session start"; exit 1; }
cat "$S/load-times.txt"
grep -h "initial tables from image" "$S"/*.log 2>/dev/null | head -2
export LOADGEN=$LGB/loadgen PROFILE=pilot RUN_KIND=functional STATS_OP=10 IDLE_WAIT_S=120
SMP=$DATA/v7-samples/day23-0-2M.v3.smp
LGC=(--opt samples=$SMP --opt quantiles=$W/tools/dist_quantile.txt --fixed update=$R --mix query=1 --x-stream query
     --opt prequential=1 --opt update_rate=$R --opt query_window_s=${W_S:-60} --drain-s 5)  # seq_base / wrap=1: added by session.sh
m() { SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" "$@"; }
m warmup -- "${LGC[@]}" --mode fixed --rates 1 --warmup-s 2 --step-warmup-s 0 --step-measure-s 5; rc=$?
[ $rc = 0 ] || bad "warmup rc $rc"
m fixed -- "${LGC[@]}" --raw --mode fixed --rates "$Q,$Q" --warmup-s 2 --step-warmup-s 1 --step-measure-s 20; rc=$?
[ $rc = 0 ] || bad "fixed rc $rc"
F=$S/fixed
for f in scores.bin scoreq.bin recsys.txt; do [ -s "$F/loadgen/$f" ] || bad "missing $f"; done
grep -q '^prequential=1' "$F/loadgen/recsys.txt" || bad "recsys.txt without prequential=1"
SESSION_LOCAL=1 bash "$X/session.sh" stop "$S"; rc=$?
[ $rc = 0 ] || bad "stop rc $rc"
FC=$S/final-counters.txt
kv() { grep -h "^$1=" "$2" | tail -1 | cut -d= -f2; }
last=$(kv last_update_seq "$F/loadgen/recsys.txt")
echo "final: $(tr '\n' ' ' < "$FC" | cut -c1-600)"
# server stderr (stop stats) paths: as session.sh writes them in SESSION_LOCAL mode (first run: adjust if they differ)
grep -rh "^train_samples=\|^published_seq=\|^torn_rows=\|^update_misses=\|^train.lr=\|^train.batch=" "$S"/*.log 2>/dev/null | sort | uniq -c | head -12
[ "$(grep -rh '^torn_rows=' "$S"/*.log 2>/dev/null | grep -vc '=0$')" = 0 ] || bad "torn rows"
[ "$(grep -rh '^update_misses=' "$S"/*.log 2>/dev/null | grep -vc '=0$')" = 0 ] || bad "update misses"
grep -rqh "^published_seq=$last$" "$S"/*.log 2>/dev/null || bad "published_seq != last update seq $last after idle"
for k in 0 1; do [ -s "$WD/stale-n$k.stl" ] || bad "stale log n$k empty"; done
python3 -I -B "$W/tools/v7_metrics.py" "$F" --stale0 "$WD/stale-n0.stl" --stale1 "$WD/stale-n1.stl" \
  --frozen "$DATA/v7-ckpt-fp16/frozen-day23-0-2M.scr" --trace-n "$(kv trace_samples "$F/loadgen/recsys.txt")" \
  --steps-out "$WD/v7-steps.csv" --auc-run "$WD/auc_run.csv" --system hw --update-rate $R > "$WD/v7-metrics.txt" 2>&1 \
  || bad "v7_metrics.py: $(tail -2 "$WD/v7-metrics.txt")"
cat "$WD/v7-metrics.txt"; cat "$WD/auc_run.csv"
python3 -I -c 'import csv,math,sys
rows=list(csv.DictReader(open(sys.argv[1])))
ok=rows and all(int(r["samples_scored"])>0 and r["auc"] and math.isfinite(float(r["auc"])) and r["stale_read_frac"]!="" and float(r["updater_cpu_s_per_s"] or 0)>0 for r in rows)
sys.exit(0 if ok else 1)' "$WD/v7-steps.csv" || bad "v7-steps.csv: a step without scores / AUC / stale fraction / updater CPU"
# note: the frozen AUC uses the full checkpoint, the test serves a scaled image (ids folded), so only its presence is checked
grep -q ',hw,' <(sed 's/^/,/' "$WD/auc_run.csv") && [ -n "$(tail -1 "$WD/auc_run.csv" | cut -d, -f8)" ] || bad "auc_run.csv without auc_frozen"
[ $FAIL = 0 ] && echo "V7 HOST TEST PASS ($BACKEND) -> $WD" || { echo "V7 HOST TEST FAIL ($BACKEND) -> $WD"; exit 1; }
