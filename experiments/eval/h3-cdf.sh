#!/bin/bash
# H3 per-page read-fault CDF probe on N VMs (evaluation-pipeline rev 3 §2.3 H3-b; user grant 2026-10-20 "guest
# tracefs/kprobe for the H3 CDF pass": guest root on tracefs, setup and teardown inside the CDF pass only).
# kprobe event + in-kernel hist trigger on swmc_fault_account (Popcorn build 12: built into vmlinux, kernel/swmc/
# popcorn_msi.c, CONFIG_SWMC_POPCORN_MSI=y, System.map "T swmc_fault_account"; so the event can be armed before
# cxl_shm loads. Arguments: kind %di (0 = READ), ctx %dx: struct swmc_fault_ctx map_pfn at +8, transition at +48),
# filter kind==0 && tr==1 (I->S read faults), keys=pfn, 2^17 entries (reports/packets/ROCKSDB-V1-packet.md §5.2).
# Output: one hist file per VM for export_h3.py / experiments/rocksdb/h3-page-cdf.py (Dropped 0 = complete CDF).
# Page sampling (verifier M2; user 2026-10-20: vector DB off, RecSys 16 via H3_RS_CDF_PFN_MOD): H3_CDF_PFN_MOD = M (power of two, 1 = off) keeps
# only pages with pfn % M == 0 (filter term "!(pfn & (M-1))"): the hist then holds ~1/M of the pages, an unbiased
# sample of the per-page distribution; the value is written to <dir>/cdf-setup.txt ("pfn_mod=M").
# usage (env NODES = guest ips, node k = position k):
#   h3-cdf.sh setup <dir>              add the kprobe event, filter and hist trigger on every VM; <dir>/cdf-setup.txt
#   h3-cdf.sh clear <dir>              clear the hist on every VM; <dir>/cdf-clear.txt
#   h3-cdf.sh dump <dir>               <dir>/hist-vm<k>.txt from every VM
#   h3-cdf.sh part-pre <dir> <part>    run.sh PART_PRE_CMD hook: clear when <part> = cdf, else nothing
#   h3-cdf.sh part-post <dir> <part>   run.sh PART_POST_CMD hook: dump when <part> = cdf, else nothing
#   h3-cdf.sh teardown <dir>           remove trigger and event on every VM (idempotent); "CDF TEARDOWN PASS" when no VM
#                                      has the swmc/acct event left; <dir>/cdf-teardown.txt
#   h3-cdf.sh filter                   print the filter of the current H3_CDF_PFN_MOD (no VM contact)
# Every guest command runs as `sudo -n sh -c` (fail closed: a refused sudo is a failure). Exit 0 = success.
set -uo pipefail
CMD=${1:-} D=${2:-}
MOD=${H3_CDF_PFN_MOD:-1}
[[ $MOD =~ ^[1-9][0-9]*$ ]] && [ $((MOD & (MOD - 1))) = 0 ] || { echo "H3_CDF_PFN_MOD must be a power of two (1 = off)" >&2; exit 2; }
FILTER="kind==0 && tr==1"; [ "$MOD" = 1 ] || FILTER="$FILTER && !(pfn & $((MOD - 1)))"
if [ "$CMD" = filter ]; then echo "$FILTER"; exit 0; fi
[ -n "$CMD" ] && [ -d "$D" ] || { sed -n 2,22p "$0"; exit 2; }
read -r -a IPS <<< "${NODES:?NODES (guest ips) required}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
T=/sys/kernel/tracing
EV="p:swmc/acct swmc_fault_account kind=%di:u32 pfn=+8(%dx):u64 tr=+48(%dx):u8"
HIST="hist:keys=pfn:vals=hitcount:size=131072"
on() { $SSH comsys@"${IPS[$1]}" "$2" < /dev/null; }
rc=0
clear_all() {
  local k out
  for k in "${!IPS[@]}"; do
    out=$(on $k "sudo -n sh -c 'echo \"$HIST:clear\" >> $T/events/swmc/acct/trigger && echo clear_ok'" 2>&1)
    echo "$(date -Is) vm$k ${IPS[$k]}: $out" >> "$D/cdf-clear.txt"
    [ "$out" = clear_ok ] || rc=1
  done
  [ $rc = 0 ] && echo "CDF CLEAR PASS $(date -Is)" || echo "CDF CLEAR FAIL (see $D/cdf-clear.txt)"
}
dump_all() {
  local k
  for k in "${!IPS[@]}"; do
    on $k "sudo -n cat $T/events/swmc/acct/hist" > "$D/hist-vm$k.txt" 2>&1 || rc=1
    grep -q 'Dropped:' "$D/hist-vm$k.txt" || rc=1
    echo "$(date -Is) vm$k entries=$(grep -c 'hitcount:' "$D/hist-vm$k.txt") $(grep -m1 'Dropped:' "$D/hist-vm$k.txt")" >> "$D/cdf-dump.txt"
  done
  [ $rc = 0 ] && echo "CDF DUMP PASS $(date -Is)" || echo "CDF DUMP FAIL (see $D/cdf-dump.txt)"
}
case $CMD in
  setup)
    echo "$(date -Is) pfn_mod=$MOD filter=[$FILTER] hist=[$HIST]" >> "$D/cdf-setup.txt"
    for k in "${!IPS[@]}"; do
      out=$(on $k "sudo -n sh -c 'grep -q \"^p:swmc/acct \" $T/kprobe_events && { echo EXISTS; exit 1; }
        echo \"$EV\" >> $T/kprobe_events && echo \"$FILTER\" > $T/events/swmc/acct/filter &&
        echo \"$HIST\" > $T/events/swmc/acct/trigger && echo setup_ok' && sudo -n cat $T/events/swmc/acct/filter $T/events/swmc/acct/trigger" 2>&1)
      echo "$(date -Is) vm$k ${IPS[$k]}: $(echo "$out" | tr '\n' ' ')" >> "$D/cdf-setup.txt"
      echo "$out" | grep -qx setup_ok || rc=1
    done
    [ $rc = 0 ] && echo "CDF SETUP PASS" | tee -a "$D/cdf-setup.txt" || echo "CDF SETUP FAIL (see $D/cdf-setup.txt)";;
  clear) clear_all;;
  dump) dump_all;;
  part-pre) [ "${3:-}" != cdf ] || clear_all;;
  part-post) [ "${3:-}" != cdf ] || dump_all;;
  teardown)
    for k in "${!IPS[@]}"; do
      out=$(on $k "sudo -n sh -c 'if [ -d $T/events/swmc/acct ]; then echo \"!$HIST\" >> $T/events/swmc/acct/trigger 2>/dev/null;
        echo 0 > $T/events/swmc/acct/enable 2>/dev/null; echo \"-:swmc/acct\" >> $T/kprobe_events; fi;
        echo left=\$(grep -c \"^p:swmc/acct \" $T/kprobe_events)'" 2>&1)
      echo "$(date -Is) vm$k ${IPS[$k]}: $(echo "$out" | tr '\n' ' ')" >> "$D/cdf-teardown.txt"
      echo "$out" | grep -qx left=0 || rc=1
    done
    [ $rc = 0 ] && echo "CDF TEARDOWN PASS" | tee -a "$D/cdf-teardown.txt" || echo "CDF TEARDOWN FAIL (see $D/cdf-teardown.txt)" | tee -a "$D/cdf-teardown.txt";;
  *) sed -n 2,22p "$0"; exit 2;;
esac
exit $rc
