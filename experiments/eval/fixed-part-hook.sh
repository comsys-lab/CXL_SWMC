#!/bin/bash
# Part hook of h2n-block.sh fixed-window lifetimes (H2N_FIXED; run.sh PART_PRE_CMD / PART_POST_CMD, servers up).
# usage: fixed-part-hook.sh pre|post <sys> <part>   |   fixed-part-hook.sh check <sys> <tag>
#   pre   the part's token <sys>/<part>/<detail>/<recv>/...: detail 0|1 -> /sys/kernel/swmc/instr/detail, recv
#         poll|idle|sleep -> /sys/module/cxl_shm/parameters/recv_mode on every VM (- = untouched), read back and checked
#   post  detail back to 0 (if the part set it), recv_mode back to RECV_MODE (if the part set it), checked
#   check (Popcorn and De Stijl: cxl_shm loaded) every VM at detail 0 and recv_mode RECV_MODE
# Always prints one line per VM with the values read (run.sh appends it to <run>/part-hooks.txt). Guest sudo: the
# recv_mode write of grant B and the instr/detail write approved for popcorn-writer-lock-split (both sudo -n sh -c).
# env: FIXED_SPEC (= H2N_FIXED), NODES (VM IPs), RECV_MODE; FIXED_HOOK_DRY=1 prints the commands only.
set -uo pipefail
PH=${1:?pre|post|check} SYS=${2:?sys} PART=${3:?part}
: "${FIXED_SPEC:?}" "${NODES:?}" "${RECV_MODE:?}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
DET=- RECV=-
if [ "$PH" != check ]; then
  found=0
  for t in $FIXED_SPEC; do
    IFS=/ read -r fs fp fd fr _ <<< "$t"
    [ "$fs/$fp" = "$SYS/$PART" ] && { DET=$fd RECV=$fr found=1; }
  done
  [ $found = 1 ] || { echo "HOOK FAIL: no H2N_FIXED token for $SYS/$PART"; exit 1; }
fi
case $PH in
  pre) WD=$DET WR=$RECV;;
  post) WD=-; [ "$DET" = - ] || WD=0; WR=-; [ "$RECV" = - ] || WR=$RECV_MODE;;
  check) [[ ${SYS%%@*} =~ ^(pop|ds)$ ]] || { echo "$(date -Is) check $SYS: nothing to check"; exit 0; }; WD=0 WR=$RECV_MODE;;
  *) echo "HOOK FAIL: phase $PH"; exit 2;;
esac
rc=0
for ip in $NODES; do
  cmd=
  [ "$PH" = check ] || [ "$WD" = - ] || cmd+="sudo -n sh -c 'echo $WD > /sys/kernel/swmc/instr/detail'; "
  [ "$PH" = check ] || [ "$WR" = - ] || cmd+="sudo -n sh -c 'echo $WR > /sys/module/cxl_shm/parameters/recv_mode'; "
  cmd+="echo detail=\$(cat /sys/kernel/swmc/instr/detail 2>/dev/null || echo absent) recv_mode=\$(cat /sys/module/cxl_shm/parameters/recv_mode 2>/dev/null || echo absent)"
  if [ "${FIXED_HOOK_DRY:-0}" = 1 ]; then echo "DRY $ip: $cmd"; continue; fi
  out=$($SSH comsys@$ip "$cmd" < /dev/null 2>&1)
  echo "$(date -Is) $PH $SYS/$PART $ip $out"
  # expected values: the written ones; for '-' detail must be 0 (nothing else may leave it at 1) and recv_mode, when
  # cxl_shm is loaded (pop), RECV_MODE
  ed=$WD; [ "$ed" = - ] && ed=0
  er=$WR; [ "$er" = - ] && er=$RECV_MODE
  [[ $out == *"detail=$ed "* ]] || { [ "$ed" = 0 ] && [[ $out == *"detail=absent "* ]]; } || { echo "HOOK FAIL: $ip detail != $ed"; rc=1; }
  if [[ ${SYS%%@*} =~ ^(pop|ds)$ ]]; then [[ $out == *"recv_mode=$er" ]] || { echo "HOOK FAIL: $ip recv_mode != $er"; rc=1; }; fi
done
exit $rc
