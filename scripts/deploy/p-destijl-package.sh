#!/bin/bash
# Package a built De Stijl v2 kernel (builds/destijl/<n>, LOCALVERSION -ds-destijl-<n>) for the same direct-boot
# deployment as Popcorn build 12 (p-popcorn-package.sh / p-popcorn-deploy.sh, P3c pattern). Host-local only (no guest,
# no VM change, no sudo, no virsh: the rollback XMLs come from a frozen bundle, checked again by the deploy precheck).
#   [XML_SRC=<dir>] [KTREE=<kernel worktree>] [EQUIV_COMMIT=<commit>] [FAULTLAT_BUILD=<builds/faultlat/<m>>] \
#     p-destijl-package.sh <n> <bundle-version>
# FAULTLAT_BUILD: take faultlat from that frozen build (its build-record.json faultlat_sha256 must match) instead of
#   building it here with workloads/faultlat/setup.sh.
# TOOLS_FROM=<builds/destijl/<n>/deploy-v<w>>: the guest tools must be byte-identical to that bundle's (de_stijl_test,
#   whose binary embeds its build path, is copied from it if systems/destijl/lib + systems/common are unchanged since
#   its cxl_swmc_commit), so an existing guest tools dir of that bundle is reused by p-destijl-deploy.sh.
#   TOOLS_FROM of ANOTHER build (build 8 from builds/destijl/7/deploy-v1): the same, except destijl.env, whose K and
#   KO_SHA are this build's (all other lines identical) -> new tools.sha256, new guest tools dir (p-destijl-bundle.sh).
# Inputs (builds/destijl/<n>):  MANIFEST.txt (release, source_commit, dirty_sha256, config_sha256, artifact sha256s),
#   .config, arch/x86/boot/bzImage, System.map, certs/, cxl_shm/cxl_shm.ko (cxl_shm v13, M=<KTREE>/msg_layer_module).
# Source identity: a build from a dirty tree (MANIFEST dirty_sha256) is accepted only if EQUIV_COMMIT reproduces the
#   dirty hash: sha256(`git diff <source_commit> <EQUIV_COMMIT> -- famfs-linux` without the files the MANIFEST lists as
#   untracked, then `git show <EQUIV_COMMIT>:<file>` of those files) == dirty_sha256 (same recipe as MANIFEST.txt), and
#   msg_layer_module is unchanged between both commits and clean in KTREE. Clean builds need the tag rel/destijl-<n>,
#   or SOURCE_TAG=<tag> for a rebuild of a tagged commit under a new release (e.g. build 7 = SOURCE_TAG=rel/destijl-6).
# XML_SRC: directory with vm<k>/candidate-normal.xml, cxl_vm<k>/candidate-normal.xml or cxl_vm<k>.after-define.xml
#   (vmN chain topo<N>/ output) = the CURRENT inactive XML of cxl_vm<k> (default builds/popcorn_new/12/deploy-v1). The
#   rollback XML of this bundle is that file; p-destijl-deploy.sh precheck refuses unless `virsh dumpxml --inactive`
#   equals it byte for byte (so never a generator-formatted topo<N>/cxl_vm<k>.xml).
# VMS="0 1" (default) or e.g. "0 1 2 3 4 5 6 7": the VM ids that get a vm<k>/ deploy dir (VM8 topology: cxl_vm0..7).
# MEASUREMENT.lock: tolerated when nothing is compiled (stage/ exists, FAULTLAT_BUILD and TOOLS_FROM set); the rest
#   (make kernelrelease, tar, signature checks) runs under scripts/ctl/build-wrap.sh (node 1 / session CPUs).
# Writes (all new; refuses if deploy-v<v> exists):
#   builds/destijl/<n>/stage/ (reused if present)   modules_install (kernel + cxl_shm in updates/), signed by kbuild with
#                                                   the build's own key, depmod -b
#   builds/destijl/<n>/deploy-v<v>/
#     modules.tar, modules-manifest.json, kernel.config, prepare-guest.sh, sanitize-initrd.py, verify-module-payload.py,
#     verify-initrd.py, verify-installed-modules.py, preparation.sha256
#                                                   guest install set (l-vanilla scripts; prepare-guest.sh and
#                                                   verify-installed-modules.py = ds-* copies that also accept an
#                                                   installed /lib/modules/<K> identical to this bundle)
#     tools/{faultlat,run.sh,cxl_region.yaml,p-destijl-guest.sh,ds-replica-check.sh,destijl.env,de_stijl_test,tools.sha256}
#                                                                 guest tools (GT; ds-replica-check.sh from phase 5d on)
#     vm<k>/ (k in VMS) {rollback-inactive.xml,candidate-normal.xml,candidate-restricted.xml,xml.sha256}
#     p-destijl-deploy.sh, p-destijl-shm.sh, smoke.sh, smoke-n.sh, scenarios.sh, parse.py, vm-console.py, p-popcorn-xml.py
#     params-layout.txt, signatures.txt, package-record.json, packet.sha256
#   destijl.env: K, KO_SHA (signed, installed cxl_shm.ko), PARAMS (= PARAMS_N2), PARAMS_N2..PARAMS_N8 (`faultlat params
#   --protocol destijl --nodes N --init-state invalid` for config/cxl_region-destijl.yaml), MANAGED_BASE_OFF, MANAGED_BYTES.
set -euo pipefail
umask 022
n=${1:?build number}; v=${2:?bundle version}
[[ "$n" =~ ^[0-9]+$ && "$v" =~ ^[0-9]+$ ]] || { echo "build number and bundle version must be integers"; exit 2; }
ROOT=/home/comsys/sungsu/destijl-control
SW=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)    # the harness tree this script is in
KTREE=${KTREE:-$ROOT/workspaces/destijl-v2/kernel}
KS=$KTREE/famfs-linux
B=$ROOT/builds/destijl/$n
LV=-ds-destijl-$n
OUT=$B/deploy-v$v
ST=$B/stage
DEP=$SW/scripts/deploy
REG=$SW/config/cxl_region-destijl.yaml
XML_SRC=${XML_SRC:-$ROOT/builds/popcorn_new/12/deploy-v1}
DEV_SIZE=103060340736   # observed /sys/bus/dax/devices/dax0.0/size on the guests
WRAP="bash $SW/scripts/ctl/build-wrap.sh"   # node 1, or the session CPUs while MEASUREMENT.lock exists
SCR=${TMPDIR:-/tmp}/p-destijl-package-$$
VMS=${VMS:-0 1}
read -r -a VML <<< "$VMS"
[ ${#VML[@]} -ge 1 ] || { echo "VMS is empty"; exit 2; }
for k in "${VML[@]}"; do [[ "$k" =~ ^[0-7]$ ]] || { echo "VMS: bad VM id '$k'"; exit 2; }; done
[ "$(printf '%s\n' "${VML[@]}" | sort -u | wc -l)" = ${#VML[@]} ] || { echo "VMS has duplicates"; exit 2; }

if [ -e "$ROOT/workspaces/MEASUREMENT.lock" ]; then   # packaging only, nothing compiled
  [ -e "$ST" ] && [ -n "${FAULTLAT_BUILD:-}" ] && [ -n "${TOOLS_FROM:-}" ] ||
    { echo "STOP: workspaces/MEASUREMENT.lock exists and this run would compile (needs stage/, FAULTLAT_BUILD, TOOLS_FROM)"; exit 1; }
fi
test ! -e "$OUT" || { echo "STOP: $OUT exists"; exit 1; }
M=$B/MANIFEST.txt
mf() { sed -n "s/^$1: \([^ ]*\).*/\1/p" "$M" | head -1; }
art() { awk -v f="$1" '$1 == f {print $2; exit}' "$M"; }
K=$(mf release); COMMIT=$(mf source_commit); DIRTY=$(mf dirty_sha256); CSHA=$(mf config_sha256)
BZ_SHA=$(art arch/x86/boot/bzImage); KO_BUILD_SHA=$(art cxl_shm/cxl_shm.ko)
[ "$K" = "6.14.0-famfs-de-stijl+$LV" ] || { echo "STOP: MANIFEST release '$K' is not 6.14.0-famfs-de-stijl+$LV"; exit 1; }
for x in COMMIT CSHA BZ_SHA KO_BUILD_SHA; do [ -n "${!x}" ] || { echo "STOP: MANIFEST lacks $x"; exit 1; }; done
[ "$(sha256sum "$B/.config" | cut -d' ' -f1)" = "$CSHA" ] || { echo "STOP: .config changed since the build"; exit 1; }
[ "$(sha256sum "$B/arch/x86/boot/bzImage" | cut -d' ' -f1)" = "$BZ_SHA" ] || { echo "STOP: bzImage changed"; exit 1; }
[ "$(sha256sum "$B/cxl_shm/cxl_shm.ko" | cut -d' ' -f1)" = "$KO_BUILD_SHA" ] || { echo "STOP: cxl_shm.ko changed"; exit 1; }
grep -qx 'CONFIG_SWMC_DE_STIJL=y' "$B/.config" && grep -qx 'CONFIG_MODULE_SIG_ALL=y' "$B/.config" ||
  { echo "STOP: .config lacks CONFIG_SWMC_DE_STIJL=y or CONFIG_MODULE_SIG_ALL=y"; exit 1; }

# source identity
if [ -n "$DIRTY" ]; then
  : "${EQUIV_COMMIT:?build $n is from a dirty tree: set EQUIV_COMMIT to the commit that holds exactly that diff}"
  EQ=$(git -C "$KTREE" rev-parse "$EQUIV_COMMIT^{commit}")
  read -r -a UNTR <<< "$(sed -n '/^dirty_sha256/,/^base_config/p' "$M" | grep -oE '[A-Za-z0-9_./-]+\.[ch]\b' | tr '\n' ' ')"
  [ ${#UNTR[@]} -gt 0 ] || { echo "STOP: MANIFEST names no untracked files for dirty_sha256"; exit 1; }
  EX=(); for f in "${UNTR[@]}"; do EX+=(":(exclude)famfs-linux/$f"); done
  got=$( (git -C "$KTREE" diff "$COMMIT" "$EQ" -- famfs-linux "${EX[@]}"
          for f in "${UNTR[@]}"; do git -C "$KTREE" show "$EQ:famfs-linux/$f"; done) | sha256sum | cut -d' ' -f1)
  [ "$got" = "$DIRTY" ] || { echo "STOP: $EQ does not reproduce dirty_sha256 ($got != $DIRTY)"; exit 1; }
  SRC_ID="$COMMIT + dirty $DIRTY == $EQ"
else
  TAG=${SOURCE_TAG:-rel/destijl-$n}
  EQ=$(git -C "$KTREE" rev-parse "$TAG^{commit}")
  [ "$EQ" = "$(git -C "$KTREE" rev-parse "$COMMIT^{commit}")" ] || { echo "STOP: tag $TAG != build commit"; exit 1; }
  SRC_ID="$COMMIT (tag $TAG)"
fi
git -C "$KTREE" diff --quiet "$COMMIT" "$EQ" -- msg_layer_module || { echo "STOP: msg_layer_module differs between $COMMIT and $EQ"; exit 1; }
git -C "$KTREE" diff --quiet "$EQ" -- msg_layer_module && [ -z "$(git -C "$KTREE" status --porcelain -- msg_layer_module)" ] ||
  { echo "STOP: $KTREE/msg_layer_module is not clean at $EQ (modules_install M= reads it)"; exit 1; }
[ "$($WRAP make -s -C "$KS" O="$B" LOCALVERSION="$LV" kernelrelease)" = "$K" ] || { echo "STOP: kernelrelease differs"; exit 1; }
for k in "${VML[@]}"; do
  XS[$k]=
  for f in "$XML_SRC/vm$k/candidate-normal.xml" "$XML_SRC/cxl_vm$k/candidate-normal.xml" "$XML_SRC/cxl_vm$k.after-define.xml"; do
    [ -f "$f" ] && { XS[$k]=$f; break; }
  done
  [ -n "${XS[$k]}" ] || { echo "STOP: no candidate-normal.xml / cxl_vm$k.after-define.xml for vm$k in $XML_SRC"; exit 1; }
  grep -q "<name>cxl_vm$k</name>" "${XS[$k]}" || { echo "STOP: ${XS[$k]} is not cxl_vm$k"; exit 1; }
done
mkdir -p "$SCR"; trap 'rm -rf "$SCR"' EXIT

# 1. stage: kernel modules + cxl_shm (updates/), signed by kbuild (modules_install) with this build's key; the bundle
#    records the signed cxl_shm.ko sha256 (KO_SHA, checked on the guest) next to the unsigned build-output sha256.
if [ -e "$ST" ]; then
  echo "reusing existing stage $ST"
else
  mkdir "$ST"
  $WRAP make -s -C "$KS" O="$B" LOCALVERSION="$LV" INSTALL_MOD_PATH="$ST" modules_install
  $WRAP make -s -C "$B" M="$KTREE/msg_layer_module" MO="$B/cxl_shm" LOCALVERSION="$LV" \
    CONFIG_MODULE_SIG_KEY="$B/certs/signing_key.pem" INSTALL_MOD_PATH="$ST" modules_install
  depmod -b "$ST" -F "$B/System.map" "$K"
fi
MD=$ST/lib/modules/$K
test -f "$MD/updates/cxl_shm.ko"

# 2. bundle: modules.tar (dirs, *.ko, top-level modules.*; no build/source links) + manifest + signature check
mkdir "$OUT" "$OUT/tools"
(cd "$MD" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o \( -type d -o -type f \) -print |
  LC_ALL=C sort > "$SCR/members")
! grep -vE '\.ko$|^\./modules\.[^/]+$' <(cd "$MD" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o -type f -print) ||
  { echo "unexpected files in the stage"; exit 1; }
tar -C "$MD" --no-recursion --owner=0 --group=0 --numeric-owner --mtime=@0 -cf "$OUT/modules.tar" -T "$SCR/members"
cp "$B/.config" "$OUT/kernel.config"
python3 -I - "$MD" "$OUT" "$K" "$B/certs/signing_key.x509" "$SCR" "$B/cxl_shm/cxl_shm.ko" <<'PY'
import hashlib, json, pathlib, subprocess, sys
md, out, release, cert, scr, built_ko = map(pathlib.Path, sys.argv[1:7])
release = str(release)
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()
magic = b'~Module signature appended~\n'
pem = scr / 'cert.pem'
subprocess.run(['openssl', 'x509', '-inform', 'DER', '-in', cert, '-out', pem], check=True)
mods, lines = {}, []
for ko in sorted(md.rglob('*.ko')):
    rel = str(ko.relative_to(md))
    data = ko.read_bytes()
    assert data.endswith(magic), f'unsigned: {rel}'
    trailer = data[-len(magic) - 12:-len(magic)]
    n = int.from_bytes(trailer[8:12], 'big')
    assert trailer[2] == 2 and 0 < n < len(data), f'bad signature trailer: {rel}'
    (scr / 'u').write_bytes(data[:-len(magic) - 12 - n])
    (scr / 's').write_bytes(data[-len(magic) - 12 - n:-len(magic) - 12])
    subprocess.run(['openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', scr / 's', '-content', scr / 'u',
                    '-certfile', pem, '-nointern', '-noverify', '-out', '/dev/null'], check=True,
                   stderr=subprocess.DEVNULL)
    vm = subprocess.run(['modinfo', '-F', 'vermagic', ko], check=True, capture_output=True, text=True).stdout.split()[0]
    assert vm == release, f'vermagic {vm}: {rel}'
    if rel == 'updates/cxl_shm.ko':   # installed payload = the build output (modules_install only signs)
        assert data[:-len(magic) - 12 - n] == built_ko.read_bytes(), 'updates/cxl_shm.ko payload != build output'
    mods[rel] = sha(ko)
assert 'updates/cxl_shm.ko' in mods and 'kernel/drivers/dax/device_dax.ko' in mods
fp = subprocess.run(['openssl', 'x509', '-in', pem, '-noout', '-fingerprint', '-sha256'], check=True,
                    capture_output=True, text=True).stdout.strip()
manifest = {'release': release, 'archive_sha256': sha(out / 'modules.tar'),
            'config_sha256': sha(out / 'kernel.config'), 'modules': mods}
(out / 'modules-manifest.json').write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')
(out / 'signatures.txt').write_text(f'{len(mods)} modules: signature trailer + openssl cms verify against '
                                    f'the build certificate ({fp}), vermagic {release}: PASS; '
                                    f'updates/cxl_shm.ko payload == build output\n')
print(f'{len(mods)} modules signed and verified; cxl_shm {mods["updates/cxl_shm.ko"]}')
PY
cp "$DEP/ds-prepare-guest.sh" "$OUT/prepare-guest.sh"   # l-vanilla copy + re-deploy of an installed release
cp "$DEP/ds-verify-installed-modules.py" "$OUT/verify-installed-modules.py"
cp "$DEP/l-vanilla-sanitize-initrd.py" "$OUT/sanitize-initrd.py"
cp "$DEP/l-vanilla-verify-module-payload.py" "$OUT/verify-module-payload.py"
cp "$DEP/l-vanilla-verify-initrd.py" "$OUT/verify-initrd.py"
(cd "$OUT" && sha256sum modules-manifest.json kernel.config prepare-guest.sh sanitize-initrd.py \
  verify-module-payload.py verify-initrd.py verify-installed-modules.py > preparation.sha256)
(cd "$OUT" && python3 -I verify-module-payload.py)

# 3. guest tools: faultlat (faultlat-6, built from this tree), libdestijl test, region config, guest script, destijl.env
if [ -n "${FAULTLAT_BUILD:-}" ]; then
  want=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["faultlat_sha256"])' "$FAULTLAT_BUILD/build-record.json")
  [ "$(sha256sum "$FAULTLAT_BUILD/faultlat" | cut -d' ' -f1)" = "$want" ] ||
    { echo "STOP: $FAULTLAT_BUILD/faultlat != its build-record.json faultlat_sha256"; exit 1; }
  mkdir -p "$SCR/fl"; cp "$FAULTLAT_BUILD/faultlat" "$SCR/fl/faultlat"
else
  bash "$SW/workloads/faultlat/setup.sh" "$SCR/fl" > /dev/null
fi
mkdir -p "$SCR/t/systems/destijl" "$SCR/t/systems/common"
cp -r "$SW/systems/destijl/lib" "$SCR/t/systems/destijl/lib"
cp "$SW/systems/common/"*.h "$SCR/t/systems/common/"
if [ -z "${TOOLS_FROM:-}" ]; then   # with TOOLS_FROM the earlier de_stijl_test is copied below (nothing compiled)
  make -s -C "$SCR/t/systems/destijl/lib" clean > /dev/null
  make -s -C "$SCR/t/systems/destijl/lib" de_stijl_test > /dev/null
  cp "$SCR/t/systems/destijl/lib/de_stijl_test" "$OUT/tools/"
fi
cp "$SCR/fl/faultlat" "$SW/workloads/faultlat/run.sh" "$OUT/tools/"
cp "$REG" "$OUT/tools/cxl_region.yaml"
cp "$DEP/p-destijl-guest.sh" "$DEP/ds-replica-check.sh" "$OUT/tools/"   # replica check: p-destijl-guest.sh replica-check
FL=$OUT/tools/faultlat
grep -aq 'faultlat-6' "$FL" || { echo "STOP: faultlat is not faultlat-6 (no --protocol destijl)"; exit 1; }
par() { "$FL" params --protocol destijl --config "$OUT/tools/cxl_region.yaml" --device-size $DEV_SIZE --nodes "$1" \
          --init-state invalid; }
PARAMS=$(par 2)
[[ "$PARAMS" == "protocol=destijl "*" init_state=invalid" ]] || { echo "STOP: unexpected params '$PARAMS'"; exit 1; }
read -r MOFF MBYTES < <(sed -n 's/.*managed_offset=\([0-9]*\) managed_size=\([0-9]*\).*/\1 \2/p' <<<"$PARAMS")
read -r ROFF RSIZE < <(sed -n 's/.*ring_offset=\([0-9]*\) ring_size=\([0-9]*\).*/\1 \2/p' <<<"$PARAMS")
KO_SHA=$(sha256sum "$MD/updates/cxl_shm.ko" | cut -d' ' -f1)
{
  echo "# De Stijl v2 guest expectations (frozen with the packet; read by p-destijl-guest.sh)"
  echo "K=$K"
  echo "KO_SHA=$KO_SHA"
  echo "PARAMS=\"$PARAMS\""
  for m in 2 3 4 5 6 7 8; do echo "PARAMS_N$m=\"$(par $m)\""; done
  echo "MANAGED_BASE_OFF=$MOFF"
  echo "MANAGED_BYTES=$MBYTES"
} > "$OUT/tools/destijl.env"
for m in 2 3 4 5 6 7 8; do echo "N=$m $(par $m)"; done > "$OUT/params-layout.txt"
if [ -n "${TOOLS_FROM:-}" ]; then   # re-package with the guest tools of an earlier bundle of the same build (byte-identical)
  TR=$TOOLS_FROM/package-record.json
  (cd "$TOOLS_FROM/tools" && sha256sum --quiet -c tools.sha256) || { echo "STOP: $TOOLS_FROM/tools fails its tools.sha256"; exit 1; }
  for f in faultlat run.sh cxl_region.yaml p-destijl-guest.sh ds-replica-check.sh; do
    cmp -s "$OUT/tools/$f" "$TOOLS_FROM/tools/$f" || { echo "STOP: tools/$f differs from $TOOLS_FROM"; exit 1; }
  done
  if [ "$(readlink -f "$(dirname "$TOOLS_FROM")")" = "$(readlink -f "$B")" ]; then   # same build: destijl.env identical
    cmp -s "$OUT/tools/destijl.env" "$TOOLS_FROM/tools/destijl.env" || { echo "STOP: tools/destijl.env differs from $TOOLS_FROM"; exit 1; }
  else   # another build's tools (e.g. build 8 from build 7): K and KO_SHA are this build's, everything else identical
    diff -q <(grep -vE '^(K|KO_SHA)=' "$OUT/tools/destijl.env") <(grep -vE '^(K|KO_SHA)=' "$TOOLS_FROM/tools/destijl.env") > /dev/null ||
      { echo "STOP: tools/destijl.env differs from $TOOLS_FROM beyond K / KO_SHA"; exit 1; }
    XB=" (other build: destijl.env K/KO_SHA of build $n)"
  fi
  TC=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["cxl_swmc_dirty_files"]==0; print(r["cxl_swmc_commit"])' "$TR") ||
    { echo "STOP: $TR has no clean cxl_swmc_commit"; exit 1; }
  # de_stijl_test embeds its build path (not reproducible): reuse the earlier binary if its sources are unchanged
  git -C "$SW" diff --quiet "$TC" -- systems/destijl/lib systems/common &&
    [ -z "$(git -C "$SW" status --porcelain -- systems/destijl/lib systems/common)" ] ||
    { echo "STOP: systems/destijl/lib or systems/common changed since $TC ($TOOLS_FROM)"; exit 1; }
  cp "$TOOLS_FROM/tools/de_stijl_test" "$OUT/tools/de_stijl_test"
  TOOLS_SRC="tools byte-identical to $TOOLS_FROM${XB:-} (de_stijl_test copied; sources unchanged since $TC)"
fi
(cd "$OUT/tools" && sha256sum faultlat run.sh cxl_region.yaml p-destijl-guest.sh ds-replica-check.sh destijl.env de_stijl_test > tools.sha256)

# 4. per-VM candidate XMLs (direct boot from /var/lib/libvirt/images/destijl-<n>-vm<k>-v<v>)
for k in "${VML[@]}"; do
  python3 -I "$DEP/p-popcorn-xml.py" "${XS[$k]}" "/var/lib/libvirt/images/destijl-$n-vm$k-v$v" "$K" "$OUT/vm$k"
  (cd "$OUT/vm$k" && sha256sum rollback-inactive.xml candidate-normal.xml candidate-restricted.xml > xml.sha256)
done

# 5. scripts and record
cp "$DEP/p-destijl-deploy.sh" "$DEP/p-destijl-shm.sh" "$DEP/vm-console.py" "$DEP/p-popcorn-xml.py" \
  "$SW/workloads/faultlat/smoke.sh" "$SW/workloads/faultlat/smoke-n.sh" "$SW/workloads/faultlat/scenarios.sh" \
  "$SW/workloads/faultlat/parse.py" "$OUT/"
sh_() { sha256sum "$1" | cut -d' ' -f1; }
cat > "$OUT/package-record.json" <<JSON
{
  "build": "$n", "release": "$K", "source_commit": "$COMMIT", "dirty_sha256": "$DIRTY",
  "equivalent_commit": "$EQ", "source_identity": "$SRC_ID", "kernel_tree": "$KTREE",
  "config_sha256": "$CSHA", "bzImage": "$B/arch/x86/boot/bzImage", "bzImage_sha256": "$BZ_SHA",
  "modules_staged": $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["modules"]))' "$OUT/modules-manifest.json"),
  "modules_tar_sha256": "$(sh_ "$OUT/modules.tar")",
  "cxl_shm_ko_sha256": "$KO_SHA",
  "cxl_shm_ko_signed": "$(tail -c 28 "$MD/updates/cxl_shm.ko" | grep -q 'Module signature appended' && echo yes || echo no)",
  "cxl_shm_ko_build_output_sha256": "$KO_BUILD_SHA",
  "cxl_swmc_commit": "$(git -C "$SW" rev-parse HEAD)",
  "cxl_swmc_dirty_files": $(git -C "$SW" status --porcelain -- scripts/deploy workloads/faultlat systems/destijl systems/common config | wc -l),
  "faultlat_sha256": "$(sh_ "$FL")",
  "faultlat_version": "$(grep -aoE 'faultlat-[0-9]+' "$FL" | sort -u | tail -1)",
  "faultlat_source": "${FAULTLAT_BUILD:-built here by workloads/faultlat/setup.sh}",
  "de_stijl_test_sha256": "$(sh_ "$OUT/tools/de_stijl_test")",
  "tools_source": "${TOOLS_SRC:-built here}",
  "region_config": "$REG", "region_sha256": "$(sh_ "$REG")", "ring_offset": $ROFF, "ring_size": $RSIZE,
  "cxl_shm_params": "$PARAMS",
  "vms": "${VML[*]}",
  "xml_source": "$(for k in "${VML[@]}"; do printf '%s ' "${XS[$k]}"; done | sed 's/ $//')",
  "xml_source_sha256": "$(for k in "${VML[@]}"; do printf '%s ' "$(sh_ "${XS[$k]}")"; done | sed 's/ $//')",
  "images_dirs": "$(for k in "${VML[@]}"; do printf '/var/lib/libvirt/images/destijl-%s-vm%s-v%s ' "$n" "$k" "$v"; done | sed 's/ $//')",
  "created": "$(date -Is)"
}
JSON
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT/package-record.json"
(cd "$OUT" && find . -type f ! -name packet.sha256 ! -name modules.tar -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > packet.sha256)
cat "$OUT/package-record.json" "$OUT/tools/destijl.env"
echo "bundle $OUT: packet.sha256 $(sh_ "$OUT/packet.sha256") tools.sha256 $(sh_ "$OUT/tools/tools.sha256")"
