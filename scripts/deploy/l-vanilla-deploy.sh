#!/bin/bash
# Direct-boot deployment of a kernel variant to ONE VM (P3c pattern, generic
# copy of p3c-deploy.sh for VMs that already run devdax /dev/dax0.0).
# Usage: l-vanilla-deploy.sh <phase>
# Phases (run in order; each stops on the first unexpected result):
#   precheck    verify bundle + saved XML (= bundle rollback-inactive.xml), free
#               space, absent targets, devdax baseline, dmesg baseline (no privilege)
#   prepare     guest: stage bundle, sudo prepare-guest.sh; fetch + verify initrd
#   install     Host: sudo install bzImage/initrd into new $D
#   restricted  recheck, graceful shutdown, define restricted XML, start on serial
#               console (init=/bin/sh), acceptance, sysrq power-off
#   normal      define normal XML, start, verify over SSH: release, cmdline,
#               nd state == precheck, dax0.0 size/align, dmesg err set == baseline
#   rollback    stop VM (graceful, destroy after 120 s), define saved XML, verify,
#               start on original definition
# Parameters (env, all required): VM IP B R G D O SRC_TAR
#   B bundle dir (from l-vanilla-bundle.sh), R new evidence dir, G new guest
#   stage dir under /var/tmp, D new Host image dir, O kernel build dir.
set -euo pipefail
umask 077
: "${VM:?}" "${IP:?}" "${B:?}" "${R:?}" "${G:?}" "${D:?}" "${O:?}" "${SRC_TAR:?}"
K=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$B/modules-manifest.json")
BZ_SHA=$(cut -d' ' -f1 "$B/bzImage.sha256")
DAX_SIZE=103060340736
DAX_ALIGN=4096
CONSOLE=$B/vm-console.py
ND='nfit|libnvdimm|nd_pmem|nd_btt|nd_e820|dax_pmem|device_dax|kmem|cxl_shm'
V=(virsh -c qemu:///system)
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
ssh_vm() { ssh -T "${FLAGS[@]}" -p 22 "comsys@$IP" "$@"; }
scp_vm() { scp "${FLAGS[@]}" -P 22 "$@"; }
nd_state() { ssh_vm "set -o pipefail; ndctl list -NRD 2>&1; ls -1 /dev | grep -E '^(dax|pmem)' || true; grep -E '^($ND) ' /proc/modules | cut -d' ' -f1 | sort"; }
dax_check() { ssh_vm "test -c /dev/dax0.0 && test \$(cat /sys/bus/dax/devices/dax0.0/size) = $DAX_SIZE && test \$(cat /sys/bus/dax/devices/dax0.0/align) = $DAX_ALIGN && stat -c '%F %U:%G %a' /dev/dax0.0"; }
# err+ kernel messages without timestamps, sorted unique (set comparison)
dmesg_err() { ssh_vm "dmesg --level=emerg,alert,crit,err" | sed -E 's/^\[ *[0-9.]+\] //' | LC_ALL=C sort -u; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
state() { "${V[@]}" domstate "$VM"; }
wait_off() {  # wait_off SECONDS -> 0 if shut off
  local i; for ((i = 0; i < $1; i += 2)); do
    [ "$(state)" = "shut off" ] && return 0; sleep 2; done
  [ "$(state)" = "shut off" ]
}
xml_is() { "${V[@]}" dumpxml "$VM" --inactive | cmp - "$1"; }
host_recheck() {
  sudo -n sha256sum "$D/bzImage" "$D/initrd.img-$K" | tee "$R/host-images.sha256"
  test "$(sudo -n sha256sum "$D/bzImage" | cut -d' ' -f1)" = "$BZ_SHA"
  test "$(sudo -n sha256sum "$D/initrd.img-$K" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$R/guest-initrd.sha256")"
  sudo -n -u '#64055' test -r "$D/bzImage"
  sudo -n -u '#64055' test -r "$D/initrd.img-$K"
}

case "${1:-}" in
precheck)
  [[ "$G" =~ ^/var/tmp/[A-Za-z0-9._-]+$ ]]
  [[ "$D" =~ ^/var/lib/libvirt/images/[A-Za-z0-9._-]+$ ]]
  grep -q "<kernel>$D/bzImage</kernel>" "$B/candidate-normal.xml"
  cd "$B"
  test "$(sha256sum "$SRC_TAR" | cut -d' ' -f1)" = "$(cut -d' ' -f1 modules.tar.sha256)"
  sha256sum -c preparation.sha256
  sha256sum -c packet.sha256
  printf '%s  %s\n' "$BZ_SHA" "$O/arch/x86/boot/bzImage" | sha256sum -c -
  test "$(cat "$O/include/config/kernel.release")" = "$K"
  test "$(df -Pk /var/lib/libvirt/images | awk 'NR==2 {print $4}')" -ge 2097152
  mkdir -m 0700 "$R"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/before.xml"
  cmp rollback-inactive.xml "$R/before.xml"
  "${V[@]}" dumpxml "$VM" > "$R/before-live.xml"
  [ "$(state)" = "running" ]
  test ! -e "$D" && test ! -L "$D"
  ssh_vm "test ! -e $G && test ! -L $G && test ! -e /lib/modules/$K && test ! -L /lib/modules/$K"
  ssh_vm "python3 -I -c 'import os,stat; assert all(stat.S_ISDIR(os.lstat(p).st_mode) for p in (\"/var\",\"/var/tmp\"))'"
  ssh_vm "uname -r; cat /proc/cmdline" > "$R/kernel-before.txt"
  nd_state > "$R/nd-before.txt"
  grep -q '"dev":"namespace0.0"' "$R/nd-before.txt"; grep -q '"mode":"devdax"' "$R/nd-before.txt"; grep -qx dax0.0 "$R/nd-before.txt"
  if grep -qx cxl_shm "$R/nd-before.txt"; then echo "STOP: cxl_shm loaded on current VM"; exit 1; fi
  dax_check > "$R/dax-before.txt"
  dmesg_err > "$R/dmesg-err-before.txt"
  ssh_vm "test \$(df -Pk /var/tmp | awk 'NR==2 {print \$4}') -ge 6291456 && test \$(df -Pk /lib/modules | awk 'NR==2 {print \$4}') -ge 6291456"
  log "precheck PASS ($VM, current $(head -1 "$R/kernel-before.txt"), target $K)" ;;
prepare)
  grep -q 'precheck PASS' "$R/steps.log"
  ssh_vm "umask 077; mkdir -m 0700 $G"
  scp_vm "$SRC_TAR" "$B/modules-manifest.json" "$B/kernel.config" "$B/prepare-guest.sh" \
    "$B/sanitize-initrd.py" "$B/verify-module-payload.py" "$B/verify-initrd.py" \
    "$B/preparation.sha256" "comsys@$IP:$G/"
  ssh_vm "cd $G && sha256sum -c preparation.sha256 && sudo -n bash ./prepare-guest.sh" 2>&1 | tee "$R/prepare-guest.log"
  scp_vm "comsys@$IP:$G/initrd.img-$K" "$R/"
  scp_vm "comsys@$IP:$G/initrd.sha256" "$R/guest-initrd.sha256"
  scp_vm "comsys@$IP:$G/initrd-members.txt" "$R/"
  python3 -I "$B/verify-initrd.py" "$R/initrd.img-$K" "$B/modules-manifest.json"
  test "$(cut -d' ' -f1 "$R/guest-initrd.sha256")" = "$(sha256sum "$R/initrd.img-$K" | cut -d' ' -f1)"
  log "prepare PASS" ;;
install)
  grep -q 'prepare PASS' "$R/steps.log"
  test ! -e "$D" && test ! -L "$D"
  sudo -n install -d -o root -g 108 -m 0750 "$D"
  sudo -n install -o root -g 108 -m 0640 "$O/arch/x86/boot/bzImage" "$D/bzImage"
  sudo -n install -o root -g 108 -m 0640 "$R/initrd.img-$K" "$D/initrd.img-$K"
  host_recheck
  log "install PASS" ;;
restricted)
  grep -q 'install PASS' "$R/steps.log"
  xml_is "$R/before.xml"; host_recheck
  "${V[@]}" shutdown "$VM"
  wait_off 120 || { log "STOP: initial shutdown timed out (no force, no change)"; exit 1; }
  "${V[@]}" define --validate "$B/candidate-restricted.xml"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/defined-restricted.xml"
  test ! -e "$R/console-restricted.log"
  python3 -I "$CONSOLE" --domain "$VM" --log "$R/console-restricted.log" --start --timeout 180 --wait '^# ?$' \
    --send "printf 'REL=%s\n' \"\$(uname -r)\"" \
    --send "printf 'CMD=%s\n' \"\$(cat /proc/cmdline)\"" \
    --send "printf 'ROOT=%s\n' \"\$(findmnt -rn -o SOURCE,FSTYPE,OPTIONS /)\"" \
    --send "printf 'CXLSHM=%s\n' \"\$(grep -c '^cxl_shm ' /proc/modules)\"" \
    --send "printf 'DESTIJL_%s\n' P3C_ROOT_READY" \
    --expect 'DESTIJL_P3C_ROOT_READY' || { log "FAIL: console acceptance"; exit 1; }
  L=$(tr -d '\r' < "$R/console-restricted.log")
  CMDLINE=$(sed -n 's#.*<cmdline>\(.*\)</cmdline>.*#\1#p' "$B/candidate-restricted.xml")
  grep -qx "REL=$K" <<<"$L"
  grep -qxF "CMD=$CMDLINE" <<<"$L"
  grep -qE '^ROOT=/dev/vda1 ext4 ro(,|$)' <<<"$L"
  grep -qx 'CXLSHM=0' <<<"$L"
  log "restricted acceptance PASS"
  # Never exit the PID 1 shell (panics). Power off via sysrq; root is ro.
  python3 -I "$CONSOLE" --domain "$VM" --log "$R/console-stop.log" --timeout 30 --wait '^# ?$' \
    --send 'sync; echo o > /proc/sysrq-trigger' || true
  if ! wait_off 60; then log "sysrq power-off failed; destroy"; "${V[@]}" destroy "$VM"; fi
  log "restricted PASS (VM shut off)" ;;
normal)
  [ "$(state)" = "shut off" ]
  grep -q 'restricted PASS' "$R/steps.log"; xml_is "$R/defined-restricted.xml"; host_recheck
  "${V[@]}" define --validate "$B/candidate-normal.xml"
  "${V[@]}" start "$VM"
  for i in $(seq 40); do ssh_vm true 2>/dev/null && break; sleep 6; done
  ssh_vm "uname -r; cat /proc/cmdline; findmnt -rn -o SOURCE,FSTYPE,OPTIONS /; \
    echo SYSTEMD=\$(systemctl is-system-running); systemctl --failed --no-legend --plain" \
    | tee "$R/normal-check.txt"
  test "$(sed -n 1p "$R/normal-check.txt")" = "$K"
  test "$(sed -n 2p "$R/normal-check.txt")" = "$(sed -n 's#.*<cmdline>\(.*\)</cmdline>.*#\1#p' "$B/candidate-normal.xml")"
  grep -E '^SYSTEMD=(running|degraded)$' "$R/normal-check.txt"  # degraded allowed; failed units recorded
  for i in $(seq 20); do nd_state > "$R/nd-after.txt"; cmp -s "$R/nd-before.txt" "$R/nd-after.txt" && break; sleep 3; done
  diff "$R/nd-before.txt" "$R/nd-after.txt" || { log "FAIL: nd state changed"; exit 1; }  # namespace, devices, drivers
  if grep -qx cxl_shm "$R/nd-after.txt"; then log "FAIL: cxl_shm loaded"; exit 1; fi
  dax_check > "$R/dax-after.txt"
  diff "$R/dax-before.txt" "$R/dax-after.txt" || { log "FAIL: dax0.0 size/align/owner changed"; exit 1; }
  dmesg_err > "$R/dmesg-err-after.txt"
  ssh_vm "dmesg" > "$R/dmesg-after.txt"
  diff "$R/dmesg-err-before.txt" "$R/dmesg-err-after.txt" || { log "STOP: kernel err-level messages differ from baseline (VM left running $K)"; exit 1; }
  if grep -qE 'BUG:|Oops|Call Trace|WARNING: CPU' "$R/dmesg-after.txt"; then log "STOP: BUG/Oops/WARN in dmesg (VM left running $K)"; exit 1; fi
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-normal.xml"
  log "normal PASS ($VM running $K)" ;;
rollback)
  if [ "$(state)" = "running" ] && xml_is "$R/before.xml"; then
    log "rollback: definition unchanged and VM running; nothing to do"; exit 0; fi
  if [ "$(state)" != "shut off" ]; then
    "${V[@]}" shutdown "$VM" || true
    wait_off 120 || "${V[@]}" destroy "$VM"
  fi
  "${V[@]}" define --validate "$R/before.xml"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-rollback.xml"
  cmp "$R/before.xml" "$R/after-rollback.xml"
  "${V[@]}" start "$VM"
  for i in $(seq 40); do ssh_vm true 2>/dev/null && break; sleep 6; done
  ssh_vm "uname -r" | tee "$R/rollback-uname.txt"
  test "$(cat "$R/rollback-uname.txt")" = "$(head -1 "$R/kernel-before.txt")"
  log "rollback done (original definition restored, started, release $(cat "$R/rollback-uname.txt"))" ;;
*) sed -n '2,19p' "$0"; exit 2 ;;
esac
