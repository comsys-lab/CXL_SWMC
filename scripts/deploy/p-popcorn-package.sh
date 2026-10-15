#!/bin/bash
# Package a built Popcorn kernel (tools/popcorn-build.sh <n>) for the
# P3c-pattern deployment. Host-local only (no guest, no VM change, no sudo).
#   [XML_SRC=<dir>] p-popcorn-package.sh <n> <bundle-version>
# XML_SRC: take each VM's rollback (= expected current inactive) XML from
#   <dir>/cxl_vm<k>/candidate-normal.xml (e.g. the vanilla bundle, when the
#   vanilla deployment precedes this one) instead of a fresh read-only
#   `virsh dumpxml --inactive`; precheck cmp checks it at execution time.
# Writes (all new; refuses if they exist):
#   builds/popcorn_new/<n>/stage/ (reused if present)  modules_install (kernel + cxl_shm in updates/),
#                                                      signed by the build's own key (kbuild), depmod -b
#   builds/popcorn_new/<n>/deploy-v<v>/
#     modules.tar, modules-manifest.json, kernel.config, prepare-guest.sh,
#     sanitize-initrd.py, verify-module-payload.py, verify-initrd.py,
#     preparation.sha256                               guest install bundle (generic l-vanilla scripts, copied)
#     tools/{faultlat,run.sh,cxl_region.yaml,p-popcorn-guest.sh,popcorn.env,tools.sha256}
#     vm0/, vm1/ {rollback-inactive.xml,candidate-*.xml,xml.sha256}   from the current inactive XMLs
#     p-popcorn-deploy.sh, p-popcorn-shm.sh, smoke.sh, vm-console.py, p-popcorn-xml.py
#     signatures.txt, package-record.json, packet.sha256
set -euo pipefail
umask 022
n=${1:?build number}; v=${2:?bundle version}
ROOT=/home/comsys/sungsu/destijl-control
SW=$ROOT/CXL_SWMC
SUB=$SW/kernels/popcorn_new
KS=$SUB/famfs-linux
B=$ROOT/builds/popcorn_new/$n
LV=-ds-popcorn-new-$n
OUT=$B/deploy-v$v
ST=$B/stage
DEP=$SW/scripts/deploy
WRAP="nice -n 19 numactl --cpunodebind=1 --membind=1"
SCR=${TMPDIR:-/tmp}/p-popcorn-package-$$

rec() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$B/build-record.json" "$1"; }
K=$(rec release); COMMIT=$(rec source_commit)
[ "$(rec dirty_files)" = 0 ] || { echo "build $n was made from a dirty tree"; exit 1; }
[ "$(git -C "$SUB" rev-parse "rel/popcorn-new-$n^{commit}")" = "$COMMIT" ] || { echo "tag rel/popcorn-new-$n != build commit"; exit 1; }
[ "$(sha256sum "$B/.config" | cut -d' ' -f1)" = "$(rec config_sha256)" ] || { echo ".config changed since the build"; exit 1; }
[ "$(sha256sum "$B/arch/x86/boot/bzImage" | cut -d' ' -f1)" = "$(rec bzImage_sha256)" ] || { echo "bzImage changed"; exit 1; }
[ "$($WRAP make -s -C "$KS" O="$B" LOCALVERSION="$LV" kernelrelease)" = "$K" ]
test ! -e "$OUT"
mkdir -p "$SCR"; trap 'rm -rf "$SCR"' EXIT

# 1. stage: kernel modules + cxl_shm (updates/), signed by kbuild with this build's key.
#    A stage from an earlier bundle of the same build is reused (every module is re-verified in step 2).
if [ -e "$ST" ]; then
  echo "reusing existing stage $ST"
else
  mkdir "$ST"
  $WRAP make -s -C "$KS" O="$B" LOCALVERSION="$LV" INSTALL_MOD_PATH="$ST" modules_install
  $WRAP make -s -C "$B" M="$SUB/msg_layer_module" MO="$B/cxl_shm" LOCALVERSION="$LV" \
    CONFIG_MODULE_SIG_KEY="$B/certs/signing_key.pem" INSTALL_MOD_PATH="$ST" modules_install
  depmod -b "$ST" -F "$B/System.map" "$K"
fi
MD=$ST/lib/modules/$K
test -f "$MD/updates/cxl_shm.ko"

# 2. bundle: modules.tar (dirs, *.ko, top-level modules.*; no build/source links) + manifest
mkdir "$OUT" "$OUT/tools" "$OUT/vm0" "$OUT/vm1"
(cd "$MD" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o \( -type d -o -type f \) -print |
  LC_ALL=C sort > "$SCR/members")
! grep -vE '\.ko$|^\./modules\.[^/]+$' <(cd "$MD" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o -type f -print) ||
  { echo "unexpected files in the stage"; exit 1; }
tar -C "$MD" --no-recursion --owner=0 --group=0 --numeric-owner --mtime=@0 -cf "$OUT/modules.tar" -T "$SCR/members"
cp "$B/.config" "$OUT/kernel.config"
python3 -I - "$MD" "$OUT" "$K" "$B/certs/signing_key.x509" "$SCR" <<'PY'
import hashlib, json, pathlib, subprocess, sys
md, out, release, cert, scr = map(pathlib.Path, sys.argv[1:6])
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
    mods[rel] = sha(ko)
assert 'updates/cxl_shm.ko' in mods and 'kernel/drivers/dax/device_dax.ko' in mods
fp = subprocess.run(['openssl', 'x509', '-in', pem, '-noout', '-fingerprint', '-sha256'], check=True,
                    capture_output=True, text=True).stdout.strip()
manifest = {'release': release, 'archive_sha256': sha(out / 'modules.tar'),
            'config_sha256': sha(out / 'kernel.config'), 'modules': mods}
(out / 'modules-manifest.json').write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')
(out / 'signatures.txt').write_text(f'{len(mods)} modules: signature trailer + openssl cms verify against '
                                    f'the build certificate ({fp}), vermagic {release}: PASS\n')
print(f'{len(mods)} modules signed and verified; cxl_shm {mods["updates/cxl_shm.ko"]}')
PY
cp "$DEP/l-vanilla-prepare-guest.sh" "$OUT/prepare-guest.sh"
cp "$DEP/l-vanilla-sanitize-initrd.py" "$OUT/sanitize-initrd.py"
cp "$DEP/l-vanilla-verify-module-payload.py" "$OUT/verify-module-payload.py"
cp "$DEP/l-vanilla-verify-initrd.py" "$OUT/verify-initrd.py"
(cd "$OUT" && sha256sum modules-manifest.json kernel.config prepare-guest.sh sanitize-initrd.py \
  verify-module-payload.py verify-initrd.py > preparation.sha256)
(cd "$OUT" && python3 -I verify-module-payload.py)

# 3. guest tools
bash "$SW/workloads/faultlat/setup.sh" "$SCR/fl" > /dev/null
cp "$SCR/fl/faultlat" "$SW/workloads/faultlat/run.sh" "$OUT/tools/"
cp "$SW/config/cxl_region.yaml" "$OUT/tools/cxl_region.yaml"
cp "$DEP/p-popcorn-guest.sh" "$OUT/tools/"
# base parameters (init_state=invalid); p-popcorn-guest.sh load substitutes the requested init_state
PARAMS=$("$OUT/tools/faultlat" params --config "$OUT/tools/cxl_region.yaml" --device-size 103060340736 --nodes 2 \
  --init-state invalid)
read -r MOFF MBYTES < <(sed -n 's/.*managed_offset=\([0-9]*\) managed_size=\([0-9]*\).*/\1 \2/p' <<<"$PARAMS")
cat > "$OUT/tools/popcorn.env" <<ENV
# Popcorn guest expectations (frozen with the packet; read by p-popcorn-guest.sh)
K=$K
KO_SHA=$(sha256sum "$MD/updates/cxl_shm.ko" | cut -d' ' -f1)
PARAMS="$PARAMS"
MANAGED_BASE_OFF=$MOFF
MANAGED_BYTES=$MBYTES
ENV
(cd "$OUT/tools" && sha256sum faultlat run.sh cxl_region.yaml p-popcorn-guest.sh popcorn.env > tools.sha256)

# 4. per-VM candidate XMLs from the current inactive definitions (read-only virsh)
for k in 0 1; do
  if [ -n "${XML_SRC:-}" ]; then
    cp "$XML_SRC/cxl_vm$k/candidate-normal.xml" "$SCR/vm$k.xml"
  else
    virsh -c qemu:///system dumpxml --inactive "cxl_vm$k" > "$SCR/vm$k.xml"
  fi
  rmdir "$OUT/vm$k"
  python3 -I "$DEP/p-popcorn-xml.py" "$SCR/vm$k.xml" "/var/lib/libvirt/images/popcorn-new-$n-vm$k-v$v" "$K" "$OUT/vm$k"
  (cd "$OUT/vm$k" && sha256sum rollback-inactive.xml candidate-normal.xml candidate-restricted.xml > xml.sha256)
done

# 5. scripts and record
cp "$DEP/p-popcorn-deploy.sh" "$DEP/p-popcorn-shm.sh" "$DEP/vm-console.py" "$DEP/p-popcorn-xml.py" \
  "$SW/workloads/faultlat/smoke.sh" "$OUT/"
cat > "$OUT/package-record.json" <<JSON
{
  "build": "$n", "release": "$K", "source_commit": "$COMMIT", "tag": "rel/popcorn-new-$n",
  "config_sha256": "$(rec config_sha256)", "bzImage": "$B/arch/x86/boot/bzImage",
  "bzImage_sha256": "$(rec bzImage_sha256)",
  "modules_staged": $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["modules"]))' "$OUT/modules-manifest.json"),
  "cxl_shm_ko_sha256": "$(sha256sum "$MD/updates/cxl_shm.ko" | cut -d' ' -f1)",
  "cxl_swmc_commit": "$(git -C "$SW" rev-parse HEAD)", "cxl_swmc_dirty_files": $(git -C "$SW" status --porcelain -- scripts/deploy workloads/faultlat config | wc -l),
  "faultlat_sha256": "$(sha256sum "$OUT/tools/faultlat" | cut -d' ' -f1)",
  "cxl_shm_params": "$PARAMS",
  "xml_source": "${XML_SRC:-virsh dumpxml --inactive (read-only, at packaging)}",
  "created": "$(date -Is)"
}
JSON
(cd "$OUT" && find . -type f ! -name packet.sha256 ! -name modules.tar -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > packet.sha256)
cat "$OUT/package-record.json"
