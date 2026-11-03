#!/bin/bash
# Part hook of h2n-block.sh fixed-window lifetimes (H2N_FIXED; run.sh PART_PRE_CMD / PART_POST_CMD, servers up).
# usage: fixed-part-hook.sh pre|post <sys> <part>   |   fixed-part-hook.sh check <sys> <tag>
#   pre   the part's token <sys>/<part>/<detail>/<recv>/...: detail 0|1 -> /sys/kernel/swmc/instr/detail, recv
#         poll|idle|sleep -> /sys/module/cxl_shm/parameters/recv_mode on every VM (- = untouched), read back and checked
#   post  detail back to 0 (if the part set it), recv_mode back to RECV_MODE (if the part set it), checked
#   check (Popcorn and De Stijl: cxl_shm loaded) every VM at detail 0 and recv_mode RECV_MODE
# Receiver-parameter parts (run-2 receiver ablation; env FIXED_RECVP = H2N_FIXED_RECVP, FIXED_RECVP_BASE =
# H2N_FIXED_RECVP_BASE; unset = the behaviour above): a part with a token <sys>/<part>/<k>=<v>[,<k>=<v>...]
#   pre   every VM must be at the base (all FIXED_RECVP_BASE keys) before the write; then the token's keys are written
#         (recv_mode last) and every base key is read back and checked against base overlaid with the token
#   post  the base values of the token's keys are written back (recv_mode last) and every base key is checked
#   check every VM at the base (all keys), in addition to detail 0
# Always prints one line per VM with the values read (run.sh appends it to <run>/part-hooks.txt). Guest sudo: the
# recv_mode write of grant B and the instr/detail write approved for popcorn-writer-lock-split (both sudo -n sh -c);
# receiver-parameter parts: the same sudo -n sh -c 'echo <v> > /sys/module/cxl_shm/parameters/<k>' form.
# env: FIXED_SPEC (= H2N_FIXED), NODES (VM IPs), RECV_MODE; FIXED_HOOK_DRY=1 prints the commands only.
set -uo pipefail
PH=${1:?pre|post|check} SYS=${2:?sys} PART=${3:?part}
: "${FIXED_SPEC:?}" "${NODES:?}" "${RECV_MODE:?}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
RPK='^(recv_mode|ipoll|spin_us|watch_us|s_min_us|s_max_us|idle_spin_us|idle_sleep_us)$'
DET=- RECV=- RP= BASE=${FIXED_RECVP_BASE:-}
if [ "$PH" != check ]; then
  found=0
  for t in $FIXED_SPEC; do
    IFS=/ read -r fs fp fd fr _ <<< "$t"
    [ "$fs/$fp" = "$SYS/$PART" ] && { DET=$fd RECV=$fr found=1; }
  done
  [ $found = 1 ] || { echo "HOOK FAIL: no H2N_FIXED token for $SYS/$PART"; exit 1; }
  for t in ${FIXED_RECVP:-}; do
    IFS=/ read -r fs fp fkv <<< "$t"
    [ "$fs/$fp" = "$SYS/$PART" ] && RP=${fkv//,/ }
  done
fi
[ -z "$RP" ] || [ -n "$BASE" ] || { echo "HOOK FAIL: $SYS/$PART has receiver parameters but FIXED_RECVP_BASE is unset"; exit 1; }
BASE=${BASE//,/ }
bval() { local x; for x in $BASE; do [ "${x%%=*}" = "$1" ] && { echo "${x#*=}"; return 0; }; done; return 1; }
for x in $BASE $RP; do
  [[ ${x%%=*} =~ $RPK ]] && [[ ${x#*=} =~ ^([0-9]+|poll|sleep|adaptive)$ ]] || { echo "HOOK FAIL: bad receiver parameter '$x'"; exit 1; }
done
for x in $RP; do bval "${x%%=*}" > /dev/null || { echo "HOOK FAIL: $SYS/$PART key ${x%%=*} not in FIXED_RECVP_BASE"; exit 1; }; done
[ -z "$BASE" ] || [ "$(bval recv_mode)" = "$RECV_MODE" ] || { echo "HOOK FAIL: FIXED_RECVP_BASE recv_mode != RECV_MODE ($RECV_MODE)"; exit 1; }
case $PH in
  pre) WD=$DET WR=$RECV;;
  post) WD=-; [ "$DET" = - ] || WD=0; WR=-; [ "$RECV" = - ] || WR=$RECV_MODE;;
  check) [[ ${SYS%%@*} =~ ^(pop|ds)$ ]] || { echo "$(date -Is) check $SYS: nothing to check"; exit 0; }; WD=0 WR=$RECV_MODE;;
  *) echo "HOOK FAIL: phase $PH"; exit 2;;
esac
[ -z "$RP" ] || [ "$RECV" = - ] || { echo "HOOK FAIL: $SYS/$PART sets recv_mode in H2N_FIXED and receiver parameters"; exit 1; }
# receiver-parameter writes (pre: the token, post: the base of the token's keys; recv_mode last) and expectations
PW= PWM= EXP=
if [ -n "$BASE" ] && [[ ${SYS%%@*} =~ ^(pop|ds)$ ]]; then
  for x in $BASE; do
    k=${x%%=*} v=${x#*=}
    for y in $RP; do [ "${y%%=*}" = "$k" ] && { [ "$PH" = pre ] && v=${y#*=}; [ "$k" = recv_mode ] && PWM="$k=$v" || PW+="$k=$v "; }; done
    EXP+="$k=$v "
  done
fi
PCAT= ; for x in $BASE; do PCAT+="${x%%=*}=\$(cat /sys/module/cxl_shm/parameters/${x%%=*} 2>/dev/null || echo absent) "; done
if [ -n "$BASE" ] && [ "$PH" = pre ] && [ -n "$RP" ] && [ "${FIXED_HOOK_DRY:-0}" != 1 ]; then  # start state = base, every VM, before any write
  for ip in $NODES; do
    cur=$($SSH comsys@$ip "echo $PCAT" < /dev/null 2>&1)
    for x in $BASE; do [[ " $cur " == *" $x "* ]] || { echo "HOOK FAIL: $ip not at the base before $SYS/$PART ($x; read: $cur)"; exit 1; }; done
  done
fi
rc=0
for ip in $NODES; do
  cmd=
  [ "$PH" = check ] || [ "$WD" = - ] || cmd+="sudo -n sh -c 'echo $WD > /sys/kernel/swmc/instr/detail'; "
  [ "$PH" = check ] || [ "$WR" = - ] || cmd+="sudo -n sh -c 'echo $WR > /sys/module/cxl_shm/parameters/recv_mode'; "
  for x in $PW $PWM; do cmd+="sudo -n sh -c 'echo ${x#*=} > /sys/module/cxl_shm/parameters/${x%%=*}'; "; done
  cmd+="echo detail=\$(cat /sys/kernel/swmc/instr/detail 2>/dev/null || echo absent) ${PCAT}recv_mode=\$(cat /sys/module/cxl_shm/parameters/recv_mode 2>/dev/null || echo absent)"
  if [ "${FIXED_HOOK_DRY:-0}" = 1 ]; then echo "DRY $ip: $cmd${EXP:+ (expect $EXP)}"; continue; fi
  out=$($SSH comsys@$ip "$cmd" < /dev/null 2>&1)
  echo "$(date -Is) $PH $SYS/$PART $ip $out"
  # expected values: the written ones; for '-' detail must be 0 (nothing else may leave it at 1) and recv_mode, when
  # cxl_shm is loaded (pop), RECV_MODE (receiver-parameter parts: the token's recv_mode in pre)
  ed=$WD; [ "$ed" = - ] && ed=0
  er=$WR; [ "$er" = - ] && er=$RECV_MODE
  for x in $EXP; do [ "${x%%=*}" = recv_mode ] && er=${x#*=}; done
  [[ $out == *"detail=$ed "* ]] || { [ "$ed" = 0 ] && [[ $out == *"detail=absent "* ]]; } || { echo "HOOK FAIL: $ip detail != $ed"; rc=1; }
  if [[ ${SYS%%@*} =~ ^(pop|ds)$ ]]; then [[ $out == *"recv_mode=$er" ]] || { echo "HOOK FAIL: $ip recv_mode != $er"; rc=1; }; fi
  for x in $EXP; do [[ " $out " == *" $x "* ]] || { echo "HOOK FAIL: $ip $x not read back"; rc=1; }; done
done
exit $rc
