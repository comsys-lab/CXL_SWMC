#!/bin/bash
# Direct-boot deployment of Popcorn build 14 (kernel builds/popcorn_new/14 + cxl_shm 14.0-dir; bundle from
# p-popcorn-dir-package.sh, which ships this script as p-popcorn-deploy.sh) to ONE VM, on the 2-VM or the VM8 topology
# (experiment popcorn-directory-reference). = p-popcorn-deploy.sh (same phases, same Host/guest commands, same rollback:
# the saved Popcorn 13 definition, refused while cxl_shm is loaded) + the re-run rules of p-destijl-deploy.sh, because
# cxl_vm0's disk keeps /lib/modules/<K14> after the N = 2 deploy and every VM8 overlay (vm0..7) inherits it:
#   precheck  an existing /lib/modules/$K is accepted only if it is exactly the bundle install set
#             (verify-installed-modules.py on a find/sha256sum listing: every module + build/.config by sha256, only
#             depmod outputs extra, root-owned); an existing $G / $GT only if comsys-owned and empty or holding exactly
#             the bundle files; an existing $D only as a directory (install decides); anything else STOP
#   prepare   prepare-guest.sh (= ds-prepare-guest.sh) extracts into an absent /lib/modules/$K, or re-verifies the
#             installed one without extraction; depmod; the initramfs is always rebuilt in $G
#   install   an existing $D is accepted only if it already holds the identical bzImage and initrd (never overwritten)
#   tools     an existing $GT only if identical to the bundle tools (reuse_dir), else STOP
# Popcorn build-14 identity in `normal` (read-only): protocol popcorn-msi, nothing managed, dir_flat = 0 (attribute of
# kernel 14; 1 only while a directory=flat region is registered), instr/build = 13 (SWMC_INSTR_BUILD unchanged in 14).
# Usage: [DRY=1] p-popcorn-deploy-dir.sh <phase>
#   DRY=1: Host-local only (no virsh, ssh, scp, sudo, no R dir): the bundle-side checks of precheck (packet,
#   preparation, tools, xml hashes, module payload, release, bzImage, XML image paths, re-run files present), then the
#   phase's remote steps as a plan; last line "DEPLOY DRY PASS <phase> <VM> ...".
# Phases (run in order; each stops on the first unexpected result):
#   precheck  verify bundle hashes, bzImage, saved XML == bundle rollback XML,
#             free space, targets (re-run rules above), NVDIMM baseline (no privilege)
#   prepare   guest: stage bundle in $G, sudo prepare-guest.sh; fetch + verify the initrd
#   install   Host: sudo install bzImage/initrd into $D
#   restricted  graceful shutdown, define restricted XML, start on the serial
#             console (init=/bin/sh), acceptance, sysrq power-off
#   normal    define normal XML (same kernel, no init=), start, verify over
#             SSH; NVDIMM namespace/devices/driver set must equal precheck
#   tools     copy the Popcorn guest tools (faultlat, run.sh, region config,
#             p-popcorn-guest.sh = p-popcorn-guest-dir.sh, popcorn.env) to $GT (comsys-owned, no sudo); the installed
#             /lib/modules/$K/updates/cxl_shm.ko must be KO_SHA (signed 14.0-dir) with vermagic $K
#   rollback  stop VM (graceful, destroy after 120 s), define saved XML,
#             verify, start on the original definition (Popcorn 13: the 13-recv2 tools dir of the guest is untouched)
# Env (all required): VM IP C X G D GT K BZ BZ_SHA R PRE_K
#   PRE_K  release the VM must be running at precheck (6.14.0-famfs-de-stijl+-ds-popcorn-new-13)
#   C  common bundle dir (modules.tar, manifest, prepare scripts, tools/)
#   X  per-VM XML dir (rollback-inactive.xml, candidate-{normal,restricted}.xml)
#   G  guest staging dir (/var/tmp/<name>), D Host images dir,
#   GT guest tools dir (/home/comsys/<name>), K release, BZ bzImage path,
#   BZ_SHA its sha256, R evidence dir for this VM (new; parent must exist)
set -euo pipefail
umask 077
: "${VM:?}" "${IP:?}" "${C:?}" "${X:?}" "${G:?}" "${D:?}" "${GT:?}" "${K:?}" "${BZ:?}" "${BZ_SHA:?}" "${R:?}" "${PRE_K:?}"
[[ "$G" =~ ^/var/tmp/[A-Za-z0-9._-]+$ ]] && [[ "$D" =~ ^/var/lib/libvirt/images/[A-Za-z0-9._-]+$ ]] &&
  [[ "$GT" =~ ^/home/comsys/[A-Za-z0-9._-]+$ ]] || { echo "bad G/D/GT"; exit 2; }
[[ "$K" == *-ds-popcorn-new-14 ]] || { echo "p-popcorn-deploy-dir.sh deploys Popcorn build 14 only (K=$K)"; exit 2; }
DRY=${DRY:-0}
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
# Re-deploy of a release that is already installed on the guest (same bundle content), as p-destijl-deploy.sh:
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
      log "note: /lib/modules/$K exists and equals the bundle install set (inherited from cxl_vm0's disk or an earlier deploy; prepare reuses it)" ;;
    *) log "STOP: /lib/modules/$K is a $kind"; exit 1 ;;
  esac; }
bundle_local() {  # Host-local bundle checks (precheck, and DRY=1 of every phase)
  (cd "$C" && sha256sum --quiet -c packet.sha256 && sha256sum --quiet -c preparation.sha256)
  (cd "$C/tools" && sha256sum --quiet -c tools.sha256)
  (cd "$X" && sha256sum --quiet -c xml.sha256)
  local f; for f in "${PREP[@]}"; do test -f "$C/$f" || { echo "STOP: bundle has no $f (not a re-run capable build-14 bundle)"; exit 1; }; done
  grep -q '  verify-installed-modules.py$' "$C/preparation.sha256" || { echo "STOP: verify-installed-modules.py is not in preparation.sha256"; exit 1; }
  grep -q 'REUSE=1' "$C/prepare-guest.sh" || { echo "STOP: prepare-guest.sh does not accept an installed release"; exit 1; }
  python3 -I "$C/verify-module-payload.py"
  test "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$C/modules-manifest.json")" = "$K"
  printf '%s  %s\n' "$BZ_SHA" "$BZ" | sha256sum -c -
  grep -q "<kernel>$D/bzImage</kernel>" "$X/candidate-normal.xml"
  grep -q "<initrd>$D/initrd.img-$K</initrd>" "$X/candidate-normal.xml"
  grep -q "<name>$VM</name>" "$X/rollback-inactive.xml"
  grep -qx 'KO_VERSION=14.0-dir' "$C/tools/popcorn.env" && grep -qx "K=$K" "$C/tools/popcorn.env" ||
    { echo "STOP: $C/tools/popcorn.env is not K=$K KO_VERSION=14.0-dir"; exit 1; }
  ! grep -q '^KO_PATH=' "$C/tools/popcorn.env" || { echo "STOP: build-14 bundle must not be a module-override bundle (KO_PATH)"; exit 1; }
}

if [ "$DRY" = 1 ]; then
  case "${1:-}" in precheck|prepare|install|restricted|normal|tools|rollback) ;; *) sed -n '2,40p' "$0"; exit 2 ;; esac
  bundle_local
  echo "dry $1 $VM ($IP): bundle $C OK (packet, preparation, tools, xml, payload, release $K, bzImage, XML images $D, re-run files)"
  case $1 in
    precheck) echo "  plan: dumpxml --inactive == $X/rollback-inactive.xml; running $PRE_K; targets: $D absent or dir; $G / $GT absent, empty or = bundle; /lib/modules/$K absent or = bundle install set (verify-installed-modules.py --listing); NVDIMM baseline; no cxl_shm, FamFS, workload";;
    prepare) echo "  plan: stage ${PREP[*]} in $G; sudo prepare-guest.sh (extract or reuse-verified, depmod, initramfs); fetch + verify initrd";;
    install) echo "  plan: sudo install bzImage + initrd into $D (existing $D: identical images only)";;
    restricted) echo "  plan: shutdown, define $X/candidate-restricted.xml, console acceptance REL=$K, sysrq power-off";;
    normal) echo "  plan: define $X/candidate-normal.xml, start, uname $K, nd state == precheck, protocol popcorn-msi, managed 0, dir_flat 0, instr/build 13";;
    tools) echo "  plan: $GT absent or = bundle tools; copy $C/tools/*; installed cxl_shm.ko sha = KO_SHA $(sed -n 's/^KO_SHA=//p' "$C/tools/popcorn.env" | cut -c1-16), vermagic $K";;
    rollback) echo "  plan: (cxl_shm unloaded, else STOP) shutdown / destroy after 120 s, define R/before.xml (= $X/rollback-inactive.xml, Popcorn 13), start, kernel == kernel-before.txt";;
  esac
  echo "DEPLOY DRY PASS $1 $VM (nothing executed on the Host or the guest)"; exit 0
fi

case "${1:-}" in
precheck)
  bundle_local
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
  grep -q 'swmc-popcorn: popcorn-msi coherence initialized' <<<"$L" || log "note: init banner not on console (checked again in normal)"
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
  # Popcorn build-14 kernel identity (read-only): protocol, nothing managed yet, coherence off, no directory registered,
  # instrumentation format build 13
  ssh_vm "cat /sys/kernel/swmc/page_coherence/protocol /sys/kernel/swmc/page_coherence/managed_bytes; \
    cat /sys/module/swmc_kmsg/parameters/inline_dispatch; stat -c '%U:%G %a' /dev/dax0.0; \
    cat /sys/bus/dax/devices/dax0.0/size /sys/bus/dax/devices/dax0.0/align; \
    grep -o -m1 -w waitpkg /proc/cpuinfo || echo no-waitpkg; \
    cat /sys/kernel/swmc/page_coherence/dir_flat 2>/dev/null || echo no-dir_flat; \
    cat /sys/kernel/swmc/instr/build 2>/dev/null || echo no-instr-build" | tee "$R/popcorn-check.txt"
  test "$(sed -n 1p "$R/popcorn-check.txt")" = popcorn-msi
  test "$(sed -n 2p "$R/popcorn-check.txt")" = 0
  test "$(sed -n 3p "$R/popcorn-check.txt")" = Y
  test "$(sed -n 4p "$R/popcorn-check.txt")" = "root:root 600"
  test "$(sed -n 5p "$R/popcorn-check.txt")" = 103060340736
  test "$(sed -n 6p "$R/popcorn-check.txt")" = 4096
  test "$(sed -n 8p "$R/popcorn-check.txt")" = 0 || { log "FAIL: dir_flat is '$(sed -n 8p "$R/popcorn-check.txt")' (kernel 14 reports 0 before any load)"; exit 1; }
  test "$(sed -n 9p "$R/popcorn-check.txt")" = 13 || { log "FAIL: instr/build is '$(sed -n 9p "$R/popcorn-check.txt")' (kernel 14 reports 13)"; exit 1; }
  "${V[@]}" dumpxml "$VM" --inactive > "$R/after-normal.xml"
  cmp "$R/after-normal.xml" "$X/candidate-normal.xml" || diff "$X/candidate-normal.xml" "$R/after-normal.xml" > "$R/after-normal.diff" || true
  log "normal PASS ($VM running $K)" ;;
tools)
  test "$(ssh_vm 'uname -r')" = "$K"
  reuse_dir "$GT" tools-copy "$C/tools" $(cd "$C/tools" && ls -A)   # existing: identical to the bundle tools, else STOP
  ssh_vm "umask 022; test -d $GT || mkdir -m 0755 $GT"
  scp_vm "$C"/tools/* "comsys@$IP:$GT/"
  ssh_vm "cd $GT && sha256sum -c tools.sha256 && chmod 0755 faultlat run.sh p-popcorn-guest.sh" | tee "$R/tools.txt"
  KOF=/lib/modules/$K/updates/cxl_shm.ko
  ssh_vm "sha256sum $KOF; modinfo -F vermagic $KOF; modinfo -F version $KOF" | tee -a "$R/tools.txt"
  grep -q "^$(sed -n 's/^KO_SHA=//p' "$C/tools/popcorn.env")  $KOF$" "$R/tools.txt"
  grep -q "^$K " "$R/tools.txt"
  grep -qx '14.0-dir' "$R/tools.txt"
  log "tools PASS ($GT)" ;;
rollback)
  if [ "$(state)" = "running" ] && xml_is "$R/before.xml"; then
    log "rollback: definition unchanged and VM running; nothing to do"; exit 0; fi
  # Reachable VM: cxl_shm must be unloaded first (p-popcorn-shm.sh teardown, ONLY=<k> if the peer is gone).
  # Unreachable VM (ssh fails): it cannot be torn down; it is rolled back directly (shutdown, destroy after
  # 120 s) - explicit, not mistaken for "not loaded".
  if ssh_vm true 2>/dev/null; then
    if ssh_vm "grep -q '^cxl_shm ' /proc/modules"; then
      log "STOP: cxl_shm still loaded; unload it first (p-popcorn-shm.sh teardown)"; exit 1; fi
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
*) sed -n '2,40p' "$0"; exit 2 ;;
esac
