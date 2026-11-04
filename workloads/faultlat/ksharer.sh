#!/usr/bin/env bash
# faultlat ksharer: write-fault latency and its INV/ACK wait vs the number k of sharers, driven from the Host.
# Prints the commands by default; executes them only with --execute. Running it touches shared CXL memory on the
# nodes: it needs the experiment approval, cxl_shm loaded with nr_nodes=N and coherence enabled on all N guests,
# /dev/dax0.0 owned by comsys (p-popcorn-shm.sh / p-destijl-shm.sh load enable chown).
#
#   ksharer.sh <run-id> <base-page> <k> <mode> [--execute]
#
# One cell = ROUNDS rounds on fresh windows of PAGES pages (window r = base + r * PAGES):
#   1. nodes 1..k read the window at once (read-on-I: every page ends S on those k nodes; nodes k+1..N-1 stay I)
#   2. node 0 writes every page once (write-on-I with k S holders: INV to k holders, wait for their ACKs), with the
#      per-access deltas of the /proc/thread-self/swmc keys KEYS (faultlat access --thread-stat) and GAP_US between
#      two writes (faultlat access --gap-us; the thread-stat reads lie outside the timed interval, inside the gap)
# Steps: k<k>_<mode>_r<r>_read_n<j> (reader j) and k<k>_<mode>_r<r>_write (node 0). <mode> is a name tag (idle, warm);
# the receiver state between two writes is set only by GAP_US. 1 <= k <= N-1.
# Env: NODE_HOSTS ("comsys@ip0 comsys@ip1 ..."; node k = position k; 2..8 entries, required), FL_BIN (faultlat
# binary on the guests, required), RUNSH (run.sh on the guests, required), GOUT (guest output root, default
# /home/comsys/flk-results), CXL_REGION_CONFIG (region config on the guests, required), PAGES (default 2560), ROUNDS
# (default 4), GAP_US (default 0), CPU (default 2), KEYS (default write_faults,write_transactions,write_msg_wait_ns,
# write_fault_ns,sm_faults,sm_fault_ns,nack_retries).
# Every step must exit 0; parallel reader steps wait for all readers and fail if any failed.
set -euo pipefail
run=${1:?run-id}; base=${2:?base-page}; k=${3:?k}; mode=${4:?mode}; exec_=${5:-}
read -r -a NODE <<< "${NODE_HOSTS:?NODE_HOSTS (comsys@ip ...) required}"
N=${#NODE[@]}
[ "$N" -ge 2 ] && [ "$N" -le 8 ] || { echo "NODE_HOSTS must list 2..8 nodes"; exit 2; }
[[ $k =~ ^[1-7]$ ]] && [ "$k" -le $((N - 1)) ] || { echo "k must be 1..N-1 ($((N - 1)))"; exit 2; }
[[ $mode =~ ^[a-z][a-z0-9]*$ ]] || { echo "mode must be a lower-case name tag"; exit 2; }
[[ $base =~ ^[0-9]+$ ]] || { echo "base-page must be an integer"; exit 2; }
[ -z "$exec_" ] || [ "$exec_" = --execute ] || { echo "5th argument must be --execute"; exit 2; }
: "${FL_BIN:?FL_BIN (guest faultlat binary)}" "${RUNSH:?RUNSH (guest run.sh)}" "${CXL_REGION_CONFIG:?CXL_REGION_CONFIG (guest path)}"
GOUT=${GOUT:-/home/comsys/flk-results}
PAGES=${PAGES:-2560}
ROUNDS=${ROUNDS:-4}
GAP_US=${GAP_US:-0}
CPU=${CPU:-2}
KEYS=${KEYS:-write_faults,write_transactions,write_msg_wait_ns,write_fault_ns,sm_faults,sm_fault_ns,nack_retries}
for v in PAGES ROUNDS GAP_US CPU; do [[ ${!v} =~ ^[0-9]+$ ]] || { echo "$v must be an integer"; exit 2; }; done
[ "$PAGES" -ge 1 ] && [ "$ROUNDS" -ge 1 ] || { echo "PAGES and ROUNDS must be >= 1"; exit 2; }
[[ $KEYS =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]] || { echo "KEYS must be comma-separated names"; exit 2; }
out=$GOUT/$run
# same ssh options as scripts/deploy/p-popcorn-shm.sh (known_hosts entries for every node are a precondition)
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
cmd() { echo "FAULTLAT_BIN=$FL_BIN CXL_REGION_CONFIG=$CXL_REGION_CONFIG $RUNSH $out $* --cpu $CPU"; }
win() { echo $((base + $1 * PAGES)); }
for ((r = 0; r < ROUNDS; r++)); do
  w=$(win $r)
  # 1. readers 1..k at once
  if [ "$exec_" = --execute ]; then
    echo "[$(date +%T)] k=$k $mode round $r: readers 1..$k on window $w (+$PAGES)"
    pids=(); rc=0
    for ((j = 1; j <= k; j++)); do
      ssh -T "${FLAGS[@]}" "${NODE[$j]}" "$(cmd "k${k}_${mode}_r${r}_read_n$j" access --op read --pages "$PAGES" --page-offset "$w")" < /dev/null & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    [ $rc = 0 ] || { echo "ksharer $run: k=$k $mode round $r: a reader step FAILED"; exit 1; }
    echo "[$(date +%T)] k=$k $mode round $r: writer node 0 (gap ${GAP_US} us, thread-stat $KEYS)"
    ssh -T "${FLAGS[@]}" "${NODE[0]}" "$(cmd "k${k}_${mode}_r${r}_write" access --op write --pages "$PAGES" --page-offset "$w" --thread-stat "$KEYS" --gap-us "$GAP_US")" < /dev/null \
      || { echo "ksharer $run: k=$k $mode round $r: writer step FAILED"; exit 1; }
  else
    for ((j = 1; j <= k; j++)); do echo "ssh ${NODE[$j]} '$(cmd "k${k}_${mode}_r${r}_read_n$j" access --op read --pages "$PAGES" --page-offset "$w")' &"; done
    echo "wait"
    echo "ssh ${NODE[0]} '$(cmd "k${k}_${mode}_r${r}_write" access --op write --pages "$PAGES" --page-offset "$w" --thread-stat "$KEYS" --gap-us "$GAP_US")'"
  fi
done
[ "$exec_" != --execute ] || echo "ksharer $run k=$k $mode: PASS (N=$N, $ROUNDS rounds x $PAGES pages, all steps exited 0)"
echo "next free base page: $(win "$ROUNDS")"
