#!/bin/bash
# P3c devdax restore for the shared NVDIMM (Host /dev/dax1.0, seen by both VMs).
# The namespace metadata (labels/info block) lives in the shared backing, so it
# is written exactly once, from VM0, while VM1 is shut off; VM1 then cold-boots
# and only reads it. Usage: p3c-devdax.sh <phase>
#   precheck  both VMs run $K, raw namespace0.0 of $SIZE, no dax device, no
#             cxl_shm, no pmem/dax/famfs mounts; save XMLs and nd state
#   quiesce   sudo read-only: no process holds /dev/pmem0 on either VM; save
#             label dump (VM0) and verbose nd state
#   vm1-off   graceful shutdown of VM1 (no destroy; timeout = stop)
#   reconfig  VM0 only: create-namespace --force --reconfig devdax; verify VM0
#   vm1-on    start VM1 (unchanged definition); verify it sees the same devdax
#             namespace without writing; one non-destructive region re-probe
#             (disable/enable-region) if dax0.0 is missing
#   verify    final cross-check of both VMs (read-only)
#   vm1-start recovery only: start VM1 if it is shut off (no ndctl change)
# Parameters (env): B K SIZE ALIGN. Never run two phases concurrently.
set -euo pipefail
umask 077
B=${B:-/home/comsys/sungsu/destijl-control/recovery/R6-20261014-v1/P3c-devdax-plan-v1}
K=${K:-6.14.0-famfs-de-stijl+-p3a}
SIZE=${SIZE:-103062437888}
ALIGN=${ALIGN:-4096}
R=$B/run-v1
V=(virsh -c qemu:///system)
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
ip_of() { case $1 in 0) echo 192.168.122.100 ;; 1) echo 192.168.122.101 ;; esac; }
ssh_vm() { local n=$1; shift; ssh -T "${FLAGS[@]}" -p 22 "comsys@$(ip_of "$n")" "$@"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
state() { "${V[@]}" domstate "cxl_vm$1"; }
wait_off() {
  local i; for ((i = 0; i < $1; i += 2)); do
    [ "$(state 1)" = "shut off" ] && return 0; sleep 2; done
  [ "$(state 1)" = "shut off" ]
}
ND='nfit|libnvdimm|nd_pmem|nd_btt|nd_e820|dax_pmem|device_dax|kmem|cxl_shm'
snap() {  # snap VM TAG: unprivileged nd state -> $R/<tag>-vm<n>.{ndctl.json,daxctl.json,txt}
  ssh_vm "$1" "ndctl list -NR" > "$R/$2-vm$1.ndctl.json"
  ssh_vm "$1" "daxctl list 2>/dev/null || true" > "$R/$2-vm$1.daxctl.json"
  ssh_vm "$1" "uname -r; cat /sys/bus/nd/devices/namespace0.0/size; ls -l /dev | grep -E ' (dax|pmem)[0-9.]+\$' || true; \
    grep -E '^($ND) ' /proc/modules | cut -d' ' -f1 | sort; echo MOUNTS; grep -E '^/dev/(pmem|dax)|famfs' /proc/mounts || true" \
    > "$R/$2-vm$1.txt"
}
check() {  # check VM TAG MODE: assert the snapshot matches the expected mode
  python3 -I - "$R/$2-vm$1" "$3" "$K" "$SIZE" "$ALIGN" <<'PY'
import json, sys
base, mode, rel, size, align = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
nd = json.load(open(base + '.ndctl.json'))
txt = open(base + '.txt').read().split('\n')
regs = nd.get('regions', [nd]) if isinstance(nd, dict) else nd
assert len(regs) == 1 and regs[0]['dev'] == 'region0', regs
r = regs[0]
assert r['size'] == size and r['type'] == 'pmem' and r['align'] == 16777216, r
ns = r['namespaces']
assert len(ns) == 1 and ns[0]['dev'] == 'namespace0.0', ns
n = ns[0]
assert txt[0] == rel, txt[0]
assert int(txt[1]) == size, ('namespace size', txt[1])
assert 'cxl_shm' not in txt[:txt.index('MOUNTS')], 'cxl_shm loaded'
assert txt[txt.index('MOUNTS') + 1:] in ([], ['']), 'pmem/dax/famfs mounted'
if mode == 'raw':
    assert n['mode'] == 'raw' and n['size'] == size and n.get('blockdev') == 'pmem0', n
    assert not any(' dax' in l for l in txt), 'dax device present'
else:
    assert n['mode'] == 'devdax' and n.get('map') == 'mem' and n.get('chardev') == 'dax0.0', n
    assert n.get('align') == align, ('align', n.get('align'))
    assert size - 16 * 2**20 <= n['size'] <= size, ('usable size', n['size'])
    assert any(l.startswith('c') and l.endswith(' dax0.0') for l in txt), '/dev/dax0.0 not a char device'
    assert not any(l.endswith(' pmem0') for l in txt), 'pmem0 still present'
    dax = json.load(open(base + '.daxctl.json'))
    dax = dax if isinstance(dax, list) else [dax]
    assert [d['chardev'] for d in dax] == ['dax0.0'], dax
    assert dax[0].get('mode') == 'devdax' and dax[0].get('align') == align, dax[0]
    # label-less namespaces may report no uuid; compare the full identity tuple instead
    print('ident', n.get('uuid'), n['mode'], n['map'], n['align'], n['size'], txt[1])
print(base, mode, 'OK')
PY
}

case "${1:-}" in
precheck)
  mkdir -m 0700 "$R"
  for n in 0 1; do
    [ "$(state $n)" = running ]
    "${V[@]}" dumpxml "cxl_vm$n" --inactive > "$R/vm$n-before.xml"
    snap $n before; check $n before raw
    ssh_vm $n "ndctl --version; daxctl --version; test ! -e /sys/bus/nd/devices/namespace0.0/uuid" > "$R/tools-vm$n.txt"
  done
  log "precheck PASS (both VMs $K, raw namespace0.0)" ;;
quiesce)
  grep -q 'precheck PASS' "$R/steps.log"
  for n in 0 1; do
    sudo_ok=$(ssh_vm $n "sudo -n true && echo yes")
    [ "$sudo_ok" = yes ]
    # fuser exits 1 with no output when no process uses the device
    rc=0; ssh_vm $n "sudo -n fuser -v /dev/pmem0" > "$R/fuser-vm$n.txt" 2>&1 || rc=$?
    [ $rc = 1 ] && [ ! -s "$R/fuser-vm$n.txt" ] || { log "STOP: /dev/pmem0 in use or fuser failed on VM$n (rc=$rc)"; exit 1; }
    ssh_vm $n "ls -A /sys/block/pmem0/holders; grep -c pmem /proc/swaps || true" > "$R/holders-vm$n.txt"
    [ "$(cat "$R/holders-vm$n.txt")" = 0 ] || { log "STOP: pmem0 holder or swap on VM$n"; exit 1; }
    ssh_vm $n "sudo -n ndctl list -vvv" > "$R/before-vm$n.ndctl-vvv.json"
  done
  # Decision point: proceed only in label-less mode (no namespace labels).
  ssh_vm 0 "sudo -n ndctl read-labels -j nmem0" > "$R/labels-before-vm0.json" 2> "$R/labels-before-vm0.err" || true
  if grep -q '"uuid"' "$R/labels-before-vm0.json"; then
    log "STOP: namespace labels present (labelled mode); re-plan"; exit 1; fi
  log "quiesce PASS (no users of /dev/pmem0, label-less)" ;;
vm1-off)
  grep -q 'quiesce PASS' "$R/steps.log"
  "${V[@]}" shutdown cxl_vm1
  wait_off 120 || { log "STOP: VM1 shutdown timed out (no force)"; exit 1; }
  log "vm1-off PASS" ;;
reconfig)
  grep -q 'vm1-off PASS' "$R/steps.log"
  test ! -e "$R/create-namespace-vm0.log"  # run once
  [ "$(state 1)" = "shut off" ]; [ "$(state 0)" = running ]
  # --size omitted: --reconfig keeps the current namespace size ($SIZE, checked)
  ssh_vm 0 "sudo -n ndctl create-namespace --force --reconfig=namespace0.0 --mode=devdax --map=mem --align=$ALIGN" \
    2>&1 | tee "$R/create-namespace-vm0.log"
  for i in $(seq 10); do snap 0 after && check 0 after devdax > "$R/check-after-vm0.txt" 2>&1 && break; sleep 3; done
  cat "$R/check-after-vm0.txt"; grep -q 'OK$' "$R/check-after-vm0.txt"
  log "reconfig PASS (VM0 devdax)" ;;
vm1-on)
  grep -q 'reconfig PASS' "$R/steps.log"
  [ "$(state 1)" = "shut off" ]
  "${V[@]}" dumpxml cxl_vm1 --inactive | cmp - "$R/vm1-before.xml"
  "${V[@]}" start cxl_vm1
  for i in $(seq 40); do ssh_vm 1 true 2>/dev/null && break; sleep 6; done
  ok=0
  for i in $(seq 10); do snap 1 after && check 1 after devdax > "$R/check-after-vm1.txt" 2>&1 && { ok=1; break; }; sleep 3; done
  if [ $ok = 0 ]; then
    # re-probe only if VM1 simply still shows the raw namespace (right kernel, no cxl_shm, no mounts)
    check 1 after raw > "$R/check-raw-vm1.txt" 2>&1 || { cat "$R/check-after-vm1.txt"; log "FAIL: VM1 state unexpected"; exit 1; }
    log "VM1: devdax not visible after boot; one region re-probe"
    ssh_vm 1 "sudo -n ndctl disable-region region0 && sudo -n ndctl enable-region region0" 2>&1 | tee "$R/reprobe-vm1.log"
    snap 1 after; check 1 after devdax > "$R/check-after-vm1.txt" 2>&1 || { cat "$R/check-after-vm1.txt"; log "FAIL: VM1 devdax"; exit 1; }
  fi
  cat "$R/check-after-vm1.txt"
  log "vm1-on PASS (VM1 devdax)" ;;
verify)
  grep -q 'vm1-on PASS' "$R/steps.log"
  for n in 0 1; do snap $n final; check $n final devdax | tee "$R/check-final-vm$n.txt"; done
  u0=$(grep '^ident' "$R/check-final-vm0.txt"); u1=$(grep '^ident' "$R/check-final-vm1.txt")
  [ "$u0" = "$u1" ] || { log "FAIL: VM0/VM1 namespace differ ($u0 / $u1)"; exit 1; }
  for n in 0 1; do "${V[@]}" dumpxml "cxl_vm$n" --inactive | cmp - "$R/vm$n-before.xml"; done
  log "verify PASS (both VMs /dev/dax0.0, $u0, align $ALIGN)" ;;
vm1-start)
  [ "$(state 1)" = "shut off" ] && "${V[@]}" start cxl_vm1
  log "vm1-start done" ;;
*) sed -n '2,19p' "$0"; exit 2 ;;
esac
