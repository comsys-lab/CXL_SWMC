#!/bin/bash
# LMDB server node inside a guest (workloads/lmdb), detached from the SSH session, bounded. Same interface as
# scripts/guest/kv-node.sh (lives here until scripts/guest gets a generic node script; installed into <V>/bin).
# Usage: lmdb-node.sh start <V> <run_dir> <node_id> <run_id 0x..> <app_bytes> [ENV:K=V ...] <lmdb-server args...>
#          V = install dir (bin/lmdb-server, cfg/cxl_region.yaml; lib/ for the Megalon build); writes
#          <run_dir>/node<k>.{log,pid,env}. ENV:K=V tokens (before the server args) are exported to the server
#          (e.g. ENV:RACKOBJ_CONFIG=... ENV:MEGALON_REINIT=1 for the Megalon backend).
#        lmdb-node.sh ready <run_dir> <node_id> <timeout_s>   # node log shows "lmdb-server: READY"
#        lmdb-node.sh stop  <run_dir> <node_id> [wait_s]      # SIGTERM to the node's session (server prints its
#                                                            # stats, exits), KILL after
#                                                            # wait_s (default 15)
set -euo pipefail
case "${1:-}" in
  start)
    [ $# -ge 6 ] || { sed -n 2,7p "$0" >&2; exit 2; }
    V=$2 RUN=$3 K=$4 RID=$5 APP=$6; shift 6
    XENV=(); XTIMEOUT=14400  # server lifetime bound (s); ENV:XTIMEOUT=N overrides (Megalon prepare at full size)
    while [ $# -gt 0 ] && [ "${1#ENV:}" != "$1" ]; do
      case "${1#ENV:}" in XTIMEOUT=*) XTIMEOUT=${1#ENV:XTIMEOUT=};; *) XENV+=("${1#ENV:}");; esac; shift
    done
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
server_sha256=$(sha256sum "$V/bin/lmdb-server" | cut -d' ' -f1)
shim_sha256=$( [ -e "$V/lib/libmegalon-objapi.so" ] && sha256sum "$V/lib/libmegalon-objapi.so" | cut -d' ' -f1 || echo none)
libmegalon_sha256=$( [ -e "$V/lib/libmegalon.so" ] && sha256sum "$V/lib/libmegalon.so" | cut -d' ' -f1 || echo none)
timeout_s=$XTIMEOUT
region_sha256=$(sha256sum "$V/cfg/cxl_region.yaml" | cut -d' ' -f1)
start=$(date -Is)
ENV
    setsid nohup env CXL_REGION_CONFIG="$V/cfg/cxl_region.yaml" CXL_APP_HWCC_BYTES="$APP" ${XENV[@]+"${XENV[@]}"} \
      timeout "$XTIMEOUT" "$V/bin/lmdb-server" --node "$K" --run-id "$RID" "$@" > "$RUN/node$K.log" 2>&1 < /dev/null &
    echo $! > "$RUN/node$K.pid"
    echo "started node$K pid $(cat "$RUN/node$K.pid")";;
  ready) RUN=$2 K=$3 T=$4
    for _ in $(seq "$T"); do
      grep -q "lmdb-server: READY" "$RUN/node$K.log" 2>/dev/null && { echo "node$K READY"; exit 0; }
      grep -q "FATAL" "$RUN/node$K.log" 2>/dev/null && { echo "node$K FATAL: $(grep FATAL "$RUN/node$K.log")"; exit 1; }
      kill -0 "$(cat "$RUN/node$K.pid")" 2>/dev/null || { echo "node$K exited before READY"; exit 1; }
      sleep 1
    done; echo "node$K no READY within ${T}s"; exit 1;;
  stop) RUN=$2 K=$3 WAIT=${4:-15}; SID=$(cat "$RUN/node$K.pid")
    [[ $WAIT =~ ^[0-9]+$ ]] || { echo "bad wait_s" >&2; exit 2; }
    pkill -TERM -s "$SID" || true
    for _ in $(seq "$WAIT"); do pgrep -s "$SID" >/dev/null || { echo "node$K session $SID gone"; exit 0; }; sleep 1; done
    pkill -KILL -s "$SID" || true; sleep 1
    pgrep -s "$SID" >/dev/null && { echo "node$K session $SID still alive"; exit 1; }
    echo "node$K session $SID killed"; exit 0;;
  *) sed -n 2,7p "$0" >&2; exit 2;;
esac
