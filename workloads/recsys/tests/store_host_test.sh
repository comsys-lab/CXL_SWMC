#!/bin/bash
# Host test of the server's --store rn|sr (fp16 row store: round-to-nearest / stochastic rounding; experiment
# recsys-training-auc) through session.sh with SESSION_LOCAL=1, set up as tests/v7_host_test.sh (two local recsys-server
# processes on a /dev/shm file region, scaled v7 image, node 0 --update-mode train, node 1 serving, loadgen
# prequential=1 with the real day-23 samples). Five lifetimes:
#   identity (write-through, --train-batch 1, uniform update arrivals at ID_RATE = 20/s, ID_S = 30 s, so every sample is
#   its own batch and is applied before the next one arrives): id-old = OLD build (no --store), id-rn = NEW --store rn,
#   id-sr = NEW --store sr. After stop the shared table (plain swcc_offset of node0.log) is compared record by record:
#   every row with the same seq in id-old and id-rn must be bit-identical (embedding + Adagrad acc; rows whose seq
#   differs = only the samples at the window edge), >= 1000 trained rows compared; id-sr must differ in >= 1 such row.
#   drift (windowed W = DR_PW = 10 s, Poisson updates at DR_RATE = 400/s, DR_STEPS = 6 steps x DR_STEP_S = 15 s, 2 q/s,
#   lr 4e-4 acc-init 0, the v7 / v8 training): dr-rn (NEW --store rn) and dr-sr (NEW --store sr); per step
#   tools/training_auc_steps.py (pred_ctr, true_ctr). PASS rule (fixed before the first run): over the steps, sr's
#   calibration drift d = (pred - true)_last - (pred - true)_first is below rn's, and sr's last-step pred_ctr / true_ctr
#   is in [0.8, 1.25]. Every lifetime: torn_rows 0, update_misses 0, train.store= in the stats as asked.
# usage: store_host_test.sh <NEW server build dir> <OLD server build dir> <loadgen build dir> <work dir (new)>
# env: ROW_CAP (20000), PORT (27700), LG_CPUS (22-23), V7_DATA (workspaces/recsys-data), ID_RATE, ID_S, DR_RATE,
#      DR_PW, DR_STEPS, DR_STEP_S. No VM, no CXL device; run inside the Host session CPU set (nice 19).
set -uo pipefail
NB=$(cd "$1" && pwd); OB=$(cd "$2" && pwd); LGB=$(cd "$3" && pwd); WD=$4
HERE=$(cd "$(dirname "$0")" && pwd); W=$(cd "$HERE/.." && pwd); ROOT=$(cd "$W/../.." && pwd); X=$ROOT/experiments/recsys
P=/home/comsys/sungsu/destijl-control DATA=${V7_DATA:-$P/workspaces/recsys-data}
[ -e "$WD" ] && { echo "refusing: $WD exists"; exit 2; }
mkdir -p "$WD"; WD=$(cd "$WD" && pwd)
ROW_CAP=${ROW_CAP:-20000} PORT=${PORT:-27700}
IDR=${ID_RATE:-20} IDS=${ID_S:-30} DRR=${DR_RATE:-400} DRPW=${DR_PW:-10} DRN=${DR_STEPS:-6} DRS=${DR_STEP_S:-15}
export LG_CPUS=${LG_CPUS:-22-23}
python3 -I -B "$HERE/make_test_image.py" --out "$WD/emb.img" --row-cap $ROW_CAP --row-div 1 \
  --src "$DATA/v7-ckpt-fp16/emb-fp16.img" || { echo "STORE HOST TEST FAIL: test image"; exit 1; }
SMP=$DATA/v7-samples/day23-0-2M.v3.smp
FAIL=0
bad() { echo "CHECK FAIL: $*"; FAIL=1; }
CUR_S= CUR_IMG=
cleanup() { [ -z "$CUR_S" ] || SESSION_LOCAL=1 bash "$X/session.sh" stop "$CUR_S" > /dev/null 2>&1; [ -z "$CUR_IMG" ] || rm -f "$CUR_IMG"; }
trap cleanup EXIT
export LOADGEN=$LGB/loadgen PROFILE=pilot RUN_KIND=functional STATS_OP=10 IDLE_WAIT_S=120
life() {  # <name> <build> <store args> <batch> <publish window s> <update rate> <arrival> <rates> <step s> <acc-init>
  local n=$1 b=$2 st=$3 bt=$4 pw=$5 r=$6 arr=$7 rates=$8 ss=$9 ai=${10}
  local L=$WD/$n S=$WD/$n/s IMG=/dev/shm/recsys-store-test-$$-$n.img SA swcc_need HW AL ARENA DEV V rc off
  mkdir -p "$L"
  SA="--nodes 2 --row-cap $ROW_CAP --row-div 1 --serve-threads 4 --update-threads 2 --load-threads 4 --verify-rows 1
   --start-timeout-ms 900000 --update-mode train --image $WD/emb.img --model-dense $DATA/v7-ckpt-fp16/dense.bin
   --lr 0.0004 --acc-init $ai --train-batch $bt --train-threads $([ "$bt" = 1 ] && echo 1 || echo 2) --stale-sample 16
   --stale-log $L/stale-n1.stl $st $([ "$pw" = 0 ] || echo "--publish-window-s $pw")"
  SA=$(echo $SA)
  swcc_need=$("$b/bin/recsys-server" $SA --print-layout | sed -n 's/.* swcc_bytes=\([0-9]*\).*/\1/p')
  [ -n "$swcc_need" ] || { bad "$n: print-layout"; return 1; }
  HW=$((256 << 20)) AL=$((2 << 20)); ARENA=$(( (swcc_need + AL - 1) / AL * AL )); DEV=$(( HW + ARENA + (64 << 20) + 8 * AL ))
  V=$L/v; mkdir -p "$V/bin" "$V/cfg" "$V/lib"
  cp "$b/bin/recsys-server" "$V/bin/"; cp "$ROOT/scripts/guest/recsys-node.sh" "$V/bin/"
  printf 'device: %s\nmap_va: 0x600000000000\ndevice_size: %s\nalign: %s\nhwcc_offset: 0\nhwcc_size: %s\nmsg_ring: [%s, 135168]\nswcc_offset: auto\nswcc_size: auto\nreserved: []\n' \
    "$IMG" "$DEV" "$AL" "$HW" "$((HW - 135168))" > "$V/cfg/cxl_region.yaml"
  truncate -s "$DEV" "$IMG"; CUR_IMG=$IMG CUR_S=$S
  env SESSION_LOCAL=1 PORT=$PORT T_MS=0 V=$V HOST_SERVER=$b/bin/recsys-server READY_TIMEOUT=900 SYSTEM=all-HWcc \
    "SERVER_ARGS=$SA" "NODE_ENV=ENV:XTIMEOUT=3600" \
    "NODE0_ARGS=--update-threads 2 --serve-threads 1 --stale-log $L/stale-n0.stl" \
    bash "$X/session.sh" start "$S" > "$L/start.log" 2>&1 || { bad "$n: session start ($L/start.log)"; return 1; }
  local LGC=(--opt samples=$SMP --opt quantiles=$W/tools/dist_quantile.txt --fixed update=$r --mix query=1 --x-stream query
             --opt prequential=1 --opt update_rate=$r --opt query_window_s=60 --drain-s 5 --arrival $arr --seed 7 --opt seed=7)
  SESSION_LOCAL=1 bash "$X/session.sh" measure "$S" m -- "${LGC[@]}" --raw --mode fixed --rates "$rates" --warmup-s 2 \
    --step-warmup-s 0 --step-measure-s "$ss" > "$L/measure.log" 2>&1; rc=$?
  [ $rc = 0 ] || bad "$n: measure rc $rc ($L/measure.log)"
  SESSION_LOCAL=1 bash "$X/session.sh" stop "$S" > "$L/stop.log" 2>&1; rc=$?; CUR_S=
  [ $rc = 0 ] || bad "$n: stop rc $rc"
  [ "$(grep -h '^torn_rows=' "$S"/node*.log | grep -vc '=0$')" = 0 ] || bad "$n: torn rows"
  [ "$(grep -h '^update_misses=' "$S"/node*.log | grep -vc '=0$')" = 0 ] || bad "$n: update misses"
  off=$(sed -n 's/.*plain swcc_offset=\([0-9]*\).*/\1/p' "$S/node0.log" | head -1)
  [ -n "$off" ] || bad "$n: no swcc_offset in node0.log"
  dd if="$IMG" of="$L/table.bin" bs=1M iflag=skip_bytes,count_bytes skip="${off:-0}" count="$swcc_need" status=none || bad "$n: table copy"
  rm -f "$IMG"; CUR_IMG=
  echo "$n: $(grep -h '^train_samples=\|^train_batches=\|^train.store=\|^train.acc_init=\|^rows_written=\|^dram_updates=\|^published_rows=' "$S/node0.log" | tr '\n' ' ')"
}
store_kv() { grep -h '^train.store=' "$WD/$1/s/node0.log" | tail -1 | cut -d= -f2; }
# ---- identity: old vs new rn (bit-identical rows) vs new sr
life id-old "$OB" "" 1 0 $IDR uniform 1 $IDS 0
life id-rn "$NB" "--store rn" 1 0 $IDR uniform 1 $IDS 0
life id-sr "$NB" "--store sr" 1 0 $IDR uniform 1 $IDS 0
[ -z "$(grep -h '^train.store=' "$WD/id-old/s/node0.log")" ] || bad "old build reports train.store"
[ "$(store_kv id-rn)" = rn ] && [ "$(store_kv id-sr)" = sr ] || bad "train.store not rn / sr in the stats"
grep -q 'train.store=sr' "$WD/id-sr/s/node0.log" && grep -q '^recsys-server: v7 .*train.store=sr' "$WD/id-sr/s/node0.log" || bad "start line without train.store=sr"
python3 -I - "$WD" <<'PY' || bad "identity compare"
import sys, numpy as np
wd = sys.argv[1]
rec = np.dtype([("key", "<u8"), ("seq", "<u8"), ("csum", "<u4"), ("acc", "<f4"), ("pad", "u1", (40,)), ("emb", "<u2", (128,))])
t = {n: np.fromfile(f"{wd}/{n}/table.bin", dtype=rec) for n in ("id-old", "id-rn", "id-sr")}
o, r, s = t["id-old"], t["id-rn"], t["id-sr"]
assert len(o) == len(r) == len(s) and len(o) > 0
tr = (o["seq"] > 0) | (r["seq"] > 0)
same = tr & (o["seq"] == r["seq"])
neq = same & ((o["emb"] != r["emb"]).any(axis=1) | (o["acc"] != r["acc"]) | (o["csum"] != r["csum"]))
seqdiff = int((tr & (o["seq"] != r["seq"])).sum())
ss = (s["seq"] > 0) & (s["seq"] == r["seq"])
sdiff = ss & (s["emb"] != r["emb"]).any(axis=1)
print(f"identity: trained rows old/rn {int(tr.sum())}, same seq {int(same.sum())}, of those differing old vs rn {int(neq.sum())}, "
      f"seq differs (window edge) {seqdiff}; sr vs rn same-seq rows {int(ss.sum())}, emb differs {int(sdiff.sum())}; "
      f"untrained rows equal {bool((o[~tr] == r[~tr]).all())}")
ok = same.sum() >= 1000 and neq.sum() == 0 and (o[~tr] == r[~tr]).all() and sdiff.sum() > 0 and seqdiff <= 0.05 * tr.sum()
print("IDENTITY " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
# ---- drift: windowed, Poisson, rn vs sr
RATES=$(printf '2%.0s,' $(seq 1 $DRN)); RATES=${RATES%,}
for st in rn sr; do
  life dr-$st "$NB" "--store $st" 8 $DRPW $DRR poisson "$RATES" $DRS 0
  cp "$WD/dr-$st/stale-n0.stl" "$WD/dr-$st/stale-n1.stl" "$WD/dr-$st/s/m/" 2>/dev/null
  python3 -I -B "$W/tools/training_auc_steps.py" --out "$WD/drift-steps.csv" --system hw --store $st --acc-init 0 \
    --frozen "$DATA/v7-ckpt-fp16/frozen-day23-0-2M.scr" --trace-n "$(sed -n 's/^trace_samples=//p' "$WD/dr-$st/s/m/loadgen/recsys.txt")" \
    "$WD/dr-$st/s/m" > "$WD/dr-$st/steps.txt" 2>&1 || bad "training_auc_steps.py dr-$st ($(tail -1 "$WD/dr-$st/steps.txt"))"
done
cat "$WD/drift-steps.csv"
python3 -I - "$WD/drift-steps.csv" <<'PY' || bad "drift rule"
import csv, sys
r = list(csv.DictReader(open(sys.argv[1])))
d = {}
for st in ("rn", "sr"):
    x = [y for y in r if y["store"] == st and y["pred_ctr"]]
    assert len(x) >= 3, f"{st}: {len(x)} steps with scores"
    e0, e1 = float(x[0]["pred_ctr"]) - float(x[0]["true_ctr"]), float(x[-1]["pred_ctr"]) - float(x[-1]["true_ctr"])
    d[st] = (e1 - e0, float(x[-1]["pred_ctr"]) / float(x[-1]["true_ctr"]), sum(int(y["samples_scored"]) for y in x))
    print(f"drift {st}: calibration error first {e0:+.4f} last {e1:+.4f} drift {e1 - e0:+.4f}, last pred/true {d[st][1]:.3f}, scored {d[st][2]}")
ok = d["sr"][0] < d["rn"][0] and 0.8 <= d["sr"][1] <= 1.25
print("DRIFT " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
for st in rn sr; do [ "$(store_kv dr-$st)" = $st ] || bad "dr-$st: train.store != $st"; done
[ $FAIL = 0 ] && echo "STORE HOST TEST PASS -> $WD" || { echo "STORE HOST TEST FAIL -> $WD"; exit 1; }
