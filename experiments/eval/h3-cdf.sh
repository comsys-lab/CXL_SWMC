#!/bin/bash
# H3 per-page read-fault CDF probe on N VMs (evaluation-pipeline rev 3 §2.3 H3-b; user grant 2026-10-20 "guest
# tracefs/kprobe for the H3 CDF pass": guest root on tracefs, setup and teardown inside the CDF pass only).
# kprobe event + in-kernel hist trigger on swmc_fault_account (Popcorn build 12; exported; kind %di 0 = READ, ctx %dx:
# map_pfn at +8, transition at +48), filter kind==0 && tr==1 (I->S read faults), keys=pfn, 2^17 entries
# (reports/packets/ROCKSDB-V1-packet.md §5.2). Output: one hist file per VM for experiments/rocksdb/h3-page-cdf.py
# (Dropped must be 0 for a complete CDF).
# usage (env NODES = guest ips, node k = position k):
#   h3-cdf.sh setup <dir>         add the kprobe event, filter and hist trigger on every VM; <dir>/cdf-setup.txt
#   h3-cdf.sh clear <dir> <rate>  clear the hist on every VM, then print "<rate> <rate>" (run.sh PART_RATES_CMD hook:
#                                 the vector DB CDF part's @RATES@ = two windows at <rate>); <dir>/cdf-clear.txt
#   h3-cdf.sh dump <dir>          <dir>/hist-vm<k>.txt from every VM
#   h3-cdf.sh teardown <dir>      remove trigger and event on every VM (idempotent); "CDF TEARDOWN PASS" when no VM
#                                 has the swmc/acct event left; <dir>/cdf-teardown.txt
# Every guest command runs as `sudo -n sh -c` (fail closed: a refused sudo is a failure). Exit 0 = success.
set -uo pipefail
CMD=${1:-} D=${2:-}
[ -n "$CMD" ] && [ -d "$D" ] || { sed -n 2,17p "$0"; exit 2; }
read -r -a IPS <<< "${NODES:?NODES (guest ips) required}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
T=/sys/kernel/tracing
EV="p:swmc/acct swmc_fault_account kind=%di:u32 pfn=+8(%dx):u64 tr=+48(%dx):u8"
HIST="hist:keys=pfn:vals=hitcount:size=131072"
on() { $SSH comsys@"${IPS[$1]}" "$2" < /dev/null; }
rc=0
case $CMD in
  setup)
    for k in "${!IPS[@]}"; do
      out=$(on $k "sudo -n sh -c 'grep -q \"^p:swmc/acct \" $T/kprobe_events && { echo EXISTS; exit 1; }
        echo \"$EV\" >> $T/kprobe_events && echo \"kind==0 && tr==1\" > $T/events/swmc/acct/filter &&
        echo \"$HIST\" > $T/events/swmc/acct/trigger && echo setup_ok' && sudo -n cat $T/events/swmc/acct/trigger" 2>&1)
      echo "$(date -Is) vm$k ${IPS[$k]}: $(echo "$out" | tr '\n' ' ')" >> "$D/cdf-setup.txt"
      echo "$out" | grep -qx setup_ok || rc=1
    done
    [ $rc = 0 ] && echo "CDF SETUP PASS" | tee -a "$D/cdf-setup.txt" || echo "CDF SETUP FAIL (see $D/cdf-setup.txt)";;
  clear)
    [[ ${3:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "bad rate" >&2; exit 2; }
    for k in "${!IPS[@]}"; do
      out=$(on $k "sudo -n sh -c 'echo \"$HIST:clear\" >> $T/events/swmc/acct/trigger && echo clear_ok'" 2>&1)
      echo "$(date -Is) vm$k ${IPS[$k]}: $out" >> "$D/cdf-clear.txt"
      [ "$out" = clear_ok ] || rc=1
    done
    [ $rc = 0 ] || { echo "CDF CLEAR FAIL (see $D/cdf-clear.txt)" >&2; exit 1; }
    echo "$3 $3";;
  dump)
    for k in "${!IPS[@]}"; do
      on $k "sudo -n cat $T/events/swmc/acct/hist" > "$D/hist-vm$k.txt" 2>&1 || rc=1
      grep -q 'Dropped:' "$D/hist-vm$k.txt" || rc=1
      echo "$(date -Is) vm$k entries=$(grep -c 'hitcount:' "$D/hist-vm$k.txt") $(grep -m1 'Dropped:' "$D/hist-vm$k.txt")" >> "$D/cdf-dump.txt"
    done
    [ $rc = 0 ] && echo "CDF DUMP PASS" || echo "CDF DUMP FAIL (see $D/cdf-dump.txt)";;
  teardown)
    for k in "${!IPS[@]}"; do
      out=$(on $k "sudo -n sh -c 'if [ -d $T/events/swmc/acct ]; then echo \"!$HIST\" >> $T/events/swmc/acct/trigger 2>/dev/null;
        echo 0 > $T/events/swmc/acct/enable 2>/dev/null; echo \"-:swmc/acct\" >> $T/kprobe_events; fi;
        echo left=\$(grep -c \"^p:swmc/acct \" $T/kprobe_events)'" 2>&1)
      echo "$(date -Is) vm$k ${IPS[$k]}: $(echo "$out" | tr '\n' ' ')" >> "$D/cdf-teardown.txt"
      echo "$out" | grep -qx left=0 || rc=1
    done
    [ $rc = 0 ] && echo "CDF TEARDOWN PASS" | tee -a "$D/cdf-teardown.txt" || echo "CDF TEARDOWN FAIL (see $D/cdf-teardown.txt)" | tee -a "$D/cdf-teardown.txt";;
  *) sed -n 2,17p "$0"; exit 2;;
esac
exit $rc
