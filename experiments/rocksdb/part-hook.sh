#!/bin/bash
# Part hook of the RocksDB receiver-ablation lifetimes (run 2; pilot-run.sh KIND=parts -> run.sh PART_PRE_CMD /
# PART_POST_CMD, servers up). usage: part-hook.sh pre|post <sys> <part> <part dir>
#   pre   experiments/eval/fixed-part-hook.sh pre <sys> <part> (base checked on every VM, the part's receiver parameters
#         written, every base key read back against base + the part's values), then the receiver snapshot "pre"
#   post  the receiver snapshot "post", then fixed-part-hook.sh post <sys> <part> (base restored and checked)
# Receiver snapshot (one line per VM appended to <part dir>/recv-snap.txt: "<pre|post> <ip> <recv-readback.sh line>
# t_ns=.. c.<file>[.<name>]=.."): recv-readback.sh (parameters, cxl_recv* / cxl_ipoll/* schedstat run ns) + recv-snap.sh
# (/sys/kernel/cxl_shm/instr), read-only. A snapshot failure is a NOTE line (the part's data has a gap), not a failure;
# a fixed-part-hook.sh failure is (rc 1: run.sh stops the parts).
# env: FIXED_SPEC FIXED_RECVP FIXED_RECVP_BASE NODES RECV_MODE (fixed-part-hook.sh); FIXED_HOOK_DRY=1 prints the plan only.
set -uo pipefail
PH=${1:?pre|post} SYS=${2:?sys} PART=${3:?part} PD=${4:?part dir}
X=$(cd "$(dirname "$0")" && pwd); EV=$X/../eval
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
: "${NODES:?}"
snap() {
  local ip out
  if [ "${FIXED_HOOK_DRY:-0}" = 1 ]; then echo "DRY snapshot $1 $SYS/$PART: cat recv-readback.sh recv-snap.sh | ssh <vm> bash -s >> $PD/recv-snap.txt"; return 0; fi
  for ip in $NODES; do
    out=$(cat "$EV/recv-readback.sh" "$X/recv-snap.sh" | $SSH comsys@$ip "bash -s" 2>/dev/null | tr '\n' ' ')
    if [[ $out == *"t_ns="* ]]; then echo "$1 $ip $out" >> "$PD/recv-snap.txt"
    else echo "$(date -Is) NOTE: receiver snapshot $1 $SYS/$PART $ip failed ([$out])"; fi
  done
}
case $PH in
  pre) bash "$EV/fixed-part-hook.sh" pre "$SYS" "$PART" || exit 1; snap pre;;
  post) snap post; bash "$EV/fixed-part-hook.sh" post "$SYS" "$PART" || exit 1;;
  *) echo "HOOK FAIL: phase $PH"; exit 2;;
esac
exit 0
