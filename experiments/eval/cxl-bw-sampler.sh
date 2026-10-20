#!/bin/bash
# Host CXL.mem bandwidth sampler (user 2026-10-20: "CXL bandwidth 사용량도 같이"). Counts the SPR CXL CM PMU of every
# CXL port, system wide, every INTERVAL ms, with the conversion of Intel PCM (pcm-memory.cpp, cpucounters.cpp,
# non-BHS): read B = unc_cxlcm_rxc_pack_buf_inserts.mem_data (event 0x41 umask 0x10) x 64,
#       write B = unc_cxlcm_txc_pack_buf_inserts.mem_data (event 0x02 umask 0x10) x 64 x 0.5;
# CXL.cache data in both directions is recorded too (umask 0x04; expected ~0 for a Type-3 memory device).
# Needs kernel.perf_event_paranoid <= 0 (set by the user). Runs on the session cpuset 18-23 with nice 19; read only.
# Output <dir>/perf.csv (perf -x, -I) and <dir>/start-epoch.txt (wall clock at perf start, to align with steps.csv);
# cxl-bw.py turns them into a per-interval CSV. Stops when workspaces/MEASUREMENT.lock disappears (UNTIL_UNLOCK=1) or
# after MAX_S seconds.
# usage: cxl-bw-sampler.sh <out dir (new)>
P=/home/comsys/sungsu/destijl-control
D=${1:?out dir}; INTERVAL=${INTERVAL:-1000}; MAX_S=${MAX_S:-21600}; UNTIL_UNLOCK=${UNTIL_UNLOCK:-1}
[ -e "$D" ] && { echo "refuse: $D exists" >&2; exit 1; }
[ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 0 ] || { echo "refuse: perf_event_paranoid > 0" >&2; exit 1; }
mkdir -p "$D" || exit 1
E=unc_cxlcm_rxc_pack_buf_inserts.mem_data,unc_cxlcm_txc_pack_buf_inserts.mem_data
E=$E,unc_cxlcm_rxc_pack_buf_inserts.cache_data,unc_cxlcm_txc_pack_buf_inserts.cache_data,unc_cxlcm_clockticks
{ echo "events=$E interval_ms=$INTERVAL max_s=$MAX_S until_unlock=$UNTIL_UNLOCK"; perf --version
  cat /proc/sys/kernel/perf_event_paranoid; } > "$D/manifest.txt"
date +%s.%N > "$D/start-epoch.txt"
nice -n 19 taskset -c 18-23 perf stat -a --per-socket -e "$E" -I "$INTERVAL" -x, -o "$D/perf.csv" -- sleep "$MAX_S" &
pid=$!
if [ "$UNTIL_UNLOCK" = 1 ]; then
  while kill -0 $pid 2>/dev/null; do
    [ -e $P/workspaces/MEASUREMENT.lock ] || { sleep 5; [ -e $P/workspaces/MEASUREMENT.lock ] || break; }
    sleep 5
  done
  pkill -INT -P $pid 2>/dev/null; kill -INT $pid 2>/dev/null
fi
wait $pid 2>/dev/null
date +%s.%N > "$D/stop-epoch.txt"
echo "CXL-BW SAMPLER DONE $D"
