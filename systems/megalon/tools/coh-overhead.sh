#!/bin/bash
# Overhead of the Megalon coherence instrumentation: build 70 (none) vs 71+ timers off vs 71+ timers on, interleaved
# in one script so it can be rerun on a quiet Host or in the guests (reports/M2-megalon-port-changes.md §13).
#
#   coh-overhead.sh <new out dir> <sections> <rounds> <label=megalon build dir[:VAR=val[,VAR=val...]]>...
#   e.g. coh-overhead.sh /path/out 1000000 5 b70=builds/megalon/70 \
#            off=builds/megalon/72:MEGALON_COH_TIMERS=0 on=builds/megalon/72:MEGALON_COH_TIMERS=1
#
# Each round runs every variant once (order rotated per round); each run = one process per node, node 0 measures
# COH_OV_REPS (default 4) reps of <sections> read and write sections on a 64 B object, node 1 waits. Rep 0 of every
# run is a warm-up (first touches, TSC calibration, page faults) and is excluded from the summary.
# Output: <out>/raw.csv (every rep), <out>/summary.csv (median and mean over reps >= 1 per label), logs per run.
# Each run records the number of compiler/linker processes on the machine before and after (host_busy_*); compare
# only runs with 0/0 (CLAUDE.md: no builds during measurements).
#
# Host mode (default): both nodes on this machine, sparse file region in <out>, MEGALON_REINIT=1, node 1 CPUs
#   (COH_OV_C0 / COH_OV_C1 override the CPU lists). Not shared CXL memory.
# Guest mode (COH_OV_NODE=0|1): this machine runs only that node, on the region of CXL_REGION_CONFIG (the real device:
#   needs a recorded shared-memory grant); the other VM runs the same command with the other node id, the same
#   arguments and the same COH_OV_RUN_ID (required). This script does no chown and no sudo.
set -u
[ $# -ge 4 ] || { sed -n '2,22p' "$0"; exit 2; }
OUT=$1 N=$2 ROUNDS=$3; shift 3
VARIANTS=("$@")
HERE=$(cd "$(dirname "$0")" && pwd)
MSRC=$HERE/../src
CFG=${COH_OV_CONFIG:-$MSRC/config/destijl-2vm-objects.yaml}
REPS=${COH_OV_REPS:-4}
ROOT=/home/comsys/sungsu/destijl-control
[ -e "$ROOT/workspaces/MEASUREMENT.lock" ] && [ -z "${COH_OV_IGNORE_LOCK:-}" ] && { echo "MEASUREMENT.lock present"; exit 3; }
[ -e "$OUT" ] && { echo "refusing: $OUT exists"; exit 2; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# resolve variants
declare -a LBL DIR ENVS
for v in "${VARIANTS[@]}"; do
    l=${v%%=*}; rest=${v#*=}; d=${rest%%:*}; e=""
    [ "$rest" != "$d" ] && e=${rest#*:}
    d=$(cd "$d" && pwd) || exit 2
    [ -f "$d/manifest.txt" ] && [ -f "$d/ship/lib/libmegalon.so" ] || { echo "not a Megalon build: $d"; exit 2; }
    LBL+=("$l"); DIR+=("$d"); ENVS+=("${e//,/ }")
done

# one probe binary for every build (common object API), libmegalon chosen at run time
L0=${DIR[0]}/ship/lib
c++ -std=c++17 -O2 -Wall -I"$MSRC/include" "$HERE/coh_overhead.cc" -o "$OUT/coh-overhead" -L"$L0" -lmegalon \
    -Wl,-rpath-link,"$L0" || exit 1
{
    echo "date=$(date -Is) host=$(hostname) sections=$N rounds=$ROUNDS reps=$REPS config=$CFG"
    echo "probe_sha256=$(sha256sum "$OUT/coh-overhead" | cut -d' ' -f1) source_sha256=$(sha256sum "$HERE/coh_overhead.cc" | cut -d' ' -f1)"
    for i in "${!LBL[@]}"; do
        echo "variant ${LBL[$i]}: dir=${DIR[$i]} env='${ENVS[$i]}' build_id=$(sed -n 's/^build_id=//p' "${DIR[$i]}/manifest.txt") libmegalon_sha256=$(sha256sum "${DIR[$i]}/ship/lib/libmegalon.so" | cut -d' ' -f1)"
    done
} > "$OUT/manifest.txt"
cat "$OUT/manifest.txt"

# Host build processes, matched on the process name only (-x): a -f match on command lines also counted any shell
# whose command text merely contained one of the words, e.g. the operator's own launch command (verifier MED-3).
busy() { local c; c=$(pgrep -c -x '(cc1|cc1plus|cc1obj|rustc|clang|clang\+\+|clang-[0-9]+|ld|ld\.lld|ld\.gold|lld|collect2|as|cargo|make|gmake|ninja|cmake)' 2>/dev/null); echo "${c:-0}"; }

echo "label,round,rep,read_ns,write_ns,kvget_ns,kvput_ns,host_busy_before,host_busy_after,loadavg" > "$OUT/raw.csv"
run_one() {  # idx round
    local i=$1 r=$2 l=${LBL[$1]} d=${DIR[$1]} e=${ENVS[$1]} log=$OUT/run-$2-${LBL[$1]}
    local b0 b1 rc0 rc1=0
    b0=$(busy)
    if [ -z "${COH_OV_NODE:-}" ]; then
        local reg=$OUT/region.yaml
        sed "s#^device: .*#device: $OUT/region.img#; s#^device_size: .*#device_size: 2415919104#" \
            "$ROOT/CXL_SWMC/config/cxl_region.yaml" > "$reg"
        truncate -s 2415919104 "$OUT/region.img"
        local rid=0x$(printf '%x' $(( $(date +%s%N) & 0xffffffff | 1 )))
        env $e COH_OV_LABEL=$l LD_LIBRARY_PATH=$d/ship/lib RACKOBJ_CONFIG=$CFG CXL_REGION_CONFIG=$reg MEGALON_NODE_ID=0 \
            MEGALON_RUN_ID=$rid MEGALON_REINIT=1 numactl --membind=1 taskset -c ${COH_OV_C0:-18-23} timeout 600 \
            "$OUT/coh-overhead" "$N" "$REPS" > "$log.node0.log" 2>&1 & local p0=$!
        for _ in $(seq 600); do grep -q "READY published" "$log.node0.log" && break; sleep 0.1; done
        env $e COH_OV_LABEL=$l LD_LIBRARY_PATH=$d/ship/lib RACKOBJ_CONFIG=$CFG CXL_REGION_CONFIG=$reg MEGALON_NODE_ID=1 \
            MEGALON_RUN_ID=$rid numactl --membind=1 taskset -c ${COH_OV_C1:-24-31} timeout 600 \
            "$OUT/coh-overhead" "$N" "$REPS" > "$log.node1.log" 2>&1
        rc1=$?
        wait $p0; rc0=$?
        rm -f "$OUT/region.img"
    else
        [ -n "${COH_OV_RUN_ID:-}" ] && [ -n "${CXL_REGION_CONFIG:-}" ] || { echo "guest mode needs COH_OV_RUN_ID and CXL_REGION_CONFIG"; exit 2; }
        env $e COH_OV_LABEL=$l LD_LIBRARY_PATH=$d/ship/lib RACKOBJ_CONFIG=$CFG MEGALON_NODE_ID=$COH_OV_NODE \
            MEGALON_RUN_ID=$(( COH_OV_RUN_ID + r * 16 + i )) timeout 600 "$OUT/coh-overhead" "$N" "$REPS" \
            > "$log.node$COH_OV_NODE.log" 2>&1
        rc0=$?
    fi
    b1=$(busy)
    echo "round $r $l: rc0=$rc0 rc1=$rc1 host_busy=$b0/$b1"
    [ "$rc0" = 0 ] && [ "$rc1" = 0 ] || { echo "STOP: run failed ($log.*)"; exit 4; }
    local la; la=$(cut -d' ' -f1 /proc/loadavg)
    sed -n 's/^COH-OV label=\([^ ]*\) rep=\([0-9]*\) read_ns=\([0-9.]*\) write_ns=\([0-9.]*\) kvget_ns=\([0-9.]*\) kvput_ns=\([0-9.]*\).*/\1,'"$r"',\2,\3,\4,\5,\6,'"$b0,$b1,$la"'/p' \
        "$log".node*.log >> "$OUT/raw.csv"
}

nv=${#LBL[@]}
for r in $(seq 1 "$ROUNDS"); do
    for k in $(seq 0 $((nv - 1))); do run_one $(( (k + r - 1) % nv )) "$r"; done
done

python3 -I - "$OUT/raw.csv" "$OUT/summary.csv" <<'EOF'
import csv, statistics, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if int(r["rep"]) >= 1]  # rep 0 = warm-up
out = csv.writer(open(sys.argv[2], "w"))
cols = ["read", "write", "kvget", "kvput"]
out.writerow(["label", "n"] + [f"{c}_{k}_ns" for c in cols for k in ("median", "mean", "stdev")] + ["runs_with_host_builds"])
for l in dict.fromkeys(r["label"] for r in rows):
    s = [r for r in rows if r["label"] == l]
    busy = len({r["round"] for r in s if r["host_busy_before"] != "0" or r["host_busy_after"] != "0"})
    sd = lambda x: statistics.stdev(x) if len(x) > 1 else 0.0
    vals = []
    for c in cols:
        x = [float(r[f"{c}_ns"]) for r in s]
        vals += [f"{statistics.median(x):.1f}", f"{statistics.mean(x):.1f}", f"{sd(x):.1f}"]
    out.writerow([l, len(s)] + vals + [busy])
EOF
column -s, -t "$OUT/summary.csv"
