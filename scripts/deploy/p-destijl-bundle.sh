#!/bin/bash
# Make the next De Stijl build-7 deploy bundle (builds/destijl/7/deploy-v<next>) on demand, for a deploy whose rollback
# target is a Popcorn bundle (default builds/popcorn_new/13/deploy-v1). Each De Stijl deploy needs its own bundle: the
# candidate XMLs fix the Host images dir /var/lib/libvirt/images/destijl-7-vm<k>-v<v> and p-destijl-deploy.sh install
# never overwrites an existing one (the guest rebuilds the initramfs on every prepare), and the bundle's rollback XML
# must equal the VM's current `virsh dumpxml --inactive`. Host-local only: no virsh, no ssh, no sudo.
#   p-destijl-bundle.sh [--dry-run] [--rollback <popcorn bundle dir>] [--topo 2|8] [--xml-src <dir>] [--version <v>]
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
B=$ROOT/builds/destijl/$n
KTREE=$ROOT/workspaces/destijl-v2/kernel
SOURCE_TAG=rel/destijl-6
FAULTLAT_BUILD=$ROOT/builds/faultlat/3
TOOLS_FROM=$B/deploy-v1
GT=/home/comsys/destijl-$n
DRY=0 TOPO=2 RB=$ROOT/builds/popcorn_new/13/deploy-v1 XSRC= V=
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1;;
    --rollback) RB=${2:?}; shift;;
    --topo) TOPO=${2:?}; shift;;
    --xml-src) XSRC=${2:?}; shift;;
    --version) V=${2:?}; shift;;
    *) sed -n '2,25p' "$0"; exit 2;;
  esac; shift
done
stop() { echo "BUNDLE STOP: $*"; exit 1; }
sh_() { sha256sum "$1" | cut -d' ' -f1; }
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

# 3. build 7 inputs (the same checks p-destijl-package.sh repeats, here so the dry run sees them)
M=$B/MANIFEST.txt
mf() { sed -n "s/^$1: \([^ ]*\).*/\1/p" "$M" | head -1; }
art() { awk -v f="$1" '$1 == f {print $2; exit}' "$M"; }
K=$(mf release); BZ=$B/arch/x86/boot/bzImage; BZ_SHA=$(art arch/x86/boot/bzImage)
[ "$K" = "6.14.0-famfs-de-stijl+-ds-destijl-$n" ] || stop "MANIFEST release '$K'"
[ "$(sh_ "$BZ")" = "$BZ_SHA" ] || stop "bzImage changed"
[ "$(sh_ "$B/.config")" = "$(mf config_sha256)" ] || stop ".config changed"
[ "$(sh_ "$B/cxl_shm/cxl_shm.ko")" = "$(art cxl_shm/cxl_shm.ko)" ] || stop "cxl_shm.ko changed"
test -f "$B/stage/lib/modules/$K/updates/cxl_shm.ko" || stop "no stage (packaging would compile/install modules)"
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
git -C "$SW" diff --quiet "$TC" -- systems/destijl/lib systems/common || stop "systems/destijl/lib or systems/common changed since $TC"
DIRTY=$(git -C "$SW" status --porcelain -- scripts/deploy workloads/faultlat systems/destijl systems/common config | wc -l)
[ "$DIRTY" = 0 ] || echo "NOTE: $DIRTY dirty files in $SW (recorded as cxl_swmc_dirty_files; commit before a real bundle)"

PKG=(env XML_SRC="$XSRC" VMS="$VMS" KTREE="$KTREE" SOURCE_TAG="$SOURCE_TAG" FAULTLAT_BUILD="$FAULTLAT_BUILD"
     TOOLS_FROM="$TOOLS_FROM" bash "$SW/scripts/ctl/build-wrap.sh" bash "$SW/scripts/deploy/p-destijl-package.sh" "$n" "$V")
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
  denv
  echo "BUNDLE DRY PASS (topo $TOPO, deploy-v$V, nothing written under $B)"
  exit 0
fi

"${PKG[@]}"
# 4. post-checks + MANIFEST.txt + deploy-env.sh
(cd "$OUT" && sha256sum --quiet -c packet.sha256) || stop "$OUT fails its packet.sha256"
(cd "$OUT/tools" && sha256sum --quiet -c tools.sha256) || stop "$OUT/tools fails tools.sha256"
for f in faultlat run.sh cxl_region.yaml p-destijl-guest.sh ds-replica-check.sh destijl.env de_stijl_test tools.sha256; do
  cmp -s "$OUT/tools/$f" "$TOOLS_FROM/tools/$f" || stop "tools/$f differs from $TOOLS_FROM (guest dir $GT could not be reused)"
done
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
  echo "  $(sh_ "$OUT/tools/tools.sha256")  tools/tools.sha256 (== $TOOLS_FROM/tools/tools.sha256)"
  echo "  $(sh_ "$OUT/deploy-env.sh")  deploy-env.sh"
  for k in $VMS; do echo "  $(sh_ "$OUT/vm$k/xml.sha256")  vm$k/xml.sha256 (rollback = ${XS[$k]})"; done
  echo "bzImage: $BZ $BZ_SHA"
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
echo "BUNDLE PASS $OUT packet $PKT_SHA"
