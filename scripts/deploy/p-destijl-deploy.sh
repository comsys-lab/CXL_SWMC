#!/bin/bash
# Direct-boot deployment of the De Stijl v2 kernel (builds/destijl/<n>, bundle from p-destijl-package.sh) to ONE VM.
# Copy of p-popcorn-deploy.sh (the build-12 mechanism: same phases, same checks, same Host/guest commands); changed
# only: the kernel identity checks of `normal` (protocol destijl, /sys/kernel/swmc/destijl present, nothing managed),
# the init banner of `restricted`, the guest tools of `tools` (destijl.env, p-destijl-guest.sh, de_stijl_test), and
# `rollback` with ROLLBACK_FORCE=1 (rolls back even if cxl_shm is still loaded: graceful shutdown, destroy after 120 s;
# only after a failed teardown of a bring-up, the shared data is disposable). Usage: p-destijl-deploy.sh <phase>
# Phases (run in order; each stops on the first unexpected result):
#   precheck  verify bundle hashes, bzImage, saved XML == bundle rollback XML,
#             free space, targets, NVDIMM baseline (no privilege). Re-deploy of an installed release: an existing
#             /lib/modules/$K is accepted only if it is exactly the bundle install set (verify-installed-modules.py on a
#             find/sha256sum listing: every module + build/.config by sha256, only depmod outputs extra, root-owned);
#             an existing $G / $GT only if comsys-owned and empty or holding exactly the bundle files; otherwise STOP
#   prepare   guest: stage bundle in $G, sudo prepare-guest.sh (new /lib/modules/$K, or the verified installed one
#             without extraction; depmod; initramfs always rebuilt in $G); fetch + verify the initrd
#   install   Host: sudo install bzImage/initrd into the new dir $D (an existing $D: only if it already holds the
#             identical bzImage and initrd; nothing is overwritten)
#   restricted  graceful shutdown, define restricted XML, start on the serial
#             console (init=/bin/sh), acceptance, sysrq power-off
#   normal    define normal XML (same kernel, no init=), start, verify over
#             SSH; NVDIMM namespace/devices/driver set must equal precheck
#   tools     copy the De Stijl guest tools (faultlat, run.sh, region config,
#             p-destijl-guest.sh, destijl.env, de_stijl_test) to $GT (comsys-owned, no sudo)
#   rollback  stop VM (graceful, destroy after 120 s), define saved XML,
#             verify, start on the original definition
# Env (all required): VM IP C X G D GT K BZ BZ_SHA R PRE_K
#   PRE_K  release the VM must be running at precheck (e.g. 6.14.0-famfs-de-stijl+-ds-popcorn-new-12)
# Optional: ROLLBACK_FORCE=1 (rollback phase only, see above).
#   C  common bundle dir (modules.tar, manifest, prepare scripts, tools/)
#   X  per-VM XML dir (rollback-inactive.xml, candidate-{normal,restricted}.xml)
#   G  guest staging dir (/var/tmp/<new>), D Host images dir (new),
#   GT guest tools dir (/home/comsys/<new>), K release, BZ bzImage path,
#   BZ_SHA its sha256, R evidence dir for this VM (new; parent must exist)
set -euo pipefail
umask 077
: "${VM:?}" "${IP:?}" "${C:?}" "${X:?}" "${G:?}" "${D:?}" "${GT:?}" "${K:?}" "${BZ:?}" "${BZ_SHA:?}" "${R:?}" "${PRE_K:?}"
[[ "$G" =~ ^/var/tmp/[A-Za-z0-9._-]+$ ]] && [[ "$D" =~ ^/var/lib/libvirt/images/[A-Za-z0-9._-]+$ ]] &&
  [[ "$GT" =~ ^/home/comsys/[A-Za-z0-9._-]+$ ]] || { echo "bad G/D/GT"; exit 2; }
CONSOLE=$C/vm-console.py
ND='nfit|libnvdimm|nd_pmem|nd_btt|nd_e820|dax_pmem|device_dax|kmem|cxl_shm'
V=(virsh -c qemu:///system)
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
ssh_vm() { ssh -T "${FLAGS[@]}" -p 22 "comsys@$IP" "$@"; }
scp_vm() { scp "${FLAGS[@]}" -P 22 "$@"; }
nd_state() { ssh_vm "set -o pipefail; ndctl list -NRD 2>&1; ls -1 /dev | grep -E '^(dax|pmem)' || true; grep -E '^($ND) ' /proc/modules | cut -d' ' -f1 | sort"; }
log() { printf '[%s] %s %s\n' "$(date +%T)" "$VM" "$*" | tee -a "$R/steps.log"; }
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
cmdline_of() { sed -n 's#.*<cmdline>\(.*\)</cmdline>.*#\1#p' "$1"; }
# Re-deploy of a release that is already installed on the guest (same bundle content):
PREP=(modules.tar modules-manifest.json kernel.config prepare-guest.sh sanitize-initrd.py verify-module-payload.py
  verify-initrd.py verify-installed-modules.py preparation.sha256)   # = the staging set copied to $G
gkind() { ssh_vm "if test -L $1; then echo link; elif test ! -e $1; then echo absent; elif test -d $1; then echo dir; else echo other; fi"; }
gtree() {  # gtree DIR: guest listing (non-regular entries, then sha256sum of every file, C order)
  ssh_vm "set -o pipefail; cd $1 && find . -mindepth 1 ! -type f -printf 'NONFILE %y %P\n' | LC_ALL=C sort && \
    find . -mindepth 1 -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 -r sha256sum"; }
ltree() { (d=$1; shift; cd "$d" && printf '%s\0' "$@" | LC_ALL=C sort -z | xargs -0 sha256sum); }  # ltree DIR FILE...
reuse_dir() {  # reuse_dir GDIR LABEL LOCALDIR FILE...: absent -> 0; existing comsys-owned dir that is empty or holds
  # exactly FILE... of LOCALDIR (same names, same sha256, nothing else) -> 0 (listing in $R/LABEL-existing.txt); else STOP
  local gd=$1 lb=$2 kind; shift 2; kind=$(gkind "$gd")
  case $kind in
    absent) return 0 ;;
    dir) test "$(ssh_vm "stat -c %U $gd")" = comsys || { log "STOP: $gd exists but is not comsys-owned"; exit 1; }
      gtree "$gd" > "$R/$lb-existing.txt"
      if [ ! -s "$R/$lb-existing.txt" ]; then log "note: $gd exists and is empty (reused)"; return 0; fi
      ltree "$@" > "$R/$lb-expected.txt"
      cmp -s "$R/$lb-expected.txt" "$R/$lb-existing.txt" ||
        { log "STOP: $gd exists and differs from the bundle (see $lb-existing.txt vs $lb-expected.txt)"; exit 1; }
      log "note: $gd exists and is identical to the bundle (reused)" ;;
    *) log "STOP: $gd is a $kind"; exit 1 ;;
  esac; }
check_installed() {  # /lib/modules/$K absent -> 0; present -> must be exactly the bundle install set (else STOP)
  local kind; kind=$(gkind "/lib/modules/$K")
  case $kind in
    absent) return 0 ;;
    dir) ssh_vm "set -o pipefail; cd /lib/modules/$K && find . -mindepth 1 -printf 'T %y %U %m %P\n' && \
        find . -mindepth 1 -type f -printf '%P\0' | xargs -0 -r sha256sum | sed 's/^/H /'" > "$R/installed-modules.txt"
      python3 -I "$C/verify-installed-modules.py" "$C" --listing "$R/installed-modules.txt" | tee "$R/installed-modules-check.txt" ||
        { log "STOP: /lib/modules/$K exists and differs from the bundle (installed-modules-check.txt)"; exit 1; }
      log "note: /lib/modules/$K exists and equals the bundle install set (prepare reuses it)" ;;
    *) log "STOP: /lib/modules/$K is a $kind"; exit 1 ;;
  esac; }

case "${1:-}" in
precheck)
  (cd "$C" && sha256sum --quiet -c packet.sha256 && sha256sum --quiet -c preparation.sha256)
  (cd "$C/tools" && sha256sum --quiet -c tools.sha256)
  (cd "$X" && sha256sum --quiet -c xml.sha256)
  python3 -I "$C/verify-module-payload.py"
  test "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$C/modules-manifest.json")" = "$K"
  printf '%s  %s\n' "$BZ_SHA" "$BZ" | sha256sum -c -
  grep -q "<kernel>$D/bzImage</kernel>" "$X/candidate-normal.xml"
  grep -q "<initrd>$D/initrd.img-$K</initrd>" "$X/candidate-normal.xml"
  test "$(df -Pk /var/lib/libvirt/images | awk 'NR==2 {print $4}')" -ge 2097152
  test -d "$(dirname "$R")" && mkdir -m 0700 "$R"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/before.xml"
  cmp "$X/rollback-inactive.xml" "$R/before.xml"
  "${V[@]}" dumpxml "$VM" > "$R/before-live.xml"
  test "$(state)" = running
  test ! -L "$D" && { test ! -e "$D" || test -d "$D"; }   # an existing $D: install accepts it only with identical images
  [ ! -e "$D" ] || log "note: $D exists (install checks bzImage + initrd are identical, else STOP)"
  reuse_dir "$G" staging "$C" "${PREP[@]}"
  reuse_dir "$GT" tools "$C/tools" $(cd "$C/tools" && ls -A)
  check_installed
  ssh_vm "python3 -I -c 'import os,stat; assert all(stat.S_ISDIR(os.lstat(p).st_mode) for p in (\"/var\",\"/var/tmp\",\"/home/comsys\"))'"
  ssh_vm "uname -r; cat /proc/cmdline" > "$R/kernel-before.txt"
  grep -qxF "$PRE_K" <(head -1 "$R/kernel-before.txt") || { echo "STOP: VM does not run $PRE_K"; exit 1; }
  nd_state > "$R/nd-before.txt"
  grep -q '"dev":"namespace0.0"' "$R/nd-before.txt"; grep -qx dax0.0 "$R/nd-before.txt"
  grep -q '"mode":"devdax"' "$R/nd-before.txt"; grep -q '"map":"mem"' "$R/nd-before.txt"
  grep -q '"align":4096' "$R/nd-before.txt"; grep -q '"size":103060340736' "$R/nd-before.txt"
  if grep -qx cxl_shm "$R/nd-before.txt"; then echo "STOP: cxl_shm loaded on current VM"; exit 1; fi
  ssh_vm "test \$(df -Pk /var/tmp | awk 'NR==2 {print \$4}') -ge 6291456 && test \$(df -Pk /lib/modules | awk 'NR==2 {print \$4}') -ge 6291456"
  # Popcorn refuses fs-DAX holders (fs_dax_get): no FamFS mount, fstab entry or unit may be configured
  ssh_vm "findmnt -rn -o SOURCE,TARGET,FSTYPE | grep -i famfs; grep -i famfs /etc/fstab; \
    systemctl list-unit-files --no-legend 2>/dev/null | grep -i famfs; true" > "$R/famfs-before.txt"
  test ! -s "$R/famfs-before.txt" || { echo "STOP: FamFS configured on the guest (see famfs-before.txt)"; exit 1; }
  ssh_vm "pgrep -a -x 'vdb-server|faultlat|megalon.*' || true" > "$R/procs-before.txt"
  test ! -s "$R/procs-before.txt" || { echo "STOP: workload processes running"; exit 1; }
  log "precheck PASS" ;;
prepare)
  reuse_dir "$G" staging-prepare "$C" "${PREP[@]}"   # again (precheck ran in another invocation)
  ssh_vm "umask 077; test -d $G || mkdir -m 0700 $G"
  scp_vm "${PREP[@]/#/$C/}" "comsys@$IP:$G/"
  ssh_vm "cd $G && sha256sum -c preparation.sha256 && sudo -n bash ./prepare-guest.sh" 2>&1 | tee "$R/prepare-guest.log"
  grep -q "prepare-guest PASS ($K)" "$R/prepare-guest.log"
  scp_vm "comsys@$IP:$G/initrd.img-$K" "$R/"
  scp_vm "comsys@$IP:$G/initrd.sha256" "$R/guest-initrd.sha256"
  scp_vm "comsys@$IP:$G/initrd-members.txt" "$R/"
  python3 -I "$C/verify-initrd.py" "$R/initrd.img-$K" "$C/modules-manifest.json"
  test "$(cut -d' ' -f1 "$R/guest-initrd.sha256")" = "$(sha256sum "$R/initrd.img-$K" | cut -d' ' -f1)"
  log "prepare PASS" ;;
install)
  test ! -L "$D"
  if [ -e "$D" ]; then   # re-run: accepted only if it already holds exactly these two images (never overwritten)
    test -d "$D"
    want="$BZ_SHA $(cut -d' ' -f1 "$R/guest-initrd.sha256")"
    got=$(sudo -n sha256sum "$D/bzImage" "$D/initrd.img-$K" 2>/dev/null | cut -d' ' -f1 | tr '\n' ' ') || got=missing
    [ "${got% }" = "$want" ] || { log "STOP: $D exists with other images (new initrd differs or a file is missing): use a new bundle version"; exit 1; }
    log "install: $D already holds the identical bzImage and initrd (nothing copied)"
  else
    sudo -n install -d -o root -g 108 -m 0750 "$D"
    sudo -n install -o root -g 108 -m 0640 "$BZ" "$D/bzImage"
    sudo -n install -o root -g 108 -m 0640 "$R/initrd.img-$K" "$D/initrd.img-$K"
  fi
  host_recheck
  log "install PASS" ;;
restricted)
  xml_is "$R/before.xml"; host_recheck
  ssh_vm "pgrep -a -x 'vdb-server|faultlat' || true" > "$R/procs-before-shutdown.txt"
  test ! -s "$R/procs-before-shutdown.txt" || { log "STOP: workload processes running"; exit 1; }
  "${V[@]}" shutdown "$VM"
  wait_off 120 || { log "STOP: initial shutdown timed out (no force, no change)"; exit 1; }
  "${V[@]}" define --validate "$X/candidate-restricted.xml"
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
  grep -qx "REL=$K" <<<"$L"
  grep -qxF "CMD=$(cmdline_of "$X/candidate-restricted.xml")" <<<"$L"
  grep -qE '^ROOT=/dev/vda1 ext4 ro(,|$)' <<<"$L"
  grep -qx 'CXLSHM=0' <<<"$L"
  grep -q 'swmc-destijl: De Stijl v2 coherence initialized' <<<"$L" || log "note: init banner not on console (checked again in normal)"
  log "restricted acceptance PASS"
  # Never exit the PID 1 shell (panics). Power off via sysrq; root is ro.
  python3 -I "$CONSOLE" --domain "$VM" --log "$R/console-stop.log" --timeout 30 --wait '^# ?$' \
    --send 'sync; echo o > /proc/sysrq-trigger' || true
  if ! wait_off 60; then log "sysrq power-off failed; destroy"; "${V[@]}" destroy "$VM"; fi
  log "restricted PASS (VM shut off)" ;;
normal)
  [ "$(state)" = "shut off" ]
  grep -q "$VM restricted PASS" "$R/steps.log"; xml_is "$R/defined-restricted.xml"; host_recheck
  "${V[@]}" define --validate "$X/candidate-normal.xml"
  "${V[@]}" start "$VM"
  for i in $(seq 40); do ssh_vm true 2>/dev/null && break; sleep 6; done
  ssh_vm "uname -r; cat /proc/cmdline; findmnt -rn -o SOURCE,FSTYPE,OPTIONS /; \
    echo SYSTEMD=\$(systemctl is-system-running); systemctl --failed --no-legend --plain" \
    | tee "$R/normal-check.txt"
  test "$(sed -n 1p "$R/normal-check.txt")" = "$K"
  test "$(sed -n 2p "$R/normal-check.txt")" = "$(cmdline_of "$X/candidate-normal.xml")"
  grep -E '^SYSTEMD=(running|degraded)$' "$R/normal-check.txt"  # degraded allowed; failed units recorded
  for i in $(seq 20); do nd_state > "$R/nd-after.txt"; cmp -s "$R/nd-before.txt" "$R/nd-after.txt" && break; sleep 3; done
  diff "$R/nd-before.txt" "$R/nd-after.txt" || { log "FAIL: nd state changed"; exit 1; }  # namespace, devices, drivers
  if grep -qx cxl_shm "$R/nd-after.txt"; then echo "FAIL: cxl_shm loaded"; exit 1; fi
  # De Stijl kernel identity (read-only): protocol, nothing managed yet, De Stijl sysfs present, init banner
  ssh_vm "cat /sys/kernel/swmc/page_coherence/protocol /sys/kernel/swmc/page_coherence/managed_bytes; \
    test -d /sys/kernel/swmc/destijl && echo destijl-sysfs || echo no-destijl-sysfs; stat -c '%U:%G %a' /dev/dax0.0; \
    cat /sys/bus/dax/devices/dax0.0/size /sys/bus/dax/devices/dax0.0/align; \
    grep -o -m1 -w waitpkg /proc/cpuinfo || echo no-waitpkg; \
    dmesg 2>/dev/null | grep -c 'swmc-destijl: De Stijl v2 coherence initialized' || true; \
    ls /sys/kernel/swmc/destijl | tr '\n' ' '; echo" | tee "$R/destijl-check.txt"
  test "$(sed -n 1p "$R/destijl-check.txt")" = destijl
  test "$(sed -n 2p "$R/destijl-check.txt")" = 0
  test "$(sed -n 3p "$R/destijl-check.txt")" = destijl-sysfs
  test "$(sed -n 4p "$R/destijl-check.txt")" = "root:root 600"
  test "$(sed -n 5p "$R/destijl-check.txt")" = 103060340736
  test "$(sed -n 6p "$R/destijl-check.txt")" = 4096
  [ "$(sed -n 8p "$R/destijl-check.txt")" != 0 ] || log "note: init banner not in dmesg (dmesg restricted or rotated)"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-normal.xml"
  cmp "$R/after-normal.xml" "$X/candidate-normal.xml" || diff "$X/candidate-normal.xml" "$R/after-normal.xml" > "$R/after-normal.diff" || true
  log "normal PASS ($VM running $K)" ;;
tools)
  test "$(ssh_vm 'uname -r')" = "$K"
  reuse_dir "$GT" tools-copy "$C/tools" $(cd "$C/tools" && ls -A)   # existing: identical to the bundle tools, else STOP
  ssh_vm "umask 022; test -d $GT || mkdir -m 0755 $GT"
  scp_vm "$C"/tools/* "comsys@$IP:$GT/"
  ssh_vm "cd $GT && sha256sum -c tools.sha256 && chmod 0755 faultlat run.sh p-destijl-guest.sh de_stijl_test" | tee "$R/tools.txt"
  ssh_vm "sha256sum /lib/modules/$K/updates/cxl_shm.ko; modinfo -F vermagic /lib/modules/$K/updates/cxl_shm.ko" | tee -a "$R/tools.txt"
  grep -q "^$(sed -n 's/^KO_SHA=//p' "$C/tools/destijl.env")  /lib/modules/$K/updates/cxl_shm.ko$" "$R/tools.txt"
  log "tools PASS ($GT)" ;;
rollback)
  if [ "$(state)" = "running" ] && xml_is "$R/before.xml"; then
    log "rollback: definition unchanged and VM running; nothing to do"; exit 0; fi
  # Reachable VM: cxl_shm must be unloaded first (p-destijl-shm.sh teardown, ONLY=<k> if the peer is gone), unless
  # ROLLBACK_FORCE=1 (after a failed teardown). Unreachable VM (ssh fails): it cannot be torn down; it is rolled back
  # directly (shutdown, destroy after 120 s) - explicit, not mistaken for "not loaded".
  if ssh_vm true 2>/dev/null; then
    if ssh_vm "grep -q '^cxl_shm ' /proc/modules"; then
      if [ "${ROLLBACK_FORCE:-0}" = 1 ]; then log "ROLLBACK_FORCE: cxl_shm still loaded; rolling back anyway"
      else log "STOP: cxl_shm still loaded; unload it first (p-destijl-shm.sh teardown) or ROLLBACK_FORCE=1"; exit 1; fi
    fi
  else
    log "VM unreachable over ssh: rolling back without teardown"
  fi
  if [ "$(state)" != "shut off" ]; then
    "${V[@]}" shutdown "$VM" || true
    wait_off 120 || "${V[@]}" destroy "$VM"
  fi
  "${V[@]}" define --validate "$R/before.xml"
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-rollback.xml"
  cmp "$R/before.xml" "$R/after-rollback.xml"
  "${V[@]}" start "$VM"
  for i in $(seq 40); do ssh_vm true 2>/dev/null && break; sleep 6; done
  ssh_vm "uname -r; cat /proc/cmdline" > "$R/kernel-after-rollback.txt"
  cmp "$R/kernel-before.txt" "$R/kernel-after-rollback.txt"
  log "rollback done (original definition restored, $(head -1 "$R/kernel-after-rollback.txt") running)" ;;
*) sed -n '2,29p' "$0"; exit 2 ;;
esac
