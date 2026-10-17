#!/bin/bash
# objtest-run.sh <megalon build dir> <tag> <megalon config yaml> <object-test args...>: 2 processes = 2 nodes, Host
# file region. Versioned copy of builds/megalon/71/checks/objtest/run.sh (used for builds 71-77); writes <tag>/ next
# to this script unless OBJTEST_DIR is set. Since 2026-10-17 (verifier LOW): re-checks MEASUREMENT.lock at the end and
# exits 4 if a measurement started during the run (the correctness result stands; the overlap must be reported).
set -u
B=$1 T=$2 CFG=$3; shift 3
D=${OBJTEST_DIR:-$(cd "$(dirname "$0")" && pwd)}/$T
[ -e /home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock ] && { echo "MEASUREMENT.lock present"; exit 3; }
[ -e "$D" ] && { echo "refusing: $D exists"; exit 2; }
mkdir -p "$D"
sed "s#^device: .*#device: $D/region.img#; s#^device_size: .*#device_size: 2415919104#" /home/comsys/sungsu/destijl-control/CXL_SWMC/config/cxl_region.yaml > "$D/region.yaml"
truncate -s 2415919104 "$D/region.img"
RID=0x$(printf '%x' $(( $(date +%s%N) & 0xffffffff | 1 )))
cd "$B/ship"
env RACKOBJ_CONFIG=$CFG CXL_REGION_CONFIG=$D/region.yaml MEGALON_NODE_ID=0 MEGALON_RUN_ID=$RID MEGALON_REINIT=1 \
  numactl --membind=1 taskset -c ${C0:-18-23} timeout 900 bin/object-test "$@" > "$D/node0.log" 2>&1 & P0=$!
for i in $(seq 600); do grep -q "READY published" "$D/node0.log" && break; sleep 0.1; done
env RACKOBJ_CONFIG=$CFG CXL_REGION_CONFIG=$D/region.yaml MEGALON_NODE_ID=1 MEGALON_RUN_ID=$RID \
  numactl --membind=1 taskset -c ${C1:-24-31} timeout 900 bin/object-test "$@" > "$D/node1.log" 2>&1 & P1=$!
wait $P0; R0=$?; wait $P1; R1=$?
rm -f "$D/region.img"
echo "rc0=$R0 rc1=$R1"; grep -h "OBJECT-TEST\|objects: arena" "$D"/node*.log | cut -c1-400
[ -e /home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock ] && { echo "MEASUREMENT.lock appeared during the run"; exit 4; }
[ $R0 = 0 ] && [ $R1 = 0 ]
