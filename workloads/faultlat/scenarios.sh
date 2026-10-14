#!/usr/bin/env bash
# faultlat scenarios: the two-node step sequence, driven from the Host.
# Prints the commands by default; executes them only with --execute.
# Running it touches shared CXL memory on both guests: it needs the
# shared-memory grant (state/TASKS.md) and coherence already enabled and
# cxl_shm loaded on both guests (see README.md).
#
#   scenarios.sh <run-id> <base-page> [--execute]
#
# Env: NODE0/NODE1 (ssh targets, default comsys@192.168.122.100/.101),
# GDIR (plugin dir on the guests), GOUT (guest output root), PAGES (pages per
# window, default 4096), CPU (pinned CPU, default 2), ITERS (ping-pong, 10000),
# CXL_REGION_CONFIG (path on the guests).
# <base-page> must point at swcc pages no earlier run touched (page states
# persist across runs; use a new base per run or reboot both guests).
set -euo pipefail
run=$1; base=$2; exec_=${3:-}
NODE0=${NODE0:-comsys@192.168.122.100}
NODE1=${NODE1:-comsys@192.168.122.101}
GDIR=${GDIR:-/home/comsys/faultlat}
GOUT=${GOUT:-/home/comsys/faultlat-results}
PAGES=${PAGES:-4096}
CPU=${CPU:-2}
ITERS=${ITERS:-10000}
CFG=${CXL_REGION_CONFIG:-/home/comsys/cxl_region.yaml}
out=$GOUT/$run

step() {  # step <node> <name> <args...>
  local node=$1 name=$2; shift 2
  local cmd="CXL_REGION_CONFIG=$CFG $GDIR/run.sh $out $name $* --cpu $CPU"
  if [ "$exec_" = --execute ]; then ssh "$node" "$cmd"; else echo "ssh $node '$cmd'"; fi
}
win() { echo $((base + $1 * PAGES)); }

# 1 read-on-I, peer never touched the pages (peer in I: no peer work)
step "$NODE0" s1_read_I_peerI   access --op read  --pages "$PAGES" --page-offset "$(win 0)" --passes 2
# 2 read-on-I, peer holds M (peer write-protects + writes back)
step "$NODE1" s2_prep_peerM     access --op write --pages "$PAGES" --page-offset "$(win 1)"
step "$NODE0" s2_read_I_peerM   access --op read  --pages "$PAGES" --page-offset "$(win 1)"
# 3 write-on-I, peer holds M (peer unmaps + writes back)
step "$NODE1" s3_prep_peerM     access --op write --pages "$PAGES" --page-offset "$(win 2)"
step "$NODE0" s3_write_I_peerM  access --op write --pages "$PAGES" --page-offset "$(win 2)" --passes 2
# 4 write-on-I, peer holds S (peer unmaps)
step "$NODE1" s4_prep_peerS     access --op read  --pages "$PAGES" --page-offset "$(win 3)"
step "$NODE0" s4_write_I_peerS  access --op write --pages "$PAGES" --page-offset "$(win 3)"
# 5 write-on-S, peer holds S: same process reads (I->S) then writes
#   (S->M via the write-protect fault; peer unmaps). Recorded as pass0_write.
step "$NODE1" s5_prep_peerS     access --op read  --pages "$PAGES" --page-offset "$(win 4)"
step "$NODE0" s5_rw_peerS       access --op rw    --pages "$PAGES" --page-offset "$(win 4)"
# 6 write-on-S, peer in I (pass0_write), then read+write again without faults
step "$NODE0" s6_rw_peerI       access --op rw    --pages "$PAGES" --page-offset "$(win 5)" --passes 2
# 7 ping-pong on one page (both nodes at once)
nonce=$(( $(date +%s) * 1000 + RANDOM % 1000 ))
pp=$(win 6)
if [ "$exec_" = --execute ]; then
  step "$NODE1" s7_pingpong_r1 pingpong --role 1 --nonce "$nonce" --iters "$ITERS" --page-offset "$pp" &
  p1=$!
  step "$NODE0" s7_pingpong_r0 pingpong --role 0 --nonce "$nonce" --iters "$ITERS" --page-offset "$pp"
  wait "$p1"
else
  step "$NODE1" s7_pingpong_r1 pingpong --role 1 --nonce "$nonce" --iters "$ITERS" --page-offset "$pp"
  echo "  (role 1 in the background, then:)"
  step "$NODE0" s7_pingpong_r0 pingpong --role 0 --nonce "$nonce" --iters "$ITERS" --page-offset "$pp"
fi
echo "next window base: $(win 7)"
