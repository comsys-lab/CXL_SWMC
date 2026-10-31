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
# NODES (optional, space-separated ssh targets of nodes 0..N-1 for N > 2:
# runs the N-node scenarios s8-s11 after s1-s7; NODE0/NODE1 default to the
# first two), PPAGES (pages per N-node window, default 256),
# GDIR (plugin dir on the guests), GOUT (guest output root), PAGES (pages per
# window, default 4096), CPU (pinned CPU, default 2), ITERS (ping-pong, 10000),
# CXL_REGION_CONFIG (path on the guests), ASYNC_T_US (De Stijl v2 only: space-separated staleness bounds T in us;
# for each T one async step pair after s7, see a<T>_* below; unset = no async step, every window as before).
# <base-page> must point at swcc pages no earlier run touched (page states
# persist across runs; use a new base per run or reboot both guests).
set -euo pipefail
run=$1; base=$2; exec_=${3:-}
read -r -a NODEV <<< "${NODES:-}"
NODE0=${NODE0:-${NODEV[0]:-comsys@192.168.122.100}}
NODE1=${NODE1:-${NODEV[1]:-comsys@192.168.122.101}}
N=${#NODEV[@]}
PPAGES=${PPAGES:-256}
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
next=7
# async (De Stijl v2, T > 0): the readM pair of s2 with a staleness bound T on node 0's window. Node 1 writes the
# pages (M at node 1), node 0 reads them under a VMA with T: an admitted read fault maps the page at once (SS) and
# the FETCH completes asynchronously (counters ds_async_issued / ds_async_completed / ds_async_fallback_* in the
# step JSON). One fresh window per T.
read -r -a ASYNC_T <<< "${ASYNC_T_US:-}"
for t in ${ASYNC_T[@]+"${ASYNC_T[@]}"}; do
  [[ $t =~ ^[1-9][0-9]*$ ]] || { echo "ASYNC_T_US: bad T '$t' (integer us > 0)"; exit 2; }
  step "$NODE1" "a${t}_prep_peerM"      access --op write --pages "$PAGES" --page-offset "$(win $next)"
  step "$NODE0" "a${t}_read_I_peerM_T"  access --op read  --pages "$PAGES" --page-offset "$(win $next)" --staleness-us "$t"
  next=$((next + 1))
done

# --- N-node scenarios (NODES with N > 2 entries) ---------------------------
if [ "$N" -gt 2 ]; then
  bg() {  # run a step in the background when executing
    if [ "$exec_" = --execute ]; then step "$@" & else step "$@"; echo "  (background)"; fi
  }
  nwin() { echo $((base + next * PAGES + $1 * PPAGES)); }   # next = 7 without ASYNC_T_US (as before)
  # 8 one writer, N-1 readers: node 0 writes; nodes 1..N-1 read in turn.
  #   First reader: read-on-I, writer downgrades M->S (write-back);
  #   later readers: read-on-I with S sharers (FETCH to N-1 peers, no work).
  step "${NODEV[0]}" s8_writer access --op write --pages "$PPAGES" --page-offset "$(nwin 0)"
  for k in $(seq 1 $((N - 1))); do
    step "${NODEV[$k]}" "s8_reader_$k" access --op read --pages "$PPAGES" --page-offset "$(nwin 0)"
  done
  # 9 round-robin writers: node k writes after node k-1 (write-on-I, the
  #   previous writer goes M->I; N-1 INVALIDATEs per fault).
  for k in $(seq 0 $((N - 1))); do
    step "${NODEV[$k]}" "s9_rr_writer_$k" access --op write --pages "$PPAGES" --page-offset "$(nwin 1)"
  done
  # 10 concurrent writers: all N nodes write the same pages at once
  #   (write-write conflicts; priority rule, NACK/abort counters).
  for k in $(seq 1 $((N - 1))); do
    bg "${NODEV[$k]}" "s10_conc_writer_$k" access --op write --pages "$PPAGES" --page-offset "$(nwin 2)"
  done
  step "${NODEV[0]}" s10_conc_writer_0 access --op write --pages "$PPAGES" --page-offset "$(nwin 2)"
  [ "$exec_" = --execute ] && wait
  # 11 token ring over all N nodes on one page (role 0 records one lap).
  nonce=$(( $(date +%s) * 1000 + RANDOM % 1000 ))
  for k in $(seq 1 $((N - 1))); do
    bg "${NODEV[$k]}" "s11_ring_r$k" pingpong --role "$k" --nodes "$N" --nonce "$nonce" --iters "$ITERS" --page-offset "$(nwin 3)"
  done
  step "${NODEV[0]}" s11_ring_r0 pingpong --role 0 --nodes "$N" --nonce "$nonce" --iters "$ITERS" --page-offset "$(nwin 3)"
  [ "$exec_" = --execute ] && wait
  echo "next window base: $(nwin 4)"
else
  echo "next window base: $(win $next)"
fi
