#!/bin/bash
# Wait for a Megalon node event inside a guest, bounded.
# Usage: megalon-wait.sh ready <run_dir> <timeout_s>   # node0.log contains "READY published"
#        megalon-wait.sh exit  <run_dir> <node_id> <timeout_s>  # node<k>.rc exists; prints rc
#        megalon-wait.sh stop  <run_dir> <node_id>              # kill the node's whole session (setsid), verify gone
set -euo pipefail
case "${1:-}" in
  ready) RUN=$2 T=$3
    for _ in $(seq "$T"); do
      grep -q "READY published" "$RUN/node0.log" 2>/dev/null && { echo READY; exit 0; }
      # only an .rc written by this attempt counts (newer than this attempt's .pid)
      [ "$RUN/node0.rc" -nt "$RUN/node0.pid" ] && { echo "node0 exited rc=$(cat "$RUN/node0.rc") before READY"; exit 1; }
      sleep 1
    done; echo "no READY within ${T}s"; exit 1;;
  exit) RUN=$2 K=$3 T=$4
    for _ in $(seq "$T"); do
      [ "$RUN/node$K.rc" -nt "$RUN/node$K.pid" ] && { echo "node$K rc=$(cat "$RUN/node$K.rc")"; exit 0; }
      sleep 1
    done; echo "node$K still running after ${T}s"; exit 1;;
  stop) RUN=$2 K=$3; SID=$(cat "$RUN/node$K.pid")
    # the pid is the setsid wrapper (session leader); timeout + kv-store live in their own process
    # group of the same session, so signal the session, not the pid or the group
    pkill -TERM -s "$SID" || true
    for _ in $(seq 10); do pgrep -s "$SID" >/dev/null || { echo "node$K session $SID gone"; exit 0; }; sleep 1; done
    pkill -KILL -s "$SID" || true; sleep 1
    pgrep -s "$SID" >/dev/null && { echo "node$K session $SID still alive"; exit 1; }
    echo "node$K session $SID killed"; exit 0;;
  *) sed -n 2,5p "$0" >&2; exit 2;;
esac
