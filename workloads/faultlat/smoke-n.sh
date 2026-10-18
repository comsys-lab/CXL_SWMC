#!/usr/bin/env bash
# faultlat smoke for N = 2..8 nodes (broadcast MSI correctness check), driven from the Host.
# N-node generalisation of smoke.sh (which stays the 2-node smoke of earlier packets).
# Prints the commands by default; executes them only with --execute (stops at the first failing step; a
# parallel step waits for all of its nodes before it fails). Running it touches shared CXL memory on every
# node: it needs the shared-memory grant (state/TASKS.md), cxl_shm loaded with nr_nodes=N and coherence
# enabled on all N guests.
#
#   smoke-n.sh <run-id> <base-page> [--execute]
#
# Env: NODE_HOSTS ("comsys@ip0 comsys@ip1 ..."; node k = position k; required, 2..8 entries),
# GDIR (plugin dir on the guests), GOUT (guest output root), PAGES (pages per window, default 1024; must be a
# multiple of N), CPU (default 2), ITERS (token ring, default 10000), CXL_REGION_CONFIG (path on the guests).
# Windows used (relative to swcc start, in pages): base + k*PAGES, k = 0..3 (k = 4 is printed as the next free).
# Every step must exit 0; access steps with --expect exit 2 on a data mismatch, the token ring exits 2 on a
# sequence error (lost/stale update).
#   n1  node N-1 writes A (I->M); nodes 0..N-2 read and check A at once (read-on-I by N-1 nodes; M->S)
#   n2  node 0 writes B over pages all others hold S (one write invalidates N-1 sharers); nodes 1..N-1 read B at once
#   n3  every node writes its own slice of a window at once (pattern per node); then node k checks slice k+1 mod N
#   n4  all N nodes write the same pages at once, shuffled (N-way write-write conflicts: NACK/abort/retry);
#       then node 0 writes E and nodes 1..N-1 check E at once
#   n5  token ring on one page over all N nodes (faultlat pingpong --nodes N): every turn checks that all
#       earlier increments are visible
set -euo pipefail
run=$1; base=$2; exec_=${3:-}
read -r -a NODE <<< "${NODE_HOSTS:?NODE_HOSTS (comsys@ip ...) required}"
N=${#NODE[@]}
[ "$N" -ge 2 ] && [ "$N" -le 8 ] || { echo "NODE_HOSTS must list 2..8 nodes"; exit 2; }
GDIR=${GDIR:-/home/comsys/faultlat}
GOUT=${GOUT:-/home/comsys/faultlat-results}
PAGES=${PAGES:-1024}
CPU=${CPU:-2}
ITERS=${ITERS:-10000}
CFG=${CXL_REGION_CONFIG:-/home/comsys/cxl_region.yaml}
[ $((PAGES % N)) = 0 ] || { echo "PAGES ($PAGES) must be a multiple of N ($N)"; exit 2; }
out=$GOUT/$run
# same ssh options as scripts/deploy/p-popcorn-shm.sh (known_hosts entries for every node are a precondition)
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)

cmd() { echo "CXL_REGION_CONFIG=$CFG $GDIR/run.sh $out $*"; }
step() {  # step <k> <name> <faultlat args...>
  local k=$1; shift
  if [ "$exec_" = --execute ]; then
    echo "[$(date +%T)] node$k ${NODE[$k]} $1"
    ssh -T "${FLAGS[@]}" "${NODE[$k]}" "$(cmd "$@" --cpu "$CPU")" < /dev/null
  else
    echo "ssh ${NODE[$k]} '$(cmd "$@" --cpu "$CPU")'"
  fi
}
# par <spec-fn> <k...>: run "$(spec-fn k)" on every listed node at once; all must succeed (all are waited for)
par() {
  local fn=$1 k p rc=0; shift
  local pids=()
  if [ "$exec_" = --execute ]; then
    echo "[$(date +%T)] parallel $fn on nodes $*"
    for k in "$@"; do
      # shellcheck disable=SC2046
      ssh -T "${FLAGS[@]}" "${NODE[$k]}" "$(cmd $($fn "$k") --cpu "$CPU")" < /dev/null & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    return $rc
  else
    for k in "$@"; do echo "ssh ${NODE[$k]} '$(cmd $($fn "$k") --cpu "$CPU")' &"; done
    echo "wait"
  fi
}
win() { echo $((base + $1 * PAGES)); }
others() { local k; for ((k = 0; k < N; k++)); do [ "$k" = "$1" ] || printf '%d ' "$k"; done; }
everyone() { local k; for ((k = 0; k < N; k++)); do printf '%d ' "$k"; done; }
A=0x1111000000000000 B=0x2222000000000000 E=0x5555000000000000
pat() { printf '0x3%x00000000000000' "$1"; }   # n3 pattern of node k (k < 16)
h=$((PAGES / N))

# n1
step $((N - 1)) n1_w$((N - 1)) access --op write --pages "$PAGES" --page-offset "$(win 0)" --pattern $A
n1r() { echo "n1_r$1 access --op read --pages $PAGES --page-offset $(win 0) --expect $A"; }
# shellcheck disable=SC2046
par n1r $(others $((N - 1)))
# n2
step 0 n2_w0 access --op write --pages "$PAGES" --page-offset "$(win 0)" --pattern $B
n2r() { echo "n2_r$1 access --op read --pages $PAGES --page-offset $(win 0) --expect $B"; }
# shellcheck disable=SC2046
par n2r $(others 0)
# n3
n3w() { echo "n3_w$1 access --op write --pages $h --page-offset $(( $(win 1) + $1 * h )) --pattern $(pat "$1")"; }
n3r() { local j=$(( ($1 + 1) % N )); echo "n3_r$1 access --op read --pages $h --page-offset $(( $(win 1) + j * h )) --expect $(pat $j)"; }
# shellcheck disable=SC2046
par n3w $(everyone)
# shellcheck disable=SC2046
par n3r $(everyone)
# n4
n4w() { echo "n4_w$1 access --op write --pages $PAGES --page-offset $(win 2) --shuffle --nonce $(( $1 + 1 ))"; }
# shellcheck disable=SC2046
par n4w $(everyone)
step 0 n4_wE access --op write --pages "$PAGES" --page-offset "$(win 2)" --pattern $E
n4r() { echo "n4_rE$1 access --op read --pages $PAGES --page-offset $(win 2) --expect $E"; }
# shellcheck disable=SC2046
par n4r $(others 0)
# n5
nonce=$(( $(date +%s) * 1000 + RANDOM % 1000 ))
n5() { echo "n5_pp$1 pingpong --role $1 --nodes $N --nonce $nonce --iters $ITERS --page-offset $(win 3)"; }
# shellcheck disable=SC2046
par n5 $(everyone)
if [ "$exec_" = --execute ]; then echo "smoke $run: PASS (N=$N, all steps exited 0)"; fi
echo "next free base page: $(win 4)"
