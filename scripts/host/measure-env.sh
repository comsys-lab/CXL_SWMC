#!/bin/bash
# Host measurement environment (scripts/host/vm_setting/README.md §2.2, §2.3, §3.1): record/apply/restore run as
# root (sudo); check needs no root (it only reads world-readable sysfs/procfs, systemctl show, read-only virsh).
# usage: measure-env.sh record|apply|restore|check <state dir>
#        measure-env.sh reapply <state dir> <new log dir>   (re-apply after VM restarts: same settings as apply, the
#        record in <state dir> is only read; logs go to the new, empty log dir, so recovery files are never rewritten)
#   record  save every setting apply changes (once, into an empty dir; restore reads it back)
#   apply   Host C1E + C6 off on every CPU; irqbalance stopped; IRQs, unbound workqueues and the Host systemd slices
#           (system, user, init) on the housekeeping CPUs HK; each VM's emulator threads (incl. vhost) pinned live
#   restore write back exactly what record saved, then diff the live state against it
#   check   exit 0 only if the applied state is in place (measurement blocks call this before starting)
# CPU plan (node0 = all 32 vCPUs): emulator cxl_vm0 = 16,48; cxl_vm1 = 17,49; HK = 18-31,50-63 (loadgen runs here).
set -uo pipefail
CMD=${1:?record|apply|restore|check} D=${2:?state dir}
EMU_cxl_vm0=16,48 EMU_cxl_vm1=17,49 HK=18-31,50-63
VMS=(cxl_vm0 cxl_vm1) SLICES=(system.slice user.slice init.scope)
V="virsh -c qemu:///system"
[ "$CMD" = check ] || [ "$(id -u)" = 0 ] || { echo "run as root ($CMD)"; exit 2; }
mask() {  # cpu list -> workqueue hex mask (comma-separated 32-bit words, as the kernel prints it)
  python3 -c 'import sys
cpus=set()
for p in sys.argv[1].split(","):
    a,_,b=p.partition("-"); cpus.update(range(int(a), int(b or a)+1))
n=int(sys.argv[2]); v=sum(1<<c for c in cpus)
w=[(v>>(32*i))&0xffffffff for i in range((n+31)//32)]
print(",".join("%08x"%x for x in reversed(w)))' "$1" "$(nproc --all)"
}
cstates() { for f in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/disable; do echo "$f $(cat $f)"; done; }
irqs() { for i in /proc/irq/[0-9]*; do echo "${i#/proc/irq/} $(cat $i/smp_affinity_list 2>/dev/null)"; done; }
state() {
  cstates > "$1/cstates.txt"; irqs > "$1/irqs.txt"
  cat /sys/devices/virtual/workqueue/cpumask > "$1/wq-cpumask.txt"
  for s in "${SLICES[@]}"; do echo "$s $(systemctl show -p AllowedCPUs --value $s)"; done > "$1/slices.txt"
  for vm in "${VMS[@]}"; do echo "$vm $($V emulatorpin $vm | awk '/\*:/{print $2}')"; done > "$1/emulatorpin.txt"
  systemctl is-active irqbalance > "$1/irqbalance.txt" || true
}
case $CMD in
  record)
    mkdir -p "$D"; [ -z "$(ls -A "$D")" ] || { echo "$D not empty"; exit 2; }
    state "$D"; date -Is > "$D/recorded-at.txt"; echo "RECORDED $D";;
  reapply)
    O=${3:?new log dir}; [ -s "$D/cstates.txt" ] || { echo "no record in $D"; exit 2; }
    mkdir -p "$O"; [ -z "$(ls -A "$O")" ] || { echo "$O not empty"; exit 2; }
    T=$(mktemp -d); cp "$D"/*.txt "$T"/; rm -f "$T/apply-irq-errors.txt" "$T/applied-at.txt"
    bash "$0" apply "$T" > "$O/reapply.log" 2>&1; rc=$?
    cp "$T/apply-irq-errors.txt" "$T/applied-at.txt" "$O"/ 2>/dev/null; rm -rf "$T"; cat "$O/reapply.log"
    # the check against the original state dir uses its apply-irq-errors list; IRQs refused now are in $O
    exit $rc;;
  apply)
    [ -s "$D/cstates.txt" ] || { echo "no record in $D (run record first)"; exit 2; }
    for d in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
      case $(cat $d/name) in C1E|C6) echo 1 > $d/disable;; esac
    done
    systemctl stop irqbalance 2>/dev/null || true
    : > "$D/apply-irq-errors.txt"
    for i in /proc/irq/[0-9]*; do
      echo $HK > $i/smp_affinity_list 2>/dev/null || echo "${i#/proc/irq/} $(cat $i/smp_affinity_list 2>/dev/null)" >> "$D/apply-irq-errors.txt"
    done
    mask $HK > /sys/devices/virtual/workqueue/cpumask
    for s in "${SLICES[@]}"; do systemctl set-property --runtime $s AllowedCPUs=$HK; done
    for vm in "${VMS[@]}"; do e=EMU_$vm; $V emulatorpin $vm ${!e} --live > /dev/null; done
    date -Is > "$D/applied-at.txt"
    echo "IRQs that refused the mask (kernel-managed, e.g. NVMe queues; stay where the kernel put them): $(wc -l < "$D/apply-irq-errors.txt"), listed in apply-irq-errors.txt"
    bash "$0" check "$D" && echo "APPLIED" || { echo "APPLY INCOMPLETE (see CHECK FAIL lines)"; exit 1; };;
  restore)
    [ -s "$D/cstates.txt" ] || { echo "no record in $D"; exit 2; }
    while read f v; do echo $v > $f; done < "$D/cstates.txt"
    while read n l; do [ -n "$l" ] && echo $l > /proc/irq/$n/smp_affinity_list 2>/dev/null; done < "$D/irqs.txt"
    cat "$D/wq-cpumask.txt" > /sys/devices/virtual/workqueue/cpumask
    while read -r s c; do
      if [ -z "$c" ]; then systemctl revert --runtime "$s" > /dev/null 2>&1 || systemctl set-property --runtime "$s" AllowedCPUs=
      else systemctl set-property --runtime "$s" "AllowedCPUs=$(echo "$c" | tr ' ' ',')"; fi
    done < "$D/slices.txt"
    while read -r vm c; do $V emulatorpin "$vm" "$c" --live > /dev/null; done < "$D/emulatorpin.txt"
    irqs > "$D/restore-irqs.txt"  # before irqbalance starts moving IRQs again
    diff "$D/irqs.txt" "$D/restore-irqs.txt" > "$D/restore-irq-diff.txt" && echo "IRQ masks restored exactly" \
      || echo "IRQ masks differing right after restore: $(grep -c '^<' "$D/restore-irq-diff.txt") (see restore-irq-diff.txt)"
    [ "$(cat "$D/irqbalance.txt")" = active ] && systemctl start irqbalance
    R=$(mktemp -d); state $R; rc=0
    for f in cstates wq-cpumask slices emulatorpin irqbalance; do diff -q $D/$f.txt $R/$f.txt > /dev/null || { echo "RESTORE DIFF $f"; rc=1; }; done
    rm -rf $R; [ $rc = 0 ] && echo "RESTORED $D"; exit $rc;;
  check)
    rc=0
    for d in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
      case $(cat $d/name) in C1E|C6) [ "$(cat $d/disable)" = 1 ] || { echo "CHECK FAIL: $d enabled"; rc=1; break; };; esac
    done
    [ "$(cat /sys/devices/virtual/workqueue/cpumask)" = "$(mask $HK)" ] || { echo "CHECK FAIL: workqueue cpumask"; rc=1; }
    for s in "${SLICES[@]}"; do [ "$(systemctl show -p AllowedCPUs --value $s | tr " " ",")" = "$HK" ] || { echo "CHECK FAIL: $s AllowedCPUs"; rc=1; }; done
    for vm in "${VMS[@]}"; do e=EMU_$vm; [ "$($V emulatorpin $vm | awk '/\*:/{print $2}')" = "${!e}" ] || { echo "CHECK FAIL: $vm emulatorpin"; rc=1; }; done
    systemctl is-active -q irqbalance && { echo "CHECK FAIL: irqbalance running"; rc=1; }
    if [ ! -f "$D/apply-irq-errors.txt" ]; then echo "CHECK FAIL: no apply record in $D (apply-irq-errors.txt)"; rc=1
    else
      bad=$(irqs | while read -r n l; do [ -z "$l" ] || [ "$l" = "$HK" ] || grep -q "^$n " "$D/apply-irq-errors.txt" || echo $n; done | wc -l)
      [ "$bad" = 0 ] || { echo "CHECK FAIL: $bad IRQs outside $HK (not kernel-managed)"; rc=1; }
    fi
    [ $rc = 0 ] && echo "CHECK PASS"; exit $rc;;
  *) echo "usage: $0 record|apply|restore|check <state dir>"; exit 2;;
esac
