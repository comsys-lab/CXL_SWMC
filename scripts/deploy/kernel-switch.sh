#!/bin/bash
# Switch ONE VM to a kernel variant that is ALREADY installed and was verified
# by an earlier deployment packet (P3c pattern minus prepare/install/restricted:
# nothing new is written to the guest or to /var/lib/libvirt/images).
# Usage: kernel-switch.sh <phase>
# Phases (run in order; each stops on the first unexpected result):
#   precheck  running PRE_K; current inactive XML saved (before.xml) and
#             == ROLLBACK_XML; target XML differs from it only in the os
#             <kernel>/<initrd>/<cmdline> lines and points into $D; Host images
#             in $D == the recorded HOSTREC hashes and qemu-readable (sudo -n,
#             read-only); guest /lib/modules/$K: every *.ko == MANIFEST; nd/dax
#             baseline; no cxl_shm, no workload process, no FamFS
#   switch    graceful shutdown (no force), define TARGET_XML, start, verify
#             over SSH: release, cmdline, systemd, nd state and dax0.0 equal to
#             precheck, no cxl_shm, no BUG/Oops/WARN, err-level dmesg set ==
#             EXPECT_ERR (if given)
#   rollback  stop (graceful, destroy after 120 s), define before.xml, verify,
#             start, release == precheck release
# Env (required): VM IP R PRE_K K TARGET_XML ROLLBACK_XML D HOSTREC MANIFEST;
# optional EXPECT_ERR (file: sorted unique err-level dmesg lines, no timestamps).
#   HOSTREC   sha256sum lines of $D/bzImage and $D/initrd.img-$K from the packet
#             that installed them (e.g. recovery/L-vanilla-deploy-v1/cxl_vm0/host-images.sha256)
#   MANIFEST  modules-manifest.json of that bundle (release == K)
set -euo pipefail
umask 077
: "${VM:?}" "${IP:?}" "${R:?}" "${PRE_K:?}" "${K:?}" "${TARGET_XML:?}" "${ROLLBACK_XML:?}" "${D:?}" "${HOSTREC:?}" "${MANIFEST:?}"
[[ "$D" =~ ^/var/lib/libvirt/images/[A-Za-z0-9._-]+$ ]] || { echo "bad D"; exit 2; }
ND='nfit|libnvdimm|nd_pmem|nd_btt|nd_e820|dax_pmem|device_dax|kmem|cxl_shm'
V=(virsh -c qemu:///system)
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
ssh_vm() { ssh -T "${FLAGS[@]}" -p 22 "comsys@$IP" "$@"; }
nd_state() { ssh_vm "set -o pipefail; ndctl list -NRD 2>&1; ls -1 /dev | grep -E '^(dax|pmem)' || true; grep -E '^($ND) ' /proc/modules | cut -d' ' -f1 | sort"; }
dax_check() { ssh_vm "test -c /dev/dax0.0 && cat /sys/bus/dax/devices/dax0.0/size /sys/bus/dax/devices/dax0.0/align && stat -c '%F %U:%G %a' /dev/dax0.0"; }
dmesg_err() { ssh_vm "dmesg --level=emerg,alert,crit,err" | sed -E 's/^\[ *[0-9.]+\] //' | LC_ALL=C sort -u; }
log() { printf '[%s] %s %s\n' "$(date +%T)" "$VM" "$*" | tee -a "$R/steps.log"; }
state() { "${V[@]}" domstate "$VM"; }
wait_off() {
  local i; for ((i = 0; i < $1; i += 2)); do
    [ "$(state)" = "shut off" ] && return 0; sleep 2; done
  [ "$(state)" = "shut off" ]
}
xml_is() { "${V[@]}" dumpxml "$VM" --inactive | cmp - "$1"; }
# workload processes that must not run during a switch (bracket trick: no self-match by the remote shell)
PROCS='[v]db-server|[f]aultlat|[k]v-store|[k]v-server|[o]bject-test|[m]egalon|[r]ecsys|[l]mdb'
wait_ssh() { local i; for i in $(seq 40); do ssh_vm true 2>/dev/null && return 0; sleep 6; done; return 1; }
# back to before.xml (VM shut off), start, check release+cmdline; used by rollback and failed switches
restore() {
  "${V[@]}" define --validate "$R/before.xml"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-rollback.xml"
  cmp "$R/before.xml" "$R/after-rollback.xml"
  "${V[@]}" start "$VM"
  wait_ssh || { log "FAIL: no SSH after the rollback start"; return 1; }
  ssh_vm "uname -r; cat /proc/cmdline" > "$R/kernel-after-rollback.txt"
  cmp "$R/kernel-before.txt" "$R/kernel-after-rollback.txt"
  log "rollback done (original definition restored, $(head -1 "$R/kernel-after-rollback.txt") running)"
}
cmdline_of() { sed -n 's#.*<cmdline>\(.*\)</cmdline>.*#\1#p' "$1"; }
host_check() {  # images in $D == HOSTREC, qemu-readable
  sudo -n sha256sum "$D/bzImage" "$D/initrd.img-$K" > "$R/host-images.sha256"
  cmp "$R/host-images.sha256" "$HOSTREC" || { echo "STOP: Host images differ from $HOSTREC"; return 1; }
  sudo -n -u '#64055' test -r "$D/bzImage" && sudo -n -u '#64055' test -r "$D/initrd.img-$K"
}

case "${1:-}" in
precheck)
  test -d "$(dirname "$R")" && mkdir -m 0700 "$R"
  test "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$MANIFEST")" = "$K"
  grep -q "<kernel>$D/bzImage</kernel>" "$TARGET_XML"
  grep -q "<initrd>$D/initrd.img-$K</initrd>" "$TARGET_XML"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/before.xml"
  "${V[@]}" dumpxml "$VM" > "$R/before-live.xml"
  cmp "$ROLLBACK_XML" "$R/before.xml" || { echo "STOP: current inactive XML != ROLLBACK_XML"; exit 1; }
  diff "$R/before.xml" "$TARGET_XML" > "$R/target.diff" || true
  # only os kernel/initrd(/cmdline) lines may differ
  ! grep -E '^[<>]' "$R/target.diff" | grep -vE '^[<>] +<(kernel|initrd|cmdline)>.*</(kernel|initrd|cmdline)>$' ||
    { echo "STOP: target XML differs outside kernel/initrd/cmdline"; exit 1; }
  test "$(state)" = running
  ssh_vm "uname -r; cat /proc/cmdline" > "$R/kernel-before.txt"
  grep -qxF "$PRE_K" <(head -1 "$R/kernel-before.txt") || { echo "STOP: VM does not run $PRE_K"; exit 1; }
  host_check
  # guest modules of the target release unchanged since their install (read-only, unprivileged)
  ssh_vm "python3 -I - /lib/modules/$K" > "$R/guest-modules.sha256" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
for ko in sorted(root.rglob('*.ko')):
    print(hashlib.sha256(ko.read_bytes()).hexdigest(), ko.relative_to(root))
PY
  python3 -I - "$R/guest-modules.sha256" "$MANIFEST" <<'PY'
import json, sys
got = dict((l.split()[1], l.split()[0]) for l in open(sys.argv[1]) if l.strip())
want = json.load(open(sys.argv[2]))['modules']
miss = sorted(set(want) - set(got)); extra = sorted(set(got) - set(want))
diff = sorted(k for k in set(want) & set(got) if want[k] != got[k])
print(f'guest modules: {len(got)} found, {len(want)} in manifest, missing {len(miss)}, extra {len(extra)}, differing {len(diff)}')
sys.exit(1 if miss or extra or diff else 0)
PY
  nd_state > "$R/nd-before.txt"
  grep -q '"dev":"namespace0.0"' "$R/nd-before.txt"; grep -qx dax0.0 "$R/nd-before.txt"
  grep -q '"mode":"devdax"' "$R/nd-before.txt"; grep -q '"map":"mem"' "$R/nd-before.txt"
  grep -q '"align":4096' "$R/nd-before.txt"; grep -q '"size":103060340736' "$R/nd-before.txt"
  if grep -qx cxl_shm "$R/nd-before.txt"; then echo "STOP: cxl_shm loaded"; exit 1; fi
  dax_check > "$R/dax-before.txt"
  grep -qx 'character special file root:root 600' "$R/dax-before.txt" || { echo "STOP: dax0.0 not root:root 600"; exit 1; }
  dmesg_err > "$R/dmesg-err-before.txt"
  ssh_vm "findmnt -rn -o SOURCE,TARGET,FSTYPE | grep -i famfs; grep -i famfs /etc/fstab; true" > "$R/famfs-before.txt"
  test ! -s "$R/famfs-before.txt" || { echo "STOP: FamFS configured"; exit 1; }
  ssh_vm "pgrep -a -f '$PROCS' || true" > "$R/procs-before.txt"
  test ! -s "$R/procs-before.txt" || { echo "STOP: workload processes running"; exit 1; }
  log "precheck PASS (running $PRE_K, target $K)" ;;
switch)
  grep -q "$VM precheck PASS" "$R/steps.log"
  xml_is "$R/before.xml"; host_check
  ssh_vm "pgrep -a -f '$PROCS' || true; grep '^cxl_shm ' /proc/modules || true" > "$R/procs-before-shutdown.txt"
  test ! -s "$R/procs-before-shutdown.txt" || { log "STOP: workload processes or cxl_shm present"; exit 1; }
  "${V[@]}" shutdown "$VM"
  if ! wait_off 120; then
    # no force; the shutdown may still complete late: only "running + definition unchanged" means still on PRE_K
    sleep 10
    if [ "$(state)" = "shut off" ]; then
      log "STOP: shutdown completed only after the timeout; restoring the original definition and starting"
      restore; exit 1
    fi
    xml_is "$R/before.xml" && log "STOP: shutdown timed out; VM $(state), definition unchanged (still $PRE_K)" ||
      log "FAIL: shutdown timed out and the definition differs from before.xml"
    exit 1
  fi
  "${V[@]}" define --validate "$TARGET_XML"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-define.xml"
  if ! cmp "$R/after-define.xml" "$TARGET_XML"; then
    diff "$TARGET_XML" "$R/after-define.xml" > "$R/after-define.diff" || true
    log "FAIL: defined XML differs from the target (after-define.diff); not starting it, rolling back"
    restore; exit 1
  fi
  "${V[@]}" start "$VM"
  wait_ssh || { log "FAIL: no SSH after boot (VM $(state)); next: rollback"; exit 1; }
  ssh_vm "uname -r; cat /proc/cmdline; findmnt -rn -o SOURCE,FSTYPE,OPTIONS /; \
    echo SYSTEMD=\$(systemctl is-system-running); systemctl --failed --no-legend --plain" | tee "$R/switch-check.txt"
  test "$(sed -n 1p "$R/switch-check.txt")" = "$K" || { log "FAIL: release"; exit 1; }
  test "$(sed -n 2p "$R/switch-check.txt")" = "$(cmdline_of "$TARGET_XML")" || { log "FAIL: cmdline"; exit 1; }
  grep -qE '^/dev/vda1 ext4 rw' "$R/switch-check.txt" || { log "FAIL: root fs"; exit 1; }
  grep -E '^SYSTEMD=(running|degraded)$' "$R/switch-check.txt" || { log "FAIL: systemd"; exit 1; }
  for i in $(seq 20); do nd_state > "$R/nd-after.txt"; cmp -s "$R/nd-before.txt" "$R/nd-after.txt" && break; sleep 3; done
  diff "$R/nd-before.txt" "$R/nd-after.txt" || { log "FAIL: nd state changed"; exit 1; }
  if grep -qx cxl_shm "$R/nd-after.txt"; then log "FAIL: cxl_shm loaded"; exit 1; fi
  dax_check > "$R/dax-after.txt"
  diff "$R/dax-before.txt" "$R/dax-after.txt" || { log "FAIL: dax0.0 size/align/owner changed"; exit 1; }
  ssh_vm "dmesg" > "$R/dmesg-after.txt"
  dmesg_err > "$R/dmesg-err-after.txt"
  if grep -qE 'BUG:|Oops|Call Trace|WARNING: CPU' "$R/dmesg-after.txt"; then log "STOP: BUG/Oops/WARN in dmesg (VM left running $K)"; exit 1; fi
  if [ -n "${EXPECT_ERR:-}" ]; then
    diff "$EXPECT_ERR" "$R/dmesg-err-after.txt" || { log "STOP: err-level dmesg differs from $EXPECT_ERR (VM left running $K)"; exit 1; }
  fi
  log "switch PASS ($VM running $K)" ;;
rollback)
  if [ "$(state)" = "running" ] && xml_is "$R/before.xml"; then
    log "rollback: definition unchanged and VM running; nothing to do"; exit 0; fi
  if ssh_vm true 2>/dev/null; then
    if ssh_vm "grep -q '^cxl_shm ' /proc/modules"; then log "STOP: cxl_shm loaded; unload it first"; exit 1; fi
  else
    log "VM unreachable over ssh: cxl_shm check skipped, rolling back without it"
  fi
  if [ "$(state)" != "shut off" ]; then
    "${V[@]}" shutdown "$VM" || true
    wait_off 120 || { log "graceful shutdown timed out; destroy"; "${V[@]}" destroy "$VM"; }
  fi
  restore ;;
*) sed -n '2,24p' "$0"; exit 2 ;;
esac
