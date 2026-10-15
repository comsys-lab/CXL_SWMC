#!/bin/bash
# Start one Megalon object-test node inside a guest, detached from the SSH session (objects, paper §4).
# Writes <run_dir>/node<k>.{log,pid,rc,env} and returns immediately.
# Usage: object-node.sh <build_dir> <run_dir> <node_id> <run_id 0x..> <region.yaml> <node.yaml> <object-test args...>
# Node 0 always re-initializes (MEGALON_REINIT=1). Start node 1 only after node 0's log shows READY
# (`megalon-wait.sh ready`, run on node 0's guest). Stop with `megalon-wait.sh stop`, never kill <pid>.
# Everything is bounded by `timeout 900`. PASS = rc 0 and an "OBJECT-TEST PASS" line in node<k>.log.
set -euo pipefail
[ $# -ge 7 ] || { sed -n 2,6p "$0" >&2; exit 2; }
B=$1 RUN=$2 K=$3 RID=$4 REGION=$5 NODECFG=$6; shift 6
case "$RID" in 0x[0-9a-fA-F]*) ;; *) echo "run_id must be 0x-prefixed hex" >&2; exit 2;; esac
for f in "$RUN/node$K".{log,pid,rc,env} "$RUN/node$K"; do
  # a reused run dir would let waiters read a previous attempt's .rc (G-B attempts 2-3); never reuse
  [ -e "$f" ] && { echo "refusing: $f exists (use a fresh run dir)" >&2; exit 2; }
done
mkdir -p "$RUN/node$K"
REINIT=0; [ "$K" = 0 ] && REINIT=1
cat > "$RUN/node$K.env" <<EOF
build_dir=$B
node_id=$K
run_id=$RID
region_config=$REGION
node_config=$NODECFG
megalon_reinit=$REINIT
args=$*
uname_r=$(uname -r)
region_sha256=$(sha256sum "$REGION" | cut -d' ' -f1)
node_config_sha256=$(sha256sum "$NODECFG" | cut -d' ' -f1)
start=$(date -Is)
EOF
cd "$B"
setsid nohup env RACKOBJ_CONFIG="$NODECFG" CXL_REGION_CONFIG="$REGION" MEGALON_NODE_ID="$K" \
  MEGALON_RUN_ID="$RID" MEGALON_REINIT="$REINIT" \
  bash -c 'R=$0 N=$1; shift; timeout 900 bin/object-test "$@"; echo $? > "$R/node$N.rc"' \
  "$RUN" "$K" "$@" > "$RUN/node$K.log" 2>&1 < /dev/null &
echo $! > "$RUN/node$K.pid"
echo "started node$K pid $(cat "$RUN/node$K.pid")"
