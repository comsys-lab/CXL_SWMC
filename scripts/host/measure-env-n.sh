#!/bin/bash
# N-VM checks on top of the unchanged measure-env.sh / measure-env-part.sh (popcorn-n; VM8 topology,
# reports/VM8-topology-packet.v2.md). Read-only, no root: world-readable procfs + read-only virsh.
#   measure-env-n.sh check <base state dir>              = measure-env.sh check <base>  + VM checks; last line
#                                                         "CHECK PASS" (drop-in for host-gate.sh MEASURE_ENV=)
#   measure-env-n.sh check <base state dir> <apply dir>  = measure-env-part.sh check <base> <apply> + VM checks;
#                                                         last line "PART CHECK PASS (...)" (drop-in for
#                                                         h1-gate.sh MEASURE_PART_SCRIPT=)
# The base scripts check only cxl_vm0/cxl_vm1 emulator pins. Added here, for EVERY running cxl_vm0..7:
#   - virsh emulatorpin = 16,48 (even VM index) / 17,49 (odd), the plan of the VM8 packet (unchanged for N=2);
#   - every non-vCPU QEMU thread (main loop, IO, workers, vhost-<pid> workers) has Cpus_allowed_list = that set
#     (kvm-nx-lpage-recovery is a KVM kthread child, not checked);
#   - vCPU thread "CPU j/KVM" pinned per topology: 4 vCPUs (VM8): host core 2i + j/2, thread (j%2)*32;
#     8 vCPUs (N=4 topology, eval-h3): host core 4i + j/2, thread (j%2)*32;
#     16 vCPUs (2-VM topology): host core 2(j/2) + i, thread (j%2)*32;
#   - EXPECT_RUNNING="cxl_vm0 cxl_vm1 ..." (required) must equal the running cxl_vm0..7 set (the H3 N subset).
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
V="virsh -c qemu:///system"
[ "${1:-}" = check ] && [ -n "${2:-}" ] || { echo "usage: EXPECT_RUNNING='cxl_vm0 ...' $0 check <base state dir> [<part apply dir>]"; exit 2; }
[[ "${EXPECT_RUNNING:-}" =~ ^(cxl_vm[0-7]( |$))+$ ]] || { echo "CHECK FAIL: EXPECT_RUNNING (cxl_vm0..7 names) is required"; exit 2; }
B=$2 A=${3:-}
if [ -n "$A" ]; then out=$(bash "$H/measure-env-part.sh" check "$B" "$A" 2>&1); brc=$?; want='^PART CHECK PASS'
else out=$(bash "$H/measure-env.sh" check "$B" 2>&1); brc=$?; want='^CHECK PASS$'; fi
printf '%s\n' "$out" | sed '$d'
last=$(printf '%s\n' "$out" | tail -n 1)
rc=0
if [ $brc != 0 ] || ! grep -qE "$want" <<< "$last"; then printf '%s\n' "$last"; rc=1; else echo "base: $last"; fi
running=$($V list --name 2>/dev/null | grep -E '^cxl_vm[0-7]$' | sort | tr '\n' ' ')
[ -n "$running" ] || { echo "CHECK FAIL: no running cxl_vm0..7"; rc=1; }
exp=$(tr ' ' '\n' <<< "$EXPECT_RUNNING" | grep . | sort | tr '\n' ' ')
[ "$exp" = "$running" ] || { echo "CHECK FAIL: running VMs [$running] != EXPECT_RUNNING [$exp]"; rc=1; }
for vm in $running; do
  i=${vm#cxl_vm}; emu=$([ $((i % 2)) = 0 ] && echo 16,48 || echo 17,49)
  [ "$($V emulatorpin "$vm" | awk '/\*:/{print $2}')" = "$emu" ] || { echo "CHECK FAIL: $vm emulatorpin (want $emu)"; rc=1; }
  pid=$(pgrep -f -- "-name guest=$vm," | head -n 1)
  [ -n "$pid" ] || { echo "CHECK FAIL: $vm QEMU process not found"; rc=1; continue; }
  bad=
  for t in /proc/"$pid"/task/*; do
    c=$(cat "$t/comm" 2>/dev/null) || continue
    a=$(awk '/^Cpus_allowed_list/{print $2}' "$t/status" 2>/dev/null) || continue
    if [[ "$c" =~ ^CPU\ ([0-9]+)/KVM$ ]]; then
      printf '%s %s\n' "${BASH_REMATCH[1]}" "$a"
    elif [[ "$c" != kvm-nx-lpage* ]] && [ "$a" != "$emu" ]; then bad+="$c=$a;"
    fi
  done > "/tmp/measure-env-n.$$.$vm" 2>/dev/null
  [ -z "$bad" ] || { echo "CHECK FAIL: $vm non-vCPU threads off $emu: $bad"; rc=1; }
  nv=$(wc -l < "/tmp/measure-env-n.$$.$vm")
  while read -r j a; do
    case $nv in
      4)  core=$((2 * i + j / 2)) ;;
      8)  core=$((4 * i + j / 2)) ;;   # N=4 topology (workspaces/vmN/vmN-xml.py: vm i -> cores 4i..4i+3 + HT)
      16) core=$((2 * (j / 2) + i)) ;;
      *)  echo "CHECK FAIL: $vm has $nv vCPU threads (4, 8 or 16 expected)"; rc=1; break ;;
    esac
    [ "$a" = "$((core + (j % 2) * 32))" ] || { echo "CHECK FAIL: $vm vCPU $j on $a (want $((core + (j % 2) * 32)))"; rc=1; }
  done < "/tmp/measure-env-n.$$.$vm"
  rm -f "/tmp/measure-env-n.$$.$vm"
  [ $rc = 0 ] && echo "vm-check $vm: emu=$emu vcpus=$nv pinned OK"
done
if [ $rc = 0 ]; then
  if [ -n "$A" ]; then echo "$last vms=[${running% }]"; else echo "CHECK PASS"; fi
fi
exit $rc
