#!/bin/bash
# socialgraph server node inside a guest (workloads/socialgraph), detached from the SSH session, bounded. Same contract
# as scripts/guest/vdb-node.sh (experiments/socialgraph/sg-run.sh calls it over ssh); runs as comsys, no sudo.
# Usage: sg-node.sh start <V> <run_dir> <node_id> <run_id 0x..> <app_bytes> [ENV:K=V ...] <sg-server args...>
#          V = install dir (bin/sg-server, cfg/cxl_region.yaml; lib/ + cfg/megalon.yaml for the Megalon build); writes
#          <run_dir>/node<k>.{log,pid,env}; ENV:K=V tokens (before the server args) are exported to the server
#          (e.g. ENV:CXL_SYSTEM=ds ENV:CXL_DESTIJL_T_US=1000000, ENV:RACKOBJ_CONFIG=... ENV:MEGALON_REINIT=1).
#        sg-node.sh ready <run_dir> <node_id> <timeout_s>   # node log shows "sg-server: READY"
#        sg-node.sh stop  <run_dir> <node_id>               # SIGTERM to the node's session (server prints its stats and
#                                                           # exits), KILL after 15 s, verify gone
#        sg-node.sh copy-image <V> <image file> <log>       # node 0, plain mapping, BEFORE coherence is enabled (Popcorn /
#                                                           # De Stijl: after the cxl_shm load + chown, before the enable;
#                                                           # hw: dax0.0 owned by comsys); sg-server --copy-image, bounded 1800 s
#        sg-node.sh verify <V> <image file> <log>           # read only: sg-server --verify --image (header, hash, records)
set -euo pipefail
case "${1:-}" in
  start)
    [ $# -ge 6 ] || { sed -n 3,8p "$0" >&2; exit 2; }
    V=$2 RUN=$3 K=$4 RID=$5 APP=$6; shift 6
    XENV=()
    while [ $# -gt 0 ] && [ "${1#ENV:}" != "$1" ]; do XENV+=("${1#ENV:}"); shift; done
    case "$RID" in 0x[0-9a-fA-F]*) ;; *) echo "run_id must be 0x-prefixed hex" >&2; exit 2;; esac
    for f in "$RUN/node$K".{log,pid,env}; do [ -e "$f" ] && { echo "refusing: $f exists" >&2; exit 2; }; done
    mkdir -p "$RUN"
    cat > "$RUN/node$K.env" <<ENV
node_id=$K
run_id=$RID
app_hwcc_bytes=$APP
args=$*
extra_env=${XENV[*]:-}
uname_r=$(uname -r)
server_sha256=$(sha256sum "$V/bin/sg-server" | cut -d' ' -f1)
region_sha256=$(sha256sum "$V/cfg/cxl_region.yaml" | cut -d' ' -f1)
start=$(date -Is)
ENV
    setsid nohup env CXL_REGION_CONFIG="$V/cfg/cxl_region.yaml" CXL_APP_HWCC_BYTES="$APP" ${XENV[@]+"${XENV[@]}"} \
      timeout 10800 "$V/bin/sg-server" --node "$K" --run-id "$RID" "$@" > "$RUN/node$K.log" 2>&1 < /dev/null &
    echo $! > "$RUN/node$K.pid"
    echo "started node$K pid $(cat "$RUN/node$K.pid")";;
  ready) RUN=$2 K=$3 T=$4
    for _ in $(seq "$T"); do
      grep -q "sg-server: READY" "$RUN/node$K.log" 2>/dev/null && { echo "node$K READY"; exit 0; }
      grep -q "FATAL" "$RUN/node$K.log" 2>/dev/null && { echo "node$K FATAL: $(grep FATAL "$RUN/node$K.log")"; exit 1; }
      kill -0 "$(cat "$RUN/node$K.pid")" 2>/dev/null || { echo "node$K exited before READY"; exit 1; }
      sleep 1
    done; echo "node$K no READY within ${T}s"; exit 1;;
  stop) RUN=$2 K=$3; SID=$(cat "$RUN/node$K.pid")
    pkill -TERM -s "$SID" || true
    for _ in $(seq 15); do pgrep -s "$SID" >/dev/null || { echo "node$K session $SID gone"; exit 0; }; sleep 1; done
    pkill -KILL -s "$SID" || true; sleep 1
    pgrep -s "$SID" >/dev/null && { echo "node$K session $SID still alive"; exit 1; }
    echo "node$K session $SID killed"; exit 0;;
  copy-image|verify)
    [ $# = 4 ] || { sed -n 3,14p "$0" >&2; exit 2; }
    V=$2 IMG=$3 L=$4
    [ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 2; }
    if [ "$1" = copy-image ]; then A=(--copy-image "$IMG"); else A=(--verify --image "$IMG"); fi
    t=$(date +%s)
    rc=0; env CXL_REGION_CONFIG="$V/cfg/cxl_region.yaml" timeout -k 30 1800 "$V/bin/sg-server" "${A[@]}" > "$L" 2>&1 < /dev/null || rc=$?
    echo "$1 rc=$rc wall_s=$(( $(date +%s) - t )) image_bytes=$(stat -c %s "$IMG") server_sha256=$(sha256sum "$V/bin/sg-server" | cut -d' ' -f1)" | tee -a "$L"
    exit $rc;;
  *) sed -n 3,14p "$0" >&2; exit 2;;
esac
