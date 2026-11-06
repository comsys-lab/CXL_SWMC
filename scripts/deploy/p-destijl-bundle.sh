#!/bin/bash
# Make the next De Stijl build-<n> deploy bundle (builds/destijl/<n>/deploy-v<next>, n = 7 or 8) on demand, for a deploy
# whose rollback target is a Popcorn bundle (default builds/popcorn_new/13/deploy-v2). Each De Stijl deploy needs its own
# bundle: the candidate XMLs fix the Host images dir /var/lib/libvirt/images/destijl-<n>-vm<k>-v<v> and p-destijl-deploy.sh
# install never overwrites an existing one (the guest rebuilds the initramfs on every prepare), and the bundle's rollback
# XML must equal the VM's current `virsh dumpxml --inactive`. Host-local only: no virsh, no ssh, no sudo.
#   p-destijl-bundle.sh [--dry-run] [--build 7|8|9|10|11|12] [--rollback <popcorn bundle dir>] [--topo 2|8] [--xml-src <dir>] [--version <v>]
# --build 7 (default, unchanged): see "Fixed inputs (build 7)" below.
# --build 8 (fault-latency breakdown port, d529ac9d9, user decision 2026-11-02 for blocks D, B2+C, E): SOURCE_TAG =
#   rel/destijl-8; MANIFEST.txt must say "status: COMPLETE" (workspaces/eval3/build8/finish-build8.sh) and System.map must
#   hold swmc_instr_breakdown_key; TOOLS_FROM = builds/destijl/7/deploy-v1 (faultlat, run.sh, cxl_region.yaml, guest
#   scripts, de_stijl_test byte-identical; destijl.env differs only in K and KO_SHA, so tools.sha256 differs too) ->
#   new guest tools dir GT=/home/comsys/destijl-8 (p-destijl-deploy.sh tools refuses a GT with other content); every
#   later build-8 bundle must have the tools.sha256 of the first build-8 bundle (same GT reused).
# --build 9 (write path phase A + adaptive receiver, cxl_shm 13.3, 4d1597980): SOURCE_TAG = rel/destijl-9, KTREE =
#   workspaces/destijl-v2/build9 (tag and msg_layer_module live there); MANIFEST "status: COMPLETE", System.map holds
#   swmc_instr_breakdown_key and ds_rx_mark_empty, staged cxl_shm.ko is version 13.3 with parameter fault_poll.
#   TOOLS_FROM = builds/destijl/7/deploy-v1 for faultlat, run.sh, cxl_region.yaml, ds-replica-check.sh, de_stijl_test
#   (byte-identical); NOT the "only K and KO_SHA differ" rule: tools/p-destijl-guest.sh = scripts/deploy/
#   p-destijl-guest-adaptive.sh (load accepts recv_mode=adaptive, fault_poll=0|1) and destijl.env gains
#   LOAD_DEFAULTS="fault_poll=0" (applied at every load unless LOAD_EXTRA sets fault_poll) -> new tools set, new guest
#   tools dir GT=/home/comsys/destijl-9; later build-9 bundles must match the first one's tools.sha256.
# --build 10 (build 9 + review fixes, cxl_shm 13.4, rel/destijl-10 934ad4a68): the build-9 rules with KTREE =
#   workspaces/destijl-v2/build10 and staged module version 13.4. Tools-identity rule: destijl.env carries K and KO_SHA
#   of build 10, so tools.sha256 can never equal build 9's -> new guest tools dir GT=/home/comsys/destijl-10 (the
#   destijl-9 dir is not reused); later build-10 bundles must match the first one's tools.sha256. MANIFEST
#   dirty_sha256 may be empty or "none" (both = clean; p-destijl-package.sh).
# --build 11 (build 10 + INV/ACK wait knobs /sys/kernel/swmc/destijl/inv_poll_backoff_max, inv_ack_atomic_and; branch
#   destijl-invack, tag rel/destijl-11): the build-10 rules with KTREE = workspaces/ds-invack/kernel, staged module
#   version 13.4 (the INV/ACK change is in kernel/swmc, not in cxl_shm; change KOVER here if build 11 bumps cxl_shm)
#   and a new guest tools dir GT=/home/comsys/destijl-11. A De Stijl build-11 deploy needs the verifier PASS marker
#   (workspaces/ds-invack/VERIFIER-PASS); the chains check it, this script does not.
# --topo 2 (default): cxl_vm0/1; rollback XML = <rollback bundle>/vm<k>/candidate-normal.xml (what the VMs run after a
#   Popcorn deploy from that bundle). --xml-src overrides it (a dir with vm<k>/candidate-normal.xml or
#   cxl_vm<k>.after-define.xml).
# --topo 8: cxl_vm0..7 (VM8 topology, 4 vCPU / 24 GB, all eight boot vm0's kernel); --xml-src is required = the
#   topo8/ dir of the vmN switch that defined the topology the VMs run now (cxl_vm<k>.after-define.xml; the
#   generator-formatted cxl_vm<k>.xml never equals dumpxml). The same bundle serves N = 4 (vm0..3) and N = 8.
# Every XML source must boot the rollback bundle's release (initrd.img-<PRE_K>), so the deploy precheck's PRE_K holds.
# Fixed inputs (build 7): SOURCE_TAG=rel/destijl-6, KTREE=workspaces/destijl-v2/kernel, FAULTLAT_BUILD=builds/faultlat/3,
# TOOLS_FROM=builds/destijl/7/deploy-v1 (guest tools byte-identical, guest dir /home/comsys/destijl-7 reused), stage/
# reused (nothing is compiled, so a bundle can be made while MEASUREMENT.lock exists; packaging runs under build-wrap.sh).
# --dry-run: every check + the XML derivation into a scratch dir (removed), prints the package command and the deploy
# environment; writes nothing under builds/. Real run: p-destijl-package.sh, then post-checks and deploy-v<v>/MANIFEST.txt
# (packet.sha256 / modules.tar / XML sha256s + deploy env; written after packet.sha256, so not listed in it) and
# deploy-v<v>/deploy-env.sh (sourceable: C K PRE_K BZ BZ_SHA GT V VMS PKT_SHA; per VM G=/var/tmp/destijl-7-vm<k>-v<v>,
# D=/var/lib/libvirt/images/destijl-7-vm<k>-v<v>, X=$C/vm<k>).
set -euo pipefail
umask 022
ROOT=/home/comsys/sungsu/destijl-control
SW=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
n=7
KTREE=$ROOT/workspaces/destijl-v2/kernel
FAULTLAT_BUILD=$ROOT/builds/faultlat/3
DRY=0 TOPO=2 RB=$ROOT/builds/popcorn_new/13/deploy-v2 XSRC= V=   # deploy-v2 = what the VMs run (deploy-v1 never installed)
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1;;
    --build) n=${2:?}; shift;;
    --rollback) RB=${2:?}; shift;;
    --topo) TOPO=${2:?}; shift;;
    --xml-src) XSRC=${2:?}; shift;;
    --version) V=${2:?}; shift;;
    *) sed -n '2,43p' "$0"; exit 2;;
  esac; shift
done
stop() { echo "BUNDLE STOP: $*"; exit 1; }
sh_() { sha256sum "$1" | cut -d' ' -f1; }
case $n in
  7) B=$ROOT/builds/destijl/7 SOURCE_TAG=rel/destijl-6 TOOLS_FROM=$ROOT/builds/destijl/7/deploy-v1;;
  8) B=$ROOT/builds/destijl/8 SOURCE_TAG=rel/destijl-8 TOOLS_FROM=$ROOT/builds/destijl/7/deploy-v1;;
  9) B=$ROOT/builds/destijl/9 SOURCE_TAG=rel/destijl-9 TOOLS_FROM=$ROOT/builds/destijl/7/deploy-v1
     KTREE=$ROOT/workspaces/destijl-v2/build9 KOVER=13.3;;
  10) B=$ROOT/builds/destijl/10 SOURCE_TAG=rel/destijl-10 TOOLS_FROM=$ROOT/builds/destijl/7/deploy-v1
      KTREE=$ROOT/workspaces/destijl-v2/build10 KOVER=13.4;;
  11) B=$ROOT/builds/destijl/11 SOURCE_TAG=rel/destijl-11 TOOLS_FROM=$ROOT/builds/destijl/7/deploy-v1
      KTREE=$ROOT/workspaces/ds-invack/kernel KOVER=13.4;;
  12) B=$ROOT/builds/destijl/12 SOURCE_TAG=rel/destijl-12 TOOLS_FROM=$ROOT/builds/destijl/7/deploy-v1
      KTREE=$ROOT/workspaces/flat-directory/src KOVER=13.5;;
  *) stop "--build must be 7, 8, 9, 10, 11 or 12";;
esac
# build 9 / 10 / 11 rule: own guest script and destijl.env LOAD_DEFAULTS (new tools set); builds 7/8: none (unchanged)
GUEST_SRC= ENV_EXTRA= REGION_SRC=
if [ "$n" = 9 ] || [ "$n" = 10 ] || [ "$n" = 11 ]; then GUEST_SRC=$SW/scripts/deploy/p-destijl-guest-adaptive.sh ENV_EXTRA='LOAD_DEFAULTS="fault_poll=0"'; fi
# --build 12 (build 10 + flat base page directory, cxl_shm 13.5, rel/destijl-12 2788a32af; experiment
#   flat-directory-reference): the build-10 rules with KTREE = workspaces/flat-directory/src, staged module version 13.5
#   with parameter bpd_mode, guest script scripts/deploy/p-destijl-guest-flat.sh (load accepts bpd_mode=sets|flat),
#   LOAD_DEFAULTS="fault_poll=0 bpd_mode=flat", region config/cxl_region-destijl-flat.yaml (REGION_SRC: tools/
#   cxl_region.yaml + PARAMS*; cxl_region.yaml leaves the byte-identity set), guest tools dir /home/comsys/destijl-12.
#   The build dir has no stage/ yet: the first real bundle runs p-destijl-package.sh's own stage step (modules_install
#   signs with the build's key, depmod), which refuses while MEASUREMENT.lock exists; the dry run checks the unsigned
#   build output cxl_shm/cxl_shm.ko instead and says so.
if [ "$n" = 12 ]; then
  GUEST_SRC=$SW/scripts/deploy/p-destijl-guest-flat.sh ENV_EXTRA='LOAD_DEFAULTS="fault_poll=0 bpd_mode=flat"'
  REGION_SRC=$SW/config/cxl_region-destijl-flat.yaml
  test -f "$REGION_SRC" || stop "no $REGION_SRC"
  git -C "$SW" ls-files --error-unmatch config/cxl_region-destijl-flat.yaml > /dev/null 2>&1 || stop "$REGION_SRC is not tracked in $SW"
fi
# test hook (dry runs only): a stand-in build dir / source tag, for the build-8 path before build 8 is finished
if [ $DRY = 1 ] && [ -n "${BUNDLE_TEST_BUILD_DIR:-}" ]; then
  B=$(readlink -f "$BUNDLE_TEST_BUILD_DIR"); SOURCE_TAG=${BUNDLE_TEST_SOURCE_TAG:-$SOURCE_TAG}
  echo "NOTE: test hook: build dir $B, source tag $SOURCE_TAG"
fi
GT=/home/comsys/destijl-$n
# tools of TOOLS_FROM that must be byte-identical (destijl.env: only for the same build; else equal except K / KO_SHA)
SAME=(faultlat run.sh cxl_region.yaml p-destijl-guest.sh ds-replica-check.sh de_stijl_test)
[ -z "$GUEST_SRC" ] || SAME=(faultlat run.sh cxl_region.yaml ds-replica-check.sh de_stijl_test)
[ -z "$REGION_SRC" ] || SAME=(faultlat run.sh ds-replica-check.sh de_stijl_test)
[ "$(dirname "$TOOLS_FROM")" = "$B" ] && SAME+=(destijl.env tools.sha256)
case $TOPO in
  2) VMS="0 1";;
  8) VMS="0 1 2 3 4 5 6 7"; [ -n "$XSRC" ] || stop "--topo 8 needs --xml-src <vmN switch evidence>/topo8";;
  *) stop "--topo must be 2 or 8";;
esac
RB=$(readlink -f "$RB"); XSRC=${XSRC:+$(readlink -f "$XSRC")}; XSRC=${XSRC:-$RB}
# next free bundle version (never reuse a number, even of a removed dir: highest existing + 1)
if [ -z "$V" ]; then
  last=$(find "$B" -maxdepth 1 -name 'deploy-v*' -printf '%f\n' | sed -n 's/^deploy-v\([0-9]\+\)$/\1/p' | sort -n | tail -1)
  V=$(( ${last:-0} + 1 ))
fi
[[ "$V" =~ ^[0-9]+$ ]] || stop "bad version $V"
OUT=$B/deploy-v$V
test ! -e "$OUT" || stop "$OUT exists"

# 1. rollback bundle (Popcorn): intact, its release = PRE_K
test -f "$RB/package-record.json" || stop "$RB is not a bundle (no package-record.json)"
(cd "$RB" && sha256sum --quiet -c packet.sha256) || stop "$RB fails its packet.sha256"
PRE_K=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$RB/package-record.json")
[[ "$PRE_K" == 6.14.0-famfs-de-stijl+-ds-popcorn-new-* ]] || stop "rollback release '$PRE_K' is not a Popcorn build"
RB_PKT=$(sh_ "$RB/packet.sha256")

# 2. XML sources: the inactive definition each VM has while running PRE_K
if [ -f "$XSRC/SHA256SUMS" ]; then (cd "$XSRC" && sha256sum --quiet -c SHA256SUMS) || stop "$XSRC fails SHA256SUMS"; fi
declare -A XS
for k in $VMS; do
  XS[$k]=
  for f in "$XSRC/vm$k/candidate-normal.xml" "$XSRC/cxl_vm$k/candidate-normal.xml" "$XSRC/cxl_vm$k.after-define.xml"; do
    [ -f "$f" ] && { XS[$k]=$f; break; }; done
  [ -n "${XS[$k]}" ] || stop "no XML source for vm$k in $XSRC"
  [ ! -f "$XSRC/vm$k/xml.sha256" ] || (cd "$XSRC/vm$k" && sha256sum --quiet -c xml.sha256) || stop "$XSRC/vm$k fails xml.sha256"
  grep -q "<name>cxl_vm$k</name>" "${XS[$k]}" || stop "${XS[$k]} is not cxl_vm$k"
  grep -F "<initrd>/var/lib/libvirt/images/" "${XS[$k]}" | grep -qF "/initrd.img-$PRE_K</initrd>" ||
    stop "${XS[$k]} does not boot $PRE_K (XML source and rollback bundle disagree)"
  head -c 100 "${XS[$k]}" | grep -q '^<domain type=.kvm.' || stop "${XS[$k]} is not in virsh dumpxml form (<domain type='kvm' ...> first)"
  if [ "$TOPO" = 8 ]; then
    grep -q "<vcpu placement='static'>4</vcpu>" "${XS[$k]}" || stop "${XS[$k]}: not 4 vCPU (VM8 topology)"
  fi
done

# 3. build <n> inputs (the same checks p-destijl-package.sh repeats, here so the dry run sees them)
M=$B/MANIFEST.txt
test -f "$M" || stop "no $M"
mf() { sed -n "s/^$1: \([^ ]*\).*/\1/p" "$M" | head -1; }
art() { awk -v f="$1" '$1 == f {print $2; exit}' "$M"; }
K=$(mf release); BZ=$B/arch/x86/boot/bzImage; BZ_SHA=$(art arch/x86/boot/bzImage)
[ "$K" = "6.14.0-famfs-de-stijl+-ds-destijl-$n" ] || stop "MANIFEST release '$K'"
if [ "$n" = 8 ]; then
  [ "$(mf status)" = COMPLETE ] || stop "build 8 MANIFEST status '$(mf status)' (run workspaces/eval3/build8/finish-build8.sh)"
  grep -q ' swmc_instr_breakdown_key$' "$B/System.map" || stop "build 8 System.map has no swmc_instr_breakdown_key"
  [ "$(sh_ "$B/System.map")" = "$(art System.map)" ] || stop "System.map changed since the MANIFEST"
fi
if [ "$n" = 9 ] || [ "$n" = 10 ] || [ "$n" = 11 ] || [ "$n" = 12 ]; then
  if [ "$n" = 12 ]; then  # MANIFEST says "BUILT, NOT STAGED" until the first real bundle stages it (package stage step)
    [[ "$(mf status)" == BUILT* || "$(mf status)" == COMPLETE ]] || stop "build $n MANIFEST status '$(mf status)'"
    grep -q ' bpd_flat_acquire_show$' "$B/System.map" || stop "build 12 System.map has no bpd_flat_acquire_show"
  else
    [ "$(mf status)" = COMPLETE ] || stop "build $n MANIFEST status '$(mf status)'"
  fi
  for s in swmc_instr_breakdown_key ds_rx_mark_empty; do
    grep -q " $s\$" "$B/System.map" || stop "build $n System.map has no $s"; done
  [ "$(sh_ "$B/System.map")" = "$(art System.map)" ] || stop "System.map changed since the MANIFEST"
  SKO=$B/stage/lib/modules/$K/updates/cxl_shm.ko
  if [ "$n" = 12 ] && [ ! -e "$B/stage" ]; then
    [ ! -e "$ROOT/workspaces/MEASUREMENT.lock" ] || [ $DRY = 1 ] ||
      stop "build 12 has no stage/ and MEASUREMENT.lock exists: p-destijl-package.sh would run modules_install (run without the lock)"
    echo "NOTE: build 12 has no stage/: p-destijl-package.sh stages it (modules_install, signed with the build's key, depmod); checking the unsigned build output instead"
    SKO=$B/cxl_shm/cxl_shm.ko
  fi
  test -f "$SKO" || stop "no staged $SKO"
  [ "$n" != 12 ] || modinfo -F parm "$SKO" | grep -q '^bpd_mode:' || stop "$SKO has no bpd_mode parameter"
  [ "$(modinfo -F version "$SKO")" = "$KOVER" ] || stop "staged cxl_shm.ko is not version $KOVER"
  [ "$(modinfo -F vermagic "$SKO" | cut -d' ' -f1)" = "$K" ] || stop "staged cxl_shm.ko vermagic is not $K"
  modinfo -F parm "$SKO" | grep -q '^fault_poll:' || stop "staged cxl_shm.ko has no fault_poll parameter"
  modinfo -F parm "$SKO" | grep -q '^recv_mode:.*adaptive' || stop "staged cxl_shm.ko recv_mode has no adaptive"
  test -f "$GUEST_SRC" && bash -n "$GUEST_SRC" || stop "guest script $GUEST_SRC missing or not valid bash"
  grep -qF 'recv_mode=(poll|sleep|adaptive)|fault_poll=[01]' "$GUEST_SRC" || stop "$GUEST_SRC does not accept recv_mode=adaptive / fault_poll"
fi
[ "$(sh_ "$BZ")" = "$BZ_SHA" ] || stop "bzImage changed"
[ "$(sh_ "$B/.config")" = "$(mf config_sha256)" ] || stop ".config changed"
[ "$(sh_ "$B/cxl_shm/cxl_shm.ko")" = "$(art cxl_shm/cxl_shm.ko)" ] || stop "cxl_shm.ko changed"
if [ "$n" = 12 ]; then
  grep -qF 'bpd_mode=(sets|flat)' "$GUEST_SRC" || stop "$GUEST_SRC does not accept bpd_mode"
  # the region must hold the flat block: msg_ring of REGION_SRC = [134217728, 134217728] (128 MiB, cxl_region-destijl-flat.yaml)
  [ "$(grep -E '^msg_ring:' "$REGION_SRC" | cut -d'#' -f1 | tr -d ' ')" = 'msg_ring:[134217728,134217728]' ] || stop "$REGION_SRC msg_ring is not [134217728, 134217728]"
else
  test -f "$B/stage/lib/modules/$K/updates/cxl_shm.ko" || stop "no stage (packaging would compile/install modules)"
fi
[ "$(git -C "$KTREE" rev-parse "$SOURCE_TAG^{commit}")" = "$(git -C "$KTREE" rev-parse "$(mf source_commit)^{commit}")" ] ||
  stop "$SOURCE_TAG != build source commit"
[ -z "$(git -C "$KTREE" status --porcelain -- msg_layer_module)" ] || stop "$KTREE/msg_layer_module not clean"
want=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["faultlat_sha256"])' "$FAULTLAT_BUILD/build-record.json")
[ "$(sh_ "$FAULTLAT_BUILD/faultlat")" = "$want" ] || stop "faultlat build 3 changed"
(cd "$TOOLS_FROM/tools" && sha256sum --quiet -c tools.sha256) || stop "$TOOLS_FROM/tools fails tools.sha256"
cmp -s "$FAULTLAT_BUILD/faultlat" "$TOOLS_FROM/tools/faultlat" || stop "faultlat != $TOOLS_FROM/tools/faultlat"
for p in run.sh:workloads/faultlat/run.sh cxl_region.yaml:config/cxl_region-destijl.yaml \
         p-destijl-guest.sh:scripts/deploy/p-destijl-guest.sh ds-replica-check.sh:scripts/deploy/ds-replica-check.sh; do
  cmp -s "$TOOLS_FROM/tools/${p%%:*}" "$SW/${p#*:}" || stop "$SW/${p#*:} differs from $TOOLS_FROM/tools/${p%%:*}"
done
TC=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["cxl_swmc_commit"])' "$TOOLS_FROM/package-record.json")
# proc_stats.h (server-side stats collector, not part of faultlat / libdestijl: no include there) and the Host tests are
# not guest tools; a change there (2026-11-05 per-step RCA export) does not invalidate the packaged tools
git -C "$SW" diff --quiet "$TC" -- systems/destijl/lib systems/common ':(exclude)systems/common/proc_stats.h' ':(exclude)systems/common/tests' \
  || stop "systems/destijl/lib or systems/common changed since $TC"
grep -rlqE '#include *"proc_stats\.h"' "$SW/workloads/faultlat" "$SW/systems/destijl/lib" 2>/dev/null && stop "faultlat / libdestijl include proc_stats.h: it is a guest-tool source again"
DIRTY=$(git -C "$SW" status --porcelain -- scripts/deploy workloads/faultlat systems/destijl systems/common config | wc -l)
[ "$DIRTY" = 0 ] || echo "NOTE: $DIRTY dirty files in $SW (recorded as cxl_swmc_dirty_files; commit before a real bundle)"

# earlier build-n bundles with tools: the new one must have the same tools.sha256 (one guest tools dir GT per build)
FIRST_TOOLS=$(find "$B" -maxdepth 3 -path "$B/deploy-v*/tools/tools.sha256" 2>/dev/null | sort -V | head -1)
[ "$n" = 7 ] || [ -z "$FIRST_TOOLS" ] || echo "earlier build-$n tools: $FIRST_TOOLS (the new bundle must match it)"

PKG=(env XML_SRC="$XSRC" VMS="$VMS" KTREE="$KTREE" SOURCE_TAG="$SOURCE_TAG" FAULTLAT_BUILD="$FAULTLAT_BUILD"
     TOOLS_FROM="$TOOLS_FROM" bash "$SW/scripts/ctl/build-wrap.sh" bash "$SW/scripts/deploy/p-destijl-package.sh" "$n" "$V")
[ -z "$GUEST_SRC" ] || PKG=(env GUEST_SRC="$GUEST_SRC" ENV_EXTRA="$ENV_EXTRA" "${PKG[@]:1}")
[ -z "$REGION_SRC" ] || PKG=(env REGION_SRC="$REGION_SRC" "${PKG[@]:1}")
denv() {  # deploy environment (sourceable)
  echo "# De Stijl build $n bundle deploy-v$V: deploy environment for p-destijl-deploy.sh / p-destijl-shm.sh"
  echo "C=$OUT"; echo "V=$V"; echo "K=$K"; echo "PRE_K=$PRE_K"; echo "BZ=$BZ"; echo "BZ_SHA=$BZ_SHA"; echo "GT=$GT"
  echo "VMS=\"$VMS\""; echo "ROLLBACK_BUNDLE=$RB"; echo "ROLLBACK_PACKET_SHA=$RB_PKT"
  echo "PKT_SHA=${1:-<after packaging>}"
  echo "# per VM k: VM=cxl_vm\$k X=\$C/vm\$k G=/var/tmp/destijl-$n-vm\$k-v$V D=/var/lib/libvirt/images/destijl-$n-vm\$k-v$V"
}

if [ $DRY = 1 ]; then
  SCR=$(mktemp -d "${TMPDIR:-/tmp}/p-destijl-bundle-dry.XXXXXX"); trap 'rm -rf "$SCR"' EXIT
  for k in $VMS; do
    python3 -I "$SW/scripts/deploy/p-popcorn-xml.py" "${XS[$k]}" "/var/lib/libvirt/images/destijl-$n-vm$k-v$V" "$K" "$SCR/vm$k" > /dev/null
    cmp -s "$SCR/vm$k/rollback-inactive.xml" "${XS[$k]}" || stop "vm$k rollback XML != source"
    grep -q "<kernel>/var/lib/libvirt/images/destijl-$n-vm$k-v$V/bzImage</kernel>" "$SCR/vm$k/candidate-normal.xml" || stop "vm$k candidate kernel"
    echo "  vm$k: source ${XS[$k]} ($(sh_ "${XS[$k]}" | cut -c1-12)) -> candidate $(diff "${XS[$k]}" "$SCR/vm$k/candidate-normal.xml" | grep -c '^>') lines changed"
  done
  echo "rollback bundle $RB (packet $RB_PKT), PRE_K $PRE_K"
  echo "would run: ${PKG[*]}"
  [ -z "$GUEST_SRC" ] || echo "build $n rule: tools/p-destijl-guest.sh = $GUEST_SRC ($(sh_ "$GUEST_SRC" | cut -c1-12)), destijl.env + $ENV_EXTRA, KTREE $KTREE"
  [ -z "$REGION_SRC" ] || echo "build $n rule: tools/cxl_region.yaml = $REGION_SRC ($(sh_ "$REGION_SRC" | cut -c1-12)), destijl.env PARAMS* from it, staged module $KOVER with bpd_mode"
  denv
  echo "BUNDLE DRY PASS (topo $TOPO, deploy-v$V, nothing written under $B)"
  exit 0
fi

"${PKG[@]}"
# 4. post-checks + MANIFEST.txt + deploy-env.sh
(cd "$OUT" && sha256sum --quiet -c packet.sha256) || stop "$OUT fails its packet.sha256"
(cd "$OUT/tools" && sha256sum --quiet -c tools.sha256) || stop "$OUT/tools fails tools.sha256"
for f in "${SAME[@]}"; do
  cmp -s "$OUT/tools/$f" "$TOOLS_FROM/tools/$f" || stop "tools/$f differs from $TOOLS_FROM (guest dir $GT could not be reused)"
done
if [ -n "$GUEST_SRC" ]; then   # build 9 rule: own guest script, destijl.env = TOOLS_FROM's except K, KO_SHA + ENV_EXTRA
  cmp -s "$OUT/tools/p-destijl-guest.sh" "$GUEST_SRC" || stop "tools/p-destijl-guest.sh != $GUEST_SRC"
  XE='^(K|KO_SHA|LOAD_DEFAULTS)='; [ -z "$REGION_SRC" ] || XE='^(K|KO_SHA|LOAD_DEFAULTS|PARAMS|PARAMS_N[0-9])='
  diff -q <(grep -vE "$XE" "$OUT/tools/destijl.env") <(grep -vE "$XE" "$TOOLS_FROM/tools/destijl.env") > /dev/null ||
    stop "tools/destijl.env differs from $TOOLS_FROM beyond K / KO_SHA / LOAD_DEFAULTS${REGION_SRC:+ / PARAMS*}"
  if [ -n "$REGION_SRC" ]; then   # build 12: region, PARAMS from it, staged (signed) module 13.5 with bpd_mode
    cmp -s "$OUT/tools/cxl_region.yaml" "$REGION_SRC" || stop "tools/cxl_region.yaml != $REGION_SRC"
    grep -q '^PARAMS="protocol=destijl .*ring_offset=134217728 ring_size=134217728 ' "$OUT/tools/destijl.env" || stop "tools/destijl.env PARAMS are not from the flat region (ring 128 MiB at 128 MiB)"
    SKO=$B/stage/lib/modules/$K/updates/cxl_shm.ko
    [ "$(modinfo -F version "$SKO")" = "$KOVER" ] && modinfo -F parm "$SKO" | grep -q '^bpd_mode:' || stop "staged $SKO is not $KOVER with bpd_mode"
  fi
  grep -qx "K=$K" "$OUT/tools/destijl.env" || stop "tools/destijl.env K is not $K"
  grep -qxF "$ENV_EXTRA" "$OUT/tools/destijl.env" || stop "tools/destijl.env lacks $ENV_EXTRA"
  [ -z "$FIRST_TOOLS" ] || cmp -s "$OUT/tools/tools.sha256" "$FIRST_TOOLS" ||
    stop "tools/tools.sha256 differs from the first build-$n bundle ($FIRST_TOOLS): guest dir $GT could not be reused"
elif [ "$n" != 7 ]; then   # cross-build tools: destijl.env = TOOLS_FROM's except K and KO_SHA; K = this release
  diff -q <(grep -vE '^(K|KO_SHA)=' "$OUT/tools/destijl.env") <(grep -vE '^(K|KO_SHA)=' "$TOOLS_FROM/tools/destijl.env") > /dev/null ||
    stop "tools/destijl.env differs from $TOOLS_FROM beyond K / KO_SHA"
  grep -qx "K=$K" "$OUT/tools/destijl.env" || stop "tools/destijl.env K is not $K"
  [ -z "$FIRST_TOOLS" ] || cmp -s "$OUT/tools/tools.sha256" "$FIRST_TOOLS" ||
    stop "tools/tools.sha256 differs from the first build-$n bundle ($FIRST_TOOLS): guest dir $GT could not be reused"
fi
for k in $VMS; do cmp -s "$OUT/vm$k/rollback-inactive.xml" "${XS[$k]}" || stop "vm$k rollback XML != source"; done
PKT_SHA=$(sh_ "$OUT/packet.sha256")
denv "$PKT_SHA" > "$OUT/deploy-env.sh"
{
  echo "bundle: $OUT (De Stijl build $n, release $K; topology $TOPO, VMs $VMS)"
  echo "made_by: $SW/scripts/deploy/p-destijl-bundle.sh at CXL_SWMC $(git -C "$SW" rev-parse HEAD) (dirty files $DIRTY), $(date -Is)"
  echo "rollback_bundle: $RB packet.sha256 $RB_PKT release $PRE_K"
  echo "sha256:"
  echo "  $PKT_SHA  packet.sha256   (every file except modules.tar, MANIFEST.txt, deploy-env.sh)"
  echo "  $(sh_ "$OUT/modules.tar")  modules.tar"
  echo "  $(sh_ "$OUT/package-record.json")  package-record.json"
  if [ "$n" = 7 ]; then echo "  $(sh_ "$OUT/tools/tools.sha256")  tools/tools.sha256 (== $TOOLS_FROM/tools/tools.sha256)"
  elif [ -n "$GUEST_SRC" ]; then echo "  $(sh_ "$OUT/tools/tools.sha256")  tools/tools.sha256 (guest dir $GT; tools of $TOOLS_FROM, p-destijl-guest.sh = $GUEST_SRC, destijl.env K/KO_SHA + $ENV_EXTRA of build $n)"
  else echo "  $(sh_ "$OUT/tools/tools.sha256")  tools/tools.sha256 (guest dir $GT; tools of $TOOLS_FROM, destijl.env K/KO_SHA of build $n)"; fi
  echo "  $(sh_ "$OUT/deploy-env.sh")  deploy-env.sh"
  for k in $VMS; do echo "  $(sh_ "$OUT/vm$k/xml.sha256")  vm$k/xml.sha256 (rollback = ${XS[$k]})"; done
  echo "bzImage: $BZ $BZ_SHA"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
echo "BUNDLE PASS $OUT packet $PKT_SHA"
