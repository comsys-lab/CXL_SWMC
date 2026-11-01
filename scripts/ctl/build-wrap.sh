#!/usr/bin/env bash
# build-wrap.sh: run a Host build (or any CPU-heavy job) confined to NUMA node 1 so it cannot disturb a measurement.
# The VMs are pinned to node 0 (vcpupin 0,2,..; numatune strict nodeset 0; /dev/dax1.0 is node 0), so a build that
# uses node-1 CPUs and node-1 memory shares only the root LV with them (hence ionice idle).
#   usage: bash scripts/ctl/build-wrap.sh <command...>
#   example: bash scripts/ctl/build-wrap.sh make -j12 -C kernels/popcorn_new/famfs-linux O=/abs/builds/popcorn_new/13
# While workspaces/MEASUREMENT.lock exists the CPU set is the session partition of measure-env-part.sh (SYS=18-23,50-55,
# 12 threads; MEAS=24-31,56-63 stays free for the measurement tools); without a lock the whole node 1 is used.
# -j is NOT added: pass it yourself (<= 12 under a lock, <= 32 otherwise). Policy: user decision 2026-11-01 23:5x
# (replaces "no build while MEASUREMENT.lock exists"; the hook no-build-during-measurement.sh accepts this wrapper).
set -u
P=/home/comsys/sungsu/destijl-control
LOCK=${MEASUREMENT_LOCK:-$P/workspaces/MEASUREMENT.lock}
if [ -e "$LOCK" ]; then
  BIND=(--physcpubind=18-23,50-55 --membind=1)
else
  BIND=(--cpunodebind=1 --membind=1)
fi
[ $# -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }
exec nice -n 19 ionice -c3 numactl "${BIND[@]}" "$@"
