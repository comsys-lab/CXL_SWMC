#!/usr/bin/env bash
# faultlat smoke: two-node MSI correctness check, driven from the Host.
# Prints the commands by default; executes them only with --execute (stops at
# the first failing step). Running it touches shared CXL memory on both
# guests: it needs the shared-memory grant (state/TASKS.md), cxl_shm loaded
# and coherence enabled on both guests (see README.md).
#
#   smoke.sh <run-id> <base-page> [--execute]
#
# Env: NODE0/NODE1 (ssh targets, default comsys@192.168.122.100/.101),
# GDIR (plugin dir on the guests), GOUT (guest output root), PAGES (pages per
# window, default 1024), CPU (default 2), ITERS (ping-pong, default 10000),
# CXL_REGION_CONFIG (path on the guests).
# Windows used (relative to swcc start, in pages): base + k*PAGES, k = 0..4.
# Every step must exit 0; access steps with --expect exit 2 on a data
# mismatch, ping-pong exits 2 on a sequence error (lost/stale update).
set -euo pipefail
run=$1; base=$2; exec_=${3:-}
NODE0=${NODE0:-comsys@192.168.122.100}
NODE1=${NODE1:-comsys@192.168.122.101}
GDIR=${GDIR:-/home/comsys/faultlat}
GOUT=${GOUT:-/home/comsys/faultlat-results}
PAGES=${PAGES:-1024}
CPU=${CPU:-2}
ITERS=${ITERS:-10000}
CFG=${CXL_REGION_CONFIG:-/home/comsys/cxl_region.yaml}
out=$GOUT/$run

cmd() { echo "CXL_REGION_CONFIG=$CFG $GDIR/run.sh $out $*"; }
step() {  # step <node> <name> <faultlat args...>
  local node=$1; shift
  if [ "$exec_" = --execute ]; then
    echo "[$(date +%T)] $node $1"
    ssh -o BatchMode=yes "$node" "$(cmd "$@" --cpu "$CPU")" < /dev/null
  else
    echo "ssh $node '$(cmd "$@" --cpu "$CPU")'"
  fi
}
pair() {  # pair <name0> <args0...> -- <name1> <args1...>: both nodes at once, both must succeed
  local a=() b=() x
  while [ "$1" != -- ]; do a+=("$1"); shift; done; shift; b=("$@")
  if [ "$exec_" = --execute ]; then
    echo "[$(date +%T)] both ${a[0]} ${b[0]}"
    ssh -o BatchMode=yes "$NODE1" "$(cmd "${b[@]}" --cpu "$CPU")" < /dev/null & x=$!
    ssh -o BatchMode=yes "$NODE0" "$(cmd "${a[@]}" --cpu "$CPU")" < /dev/null
    wait "$x"
  else
    echo "ssh $NODE1 '$(cmd "${b[@]}" --cpu "$CPU")' &"
    echo "ssh $NODE0 '$(cmd "${a[@]}" --cpu "$CPU")'; wait"
  fi
}
win() { echo $((base + $1 * PAGES)); }
h=$((PAGES / 2))
A=0x1111000000000000 B=0x2222000000000000 C=0x3333000000000000 D=0x4444000000000000 E=0x5555000000000000

# c1 node1 writes A (I->M); node0 reads and checks A (read-on-I, node1 M->S, write-back)
step "$NODE1" c1_w1 access --op write --pages "$PAGES" --page-offset "$(win 0)" --pattern $A
step "$NODE0" c1_r0 access --op read  --pages "$PAGES" --page-offset "$(win 0)" --expect $A
# c2 node0 writes B over the shared pages (S->M, node1 S->I); node1 reads and checks B (node0 M->S)
step "$NODE0" c2_w0 access --op write --pages "$PAGES" --page-offset "$(win 0)" --pattern $B
step "$NODE1" c2_r1 access --op read  --pages "$PAGES" --page-offset "$(win 0)" --expect $B
# c3 both nodes write disjoint halves at once, then each reads and checks the other's half at once
pair c3_w0 access --op write --pages "$h" --page-offset "$(win 1)" --pattern $C -- \
     c3_w1 access --op write --pages "$h" --page-offset $(( $(win 1) + h )) --pattern $D
pair c3_r0 access --op read --pages "$h" --page-offset $(( $(win 1) + h )) --expect $D -- \
     c3_r1 access --op read --pages "$h" --page-offset "$(win 1)" --expect $C
# c4 both nodes write the same pages at once (write-write conflicts: NACK/abort/retry), shuffled;
#    then node0 writes E and node1 checks E (state consistent after the conflicts)
pair c4_w0 access --op write --pages "$PAGES" --page-offset "$(win 2)" --shuffle --nonce 1 -- \
     c4_w1 access --op write --pages "$PAGES" --page-offset "$(win 2)" --shuffle --nonce 2
step "$NODE0" c4_wE access --op write --pages "$PAGES" --page-offset "$(win 2)" --pattern $E
step "$NODE1" c4_rE access --op read  --pages "$PAGES" --page-offset "$(win 2)" --expect $E
# c5 ping-pong on one page: every turn checks that all earlier increments are visible
nonce=$(( $(date +%s) * 1000 + RANDOM % 1000 ))
pair c5_pp0 pingpong --role 0 --nonce "$nonce" --iters "$ITERS" --page-offset "$(win 3)" -- \
     c5_pp1 pingpong --role 1 --nonce "$nonce" --iters "$ITERS" --page-offset "$(win 3)"
if [ "$exec_" = --execute ]; then echo "smoke $run: PASS (all steps exited 0)"; fi
echo "next free base page: $(win 4)"
