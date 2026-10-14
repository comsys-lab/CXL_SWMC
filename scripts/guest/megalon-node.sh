#!/bin/bash
# Start one Megalon kv-store node inside a guest, detached from the SSH session.
# Writes <run_dir>/node<k>.{log,pid,rc,env} and returns immediately.
# Usage: megalon-node.sh <build_dir> <run_dir> <node_id> <run_id 0x..> <region.yaml> <node.yaml> \
#                        <writers: all|node0> <threads> <write_ratio> <preheat_s> <exec_s>
# Node 0 always re-initializes (MEGALON_REINIT=1). Start node 1 only after node 0's log shows READY
# (`megalon-wait.sh ready`, run on node 0's guest). Stop with `megalon-wait.sh stop`, never kill <pid>.
# Everything is bounded by `timeout 900`. Optional env: KV_WATCHDOG_S (kv-store stuck-worker abort).
set -euo pipefail
[ $# -eq 11 ] || { sed -n 2,7p "$0" >&2; exit 2; }
B=$1 RUN=$2 K=$3 RID=$4 REGION=$5 NODECFG=$6 WRITERS=$7 THREADS=$8 WR=$9 PRE=${10} EXEC=${11}
case "$RID" in 0x[0-9a-fA-F]*) ;; *) echo "run_id must be 0x-prefixed hex" >&2; exit 2;; esac
case "$WRITERS" in all|node0) ;; *) echo "writers must be all|node0" >&2; exit 2;; esac
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
kv_writers=$WRITERS
megalon_reinit=$REINIT
kv_watchdog_s=${KV_WATCHDOG_S:-0}
args=zipfian $RUN/node$K/ $THREADS $WR 0.99 0 0 $PRE $EXEC
uname_r=$(uname -r)
region_sha256=$(sha256sum "$REGION" | cut -d' ' -f1)
node_config_sha256=$(sha256sum "$NODECFG" | cut -d' ' -f1)
start=$(date -Is)
EOF
cd "$B"
setsid nohup env RACKOBJ_CONFIG="$NODECFG" CXL_REGION_CONFIG="$REGION" MEGALON_NODE_ID="$K" \
  MEGALON_RUN_ID="$RID" MEGALON_REINIT="$REINIT" KV_WRITERS="$WRITERS" KV_WATCHDOG_S="${KV_WATCHDOG_S:-0}" \
  bash -c 'timeout 900 bin/kv-store zipfian "$0/node$1/" "$2" "$3" 0.99 0 0 "$4" "$5"; echo $? > "$0/node$1.rc"' \
  "$RUN" "$K" "$THREADS" "$WR" "$PRE" "$EXEC" > "$RUN/node$K.log" 2>&1 < /dev/null &
echo $! > "$RUN/node$K.pid"
echo "started node$K pid $(cat "$RUN/node$K.pid")"
