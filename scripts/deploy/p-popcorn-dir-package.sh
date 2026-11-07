#!/bin/bash
# Package Popcorn build 14 (kernel builds/popcorn_new/14, module builds/popcorn_new/14-dir = cxl_shm 14.0-dir with
# directory=none|flat; worktree workspaces/popcorn-directory/src, tag rel/popcorn-new-14) as a direct-boot deploy bundle
# for the 2-VM or the topo-8 layout (experiment popcorn-directory-reference). Host-local only: no virsh, no ssh, no
# sudo, no VM. Pattern: workspaces/popcorn-b13/package13.sh (build 13 deploy-v2) + the directory rule.
#   [DRY=1] p-popcorn-dir-package.sh --topo 2|8 [--xml-src <dir with cxl_vm<k>.after-define.xml>] [--version <v>]
# --topo 2: vm0 / vm1 rollback XML = builds/popcorn_new/13/deploy-v2/vm<k>/candidate-normal.xml (the definitions the
#   2-VM Popcorn 13 VMs run; p-popcorn-deploy.sh precheck compares them with the live inactive XML).
# --topo 8: vm0..vm7 rollback XML = <xml-src>/cxl_vm<k>.after-define.xml (the VM8 switch's definitions; required).
# Writes (refuses if deploy-v<V> exists; default V = next free):
#   builds/popcorn_new/14-dir/stage/  (first real run only; reused afterwards, every module re-verified)
#       modules_install of kernel 14 (O=builds/popcorn_new/14) + cxl_shm 14.0-dir (M=<src>/msg_layer_module,
#       MO=builds/popcorn_new/14-dir) into updates/, signed by kbuild with the build's own key
#       (CONFIG_MODULE_SIG_KEY=builds/popcorn_new/14/certs/signing_key.pem: this script never reads key material), depmod -b.
#       Refused while workspaces/MEASUREMENT.lock exists (the stage step compiles nothing but runs make).
#   builds/popcorn_new/14-dir/deploy-v<V>/
#     modules.tar modules-manifest.json kernel.config prepare-guest.sh sanitize-initrd.py verify-module-payload.py
#     verify-initrd.py verify-installed-modules.py preparation.sha256
#                                                  guest install set (l-vanilla scripts as build 13, except prepare-guest.sh
#                                                  and verify-installed-modules.py = the ds-* copies that also accept an
#                                                  installed, verified /lib/modules/<K14>: cxl_vm0's disk keeps it after
#                                                  N = 2 and every VM8 overlay inherits it; C2 2026-11-07)
#     tools/{faultlat,run.sh,cxl_region.yaml,p-popcorn-guest.sh,popcorn.env,tools.sha256}
#       faultlat + run.sh = builds/popcorn_new/13/deploy-v2/tools (byte-identical); cxl_region.yaml =
#       config/cxl_region-popcorn-dir.yaml; p-popcorn-guest.sh = scripts/deploy/p-popcorn-guest-dir.sh; popcorn.env:
#       K, KO_SHA (signed module), KO_VERSION=14.0-dir, PARAMS / PARAMS_N2..8 (ring = the LAST 2 MiB of the region's
#       msg_ring, asserted == the run-2 Popcorn 13 bundle's PARAMS*), MANAGED_*, DIR_OFFSET, DIR_BYTES,
#       LOAD_DEFAULTS="directory=flat dir_offset=<DIR_OFFSET>"
#     vm<k>/{rollback-inactive.xml,candidate-normal.xml,candidate-restricted.xml,xml.sha256}  (images
#       /var/lib/libvirt/images/popcorn-14-vm<k>-v<V>)
#     p-popcorn-deploy.sh (= scripts/deploy/p-popcorn-deploy-dir.sh: re-run rules), p-popcorn-shm.sh (= scripts/deploy/p-popcorn-shm-dir.sh), smoke.sh, smoke-n.sh,
#     vm-console.py, p-popcorn-xml.py, params-layout.txt, deploy-env.sh, signatures.txt, package-record.json, packet.sha256
# Output line: "BUNDLE PASS <dir> packet <sha256>" / "BUNDLE DRY PASS (topo T, deploy-vV, nothing written ...)".
set -euo pipefail
umask 022
TOPO= XSRC= V=
while [ $# -gt 0 ]; do
  case $1 in --topo) TOPO=${2:-}; shift 2;; --xml-src) XSRC=${2:-}; shift 2;; --version) V=${2:-}; shift 2;;
    *) echo "usage: [DRY=1] $0 --topo 2|8 [--xml-src <dir>] [--version <v>]"; exit 2;; esac
done
DRY=${DRY:-0}
ROOT=/home/comsys/sungsu/destijl-control
SW=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)   # the CXL_SWMC tree this script is in
DEP=$SW/scripts/deploy
KTREE=$ROOT/workspaces/popcorn-directory/src KS=$KTREE/famfs-linux
B=$ROOT/builds/popcorn_new/14 MB=$ROOT/builds/popcorn_new/14-dir
ST=$MB/stage LV=-ds-popcorn-new-14 TAG=rel/popcorn-new-14 KOV=14.0-dir
B13=$ROOT/builds/popcorn_new/13/deploy-v2 B13_PKT=60baa46ba48b5e0d7dab2dd0c3c43f51cd52c60e9ac3be6e1332237db7eb2dec
R2=$ROOT/builds/popcorn_new/13-recv2/deploy-v1 R2_PKT=a614f5ce9e7953d3444ee90b9d26a682f4a6d7d2132d4067b03490932b10389b
REG=$SW/config/cxl_region-popcorn-dir.yaml REG_SHA=939fbba5bfce9aa41b099f6a50e71ec2becb75b8a08f8ff4ac41bfa271628880
RING_SIZE=2097152   # the run-2 Popcorn ring (config/cxl_region-ring2m.yaml)
DEV_SIZE=103060340736
MK=(bash "$SW/scripts/ctl/build-wrap.sh" make)
stop() { echo "STOP: $*"; exit 1; }
sh_() { sha256sum "$1" | cut -d' ' -f1; }
case $TOPO in
  2) VMS="0 1"; [ -z "$XSRC" ] || stop "--xml-src is for --topo 8";;
  8) VMS="0 1 2 3 4 5 6 7"; [ -n "$XSRC" ] && [ -d "$XSRC" ] || stop "--topo 8 needs --xml-src <dir>";;
  *) stop "--topo 2|8";;
esac
if [ -z "$V" ]; then V=1; while [ -e "$MB/deploy-v$V" ]; do V=$((V + 1)); done; fi
[[ $V =~ ^[1-9][0-9]*$ ]] || stop "bad --version"
OUT=$MB/deploy-v$V GT=/home/comsys/popcorn-14d-v$V
test ! -e "$OUT" || stop "$OUT exists"
rb() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }
# ---- inputs: kernel build 14, module build 14-dir, source tag, region, build-13 tools, rollback XMLs
K=$(rb "$B/build-record.json" release); COMMIT=$(rb "$B/build-record.json" source_commit)
[ "$K" = "6.14.0-famfs-de-stijl+$LV" ] || stop "release '$K'"
[ "$(rb "$B/build-record.json" dirty_files)" = 0 ] && [ "$(rb "$MB/build-record.json" dirty_files)" = 0 ] || stop "dirty build"
[ "$(rb "$MB/build-record.json" release)" = "$K" ] || stop "14-dir release != $K"
[ "$(git -C "$KTREE" rev-parse "$TAG^{commit}")" = "$COMMIT" ] || stop "$TAG != build commit $COMMIT"
[ "$(rb "$MB/build-record.json" source_commit | cut -d' ' -f1)" = "$COMMIT" ] || stop "14-dir source commit != kernel build commit"
[ -z "$(git -C "$KTREE" status --porcelain --untracked-files=no -- famfs-linux msg_layer_module)" ] || stop "$KTREE not clean"
[ "$(git -C "$KTREE" rev-parse HEAD)" = "$COMMIT" ] || stop "$KTREE HEAD != build commit"
[ "$(sh_ "$B/.config")" = "$(rb "$B/build-record.json" config_sha256)" ] || stop ".config changed"
[ "$(sh_ "$B/arch/x86/boot/bzImage")" = "$(rb "$B/build-record.json" bzImage_sha256)" ] || stop "bzImage changed"
[ "$(sh_ "$B/System.map")" = "$(rb "$B/build-record.json" system_map_sha256)" ] || stop "System.map changed"
grep -q ' swmc_set_directory$' "$B/System.map" || stop "kernel 14 has no swmc_set_directory"
BKO=$MB/cxl_shm.ko
[ "$(sh_ "$BKO")" = "$(rb "$MB/build-record.json" cxl_shm_ko_build_output_sha256)" ] || stop "14-dir cxl_shm.ko changed"
[ "$(modinfo -F version "$BKO")" = "$KOV" ] && [ "$(modinfo -F vermagic "$BKO" | cut -d' ' -f1)" = "$K" ] || stop "$BKO is not $KOV for $K"
modinfo -F parm "$BKO" | grep -q '^directory:' && modinfo -F parm "$BKO" | grep -q '^dir_offset:' || stop "$BKO lacks directory / dir_offset"
[ "$(readlink -f "$MB/source")" = "$KTREE/msg_layer_module" ] || stop "14-dir was not built from $KTREE"
[ "$("${MK[@]}" -s -C "$KS" O="$B" LOCALVERSION="$LV" kernelrelease)" = "$K" ] || stop "kernelrelease differs"
[ "$(sh_ "$REG")" = "$REG_SHA" ] || stop "$REG changed (re-pin REG_SHA)"
git -C "$SW" ls-files --error-unmatch config/cxl_region-popcorn-dir.yaml > /dev/null 2>&1 || stop "$REG is not tracked in $SW"
for f in p-popcorn-guest-dir.sh p-popcorn-shm-dir.sh p-popcorn-deploy-dir.sh ds-prepare-guest.sh; do bash -n "$DEP/$f" || stop "bash -n $f"; done
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$DEP/ds-verify-installed-modules.py" || stop "ds-verify-installed-modules.py does not parse"
(cd "$B13" && sha256sum --quiet -c packet.sha256) && [ "$(sh_ "$B13/packet.sha256")" = "$B13_PKT" ] || stop "$B13 packet"
(cd "$R2" && sha256sum --quiet -c packet.sha256) && [ "$(sh_ "$R2/packet.sha256")" = "$R2_PKT" ] || stop "$R2 packet"
declare -A XS=()
for k in $VMS; do
  if [ "$TOPO" = 2 ]; then XS[$k]=$B13/vm$k/candidate-normal.xml; else XS[$k]=$XSRC/cxl_vm$k.after-define.xml; fi
  test -f "${XS[$k]}" && grep -q "<name>cxl_vm$k</name>" "${XS[$k]}" || stop "no XML for cxl_vm$k (${XS[$k]})"
done
# ---- parameters: ring = last RING_SIZE bytes of msg_ring (== the run-2 Popcorn 13 PARAMS*), directory below it
FL=$B13/tools/faultlat
MP=$("$FL" params --config "$REG" --device-size $DEV_SIZE --nodes 2 --init-state invalid)
read -r MRO MRS < <(sed -n 's/.*ring_offset=\([0-9]*\) ring_size=\([0-9]*\).*/\1 \2/p' <<<"$MP")
read -r MOFF MBYTES < <(sed -n 's/.*managed_offset=\([0-9]*\) managed_size=\([0-9]*\).*/\1 \2/p' <<<"$MP")
ROFF=$((MRO + MRS - RING_SIZE)) DIR_BYTES=$(( 4096 + (MBYTES / 4096 * 4 + 4095) / 4096 * 4096 ))
DIR_OFFSET=$((ROFF - DIR_BYTES))
[ "$DIR_OFFSET" -ge "$MRO" ] && [ $((DIR_OFFSET % 4096)) = 0 ] || stop "directory [$DIR_OFFSET,+$DIR_BYTES) does not fit msg_ring [$MRO,+$MRS)"
[ $((DIR_OFFSET + DIR_BYTES)) -le $((MOFF)) ] || stop "directory overlaps managed"
par() { local p; p=$("$FL" params --config "$REG" --device-size $DEV_SIZE --nodes "$1" --init-state invalid)
  echo "${p/ ring_offset=$MRO ring_size=$MRS / ring_offset=$ROFF ring_size=$RING_SIZE }"; }
for m in 2 3 4 5 6 7 8; do
  [ "$(par $m)" = "$(sed -n "s/^PARAMS_N$m=\"\(.*\)\"$/\1/p" "$R2/tools/popcorn.env")" ] || stop "PARAMS_N$m != the run-2 Popcorn bundle's ($R2)"
done
PARAMS=$(par 2)
LOADD="directory=flat dir_offset=$DIR_OFFSET"
echo "params: ring [$ROFF,+$RING_SIZE) (= run-2 Popcorn PARAMS_N2..8), directory [$DIR_OFFSET,+$DIR_BYTES), msg_ring [$MRO,+$MRS), margin $((DIR_OFFSET - MRO)) B; LOAD_DEFAULTS=\"$LOADD\""
# ---- stage (signed by kbuild); dry: the unsigned build output stands in
SKO=$ST/lib/modules/$K/updates/cxl_shm.ko
if [ ! -e "$ST" ]; then
  if [ "$DRY" = 1 ]; then echo "NOTE: no $ST yet: the first real run stages it (modules_install kernel 14 + cxl_shm 14.0-dir, signed by kbuild with $B/certs/signing_key.pem, depmod); checked the unsigned $BKO instead"
  else
    [ ! -e "$ROOT/workspaces/MEASUREMENT.lock" ] || stop "MEASUREMENT.lock exists: staging runs make (run without the lock)"
    mkdir "$ST"
    "${MK[@]}" -j32 -s -C "$KS" O="$B" LOCALVERSION="$LV" INSTALL_MOD_PATH="$ST" modules_install
    "${MK[@]}" -j32 -s -C "$B" M="$KTREE/msg_layer_module" MO="$MB" LOCALVERSION="$LV" \
      CONFIG_MODULE_SIG_KEY="$B/certs/signing_key.pem" INSTALL_MOD_PATH="$ST" modules_install
    depmod -b "$ST" -F "$B/System.map" "$K"
  fi
else echo "reusing existing stage $ST"; fi
if [ -e "$ST" ]; then
  test -f "$SKO" && [ "$(modinfo -F version "$SKO")" = "$KOV" ] || stop "staged $SKO is not $KOV"
  tail -c 28 "$SKO" | grep -q 'Module signature appended' || stop "staged $SKO is not signed"
fi
if [ "$DRY" = 1 ]; then
  echo "plan: topo $TOPO VMs [$VMS] -> $OUT (GT $GT, images /var/lib/libvirt/images/popcorn-14-vm<k>-v$V)"
  for k in $VMS; do echo "  vm$k rollback XML ${XS[$k]} ($(sh_ "${XS[$k]}" | cut -c1-12))"; done
  echo "  tools: faultlat/run.sh $B13/tools, region $REG ($(cut -c1-12 <<< "$REG_SHA")), guest $DEP/p-popcorn-guest-dir.sh, shm $DEP/p-popcorn-shm-dir.sh, KO_VERSION $KOV"
  echo "  deploy: p-popcorn-deploy.sh = $DEP/p-popcorn-deploy-dir.sh (re-run rules), prepare-guest.sh = ds-prepare-guest.sh, verify-installed-modules.py = ds-verify-installed-modules.py"
  echo "BUNDLE DRY PASS (topo $TOPO, deploy-v$V, nothing written under $MB)"; exit 0
fi
SCR=$(mktemp -d "${TMPDIR:-/tmp}/popcorn14-package.XXXXXX"); trap 'rm -rf "$SCR"' EXIT
MD=$ST/lib/modules/$K
mkdir "$OUT" "$OUT/tools"
(cd "$MD" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o \( -type d -o -type f \) -print | LC_ALL=C sort > "$SCR/members")
! grep -vE '\.ko$|^\./modules\.[^/]+$' <(cd "$MD" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o -type f -print) ||
  stop "unexpected files in the stage"
tar -C "$MD" --no-recursion --owner=0 --group=0 --numeric-owner --mtime=@0 -cf "$OUT/modules.tar" -T "$SCR/members"
cp "$B/.config" "$OUT/kernel.config"
python3 -I - "$MD" "$OUT" "$K" "$B/certs/signing_key.x509" "$SCR" "$BKO" <<'PY'
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
mods = {}
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
                    '-certfile', pem, '-nointern', '-noverify', '-out', '/dev/null'], check=True, stderr=subprocess.DEVNULL)
    vm = subprocess.run(['modinfo', '-F', 'vermagic', ko], check=True, capture_output=True, text=True).stdout.split()[0]
    assert vm == release, f'vermagic {vm}: {rel}'
    if rel == 'updates/cxl_shm.ko':
        assert data[:-len(magic) - 12 - n] == built_ko.read_bytes(), 'updates/cxl_shm.ko payload != 14-dir build output'
    mods[rel] = sha(ko)
assert 'updates/cxl_shm.ko' in mods and 'kernel/drivers/dax/device_dax.ko' in mods
fp = subprocess.run(['openssl', 'x509', '-in', pem, '-noout', '-fingerprint', '-sha256'], check=True,
                    capture_output=True, text=True).stdout.strip()
manifest = {'release': release, 'archive_sha256': sha(out / 'modules.tar'), 'config_sha256': sha(out / 'kernel.config'), 'modules': mods}
(out / 'modules-manifest.json').write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')
(out / 'signatures.txt').write_text(f'{len(mods)} modules: signature trailer + openssl cms verify against the build certificate '
                                    f'({fp}), vermagic {release}: PASS; updates/cxl_shm.ko payload == builds/popcorn_new/14-dir output\n')
print(f'{len(mods)} modules signed and verified; cxl_shm {mods["updates/cxl_shm.ko"]}')
PY
cp "$DEP/ds-prepare-guest.sh" "$OUT/prepare-guest.sh"   # l-vanilla copy + re-deploy of an installed release
cp "$DEP/ds-verify-installed-modules.py" "$OUT/verify-installed-modules.py"
cp "$DEP/l-vanilla-sanitize-initrd.py" "$OUT/sanitize-initrd.py"
cp "$DEP/l-vanilla-verify-module-payload.py" "$OUT/verify-module-payload.py"
cp "$DEP/l-vanilla-verify-initrd.py" "$OUT/verify-initrd.py"
(cd "$OUT" && sha256sum modules-manifest.json kernel.config prepare-guest.sh sanitize-initrd.py verify-module-payload.py \
  verify-initrd.py verify-installed-modules.py > preparation.sha256)
(cd "$OUT" && python3 -I verify-module-payload.py)
cp "$B13/tools/faultlat" "$B13/tools/run.sh" "$OUT/tools/"
cp "$REG" "$OUT/tools/cxl_region.yaml"
cp "$DEP/p-popcorn-guest-dir.sh" "$OUT/tools/p-popcorn-guest.sh"
KO_SHA=$(sh_ "$SKO")
{ echo "# Popcorn build 14 guest expectations (directory bundle; read by p-popcorn-guest.sh = p-popcorn-guest-dir.sh). N-node bundle."
  echo "K=$K"; echo "KO_SHA=$KO_SHA"; echo "KO_VERSION=$KOV"; echo "PARAMS=\"$PARAMS\""
  for m in 2 3 4 5 6 7 8; do echo "PARAMS_N$m=\"$(par $m)\""; done
  echo "MANAGED_BASE_OFF=$MOFF"; echo "MANAGED_BYTES=$MBYTES"
  echo "DIR_OFFSET=$DIR_OFFSET"; echo "DIR_BYTES=$DIR_BYTES"; echo "LOAD_DEFAULTS=\"$LOADD\""
} > "$OUT/tools/popcorn.env"
(cd "$OUT/tools" && sha256sum faultlat run.sh cxl_region.yaml p-popcorn-guest.sh popcorn.env > tools.sha256)
cp "$R2/params-layout.txt" "$OUT/params-layout.txt"
echo "directory: dir_offset=$DIR_OFFSET dir_bytes=$DIR_BYTES (msg_ring [$MRO,+$MRS) of $(basename "$REG"); ring unchanged)" >> "$OUT/params-layout.txt"
for k in $VMS; do
  python3 -I "$DEP/p-popcorn-xml.py" "${XS[$k]}" "/var/lib/libvirt/images/popcorn-14-vm$k-v$V" "$K" "$OUT/vm$k"
  (cd "$OUT/vm$k" && sha256sum rollback-inactive.xml candidate-normal.xml candidate-restricted.xml > xml.sha256)
done
cp "$DEP/p-popcorn-deploy-dir.sh" "$OUT/p-popcorn-deploy.sh"
cp "$DEP/vm-console.py" "$DEP/p-popcorn-xml.py" "$SW/workloads/faultlat/smoke.sh" "$SW/workloads/faultlat/smoke-n.sh" "$OUT/"
cp "$DEP/p-popcorn-shm-dir.sh" "$OUT/p-popcorn-shm.sh"
for f in "$OUT"/*.sh "$OUT"/tools/*.sh; do bash -n "$f" || stop "bash -n $f"; done
BZ=$B/arch/x86/boot/bzImage
{ echo "# Popcorn build 14 bundle deploy-v$V: deploy environment (plain KEY=value; never executed by the chains)"
  echo "C=$OUT"; echo "V=$V"; echo "K=$K"; echo "PRE_K=6.14.0-famfs-de-stijl+-ds-popcorn-new-13"; echo "BZ=$BZ"; echo "BZ_SHA=$(sh_ "$BZ")"
  echo "GT=$GT"; echo "VMS=\"$VMS\""; echo "KO_SHA=$KO_SHA"; echo "KO_PATH_HOST=$SKO"; echo "REGION_SHA=$REG_SHA"
  echo "DIR_OFFSET=$DIR_OFFSET"; echo "LOAD_DEFAULTS=\"$LOADD\""; } > "$OUT/deploy-env.sh"
python3 -I - "$OUT/package-record.json" "$K" "$COMMIT" "$KO_SHA" "$(sh_ "$BKO")" "$REG" "$REG_SHA" "$PARAMS" "$DIR_OFFSET" "$DIR_BYTES" \
  "$(git -C "$SW" rev-parse HEAD)" "$(git -C "$SW" status --porcelain -- scripts/deploy config | wc -l)" "$TOPO" "$(for k in $VMS; do printf '%s=%s ' "vm$k" "${XS[$k]}"; done)" <<'PY'
import datetime, json, sys
a = sys.argv[1:]
json.dump({"build": "14", "module_build": "14-dir", "release": a[1], "source_commit": a[2], "tag": "rel/popcorn-new-14",
           "cxl_shm_ko_sha256": a[3], "cxl_shm_ko_signed": "yes (kbuild modules_install, build key)", "cxl_shm_ko_build_output_sha256": a[4],
           "cxl_shm_module_version": "14.0-dir", "region_config": a[5], "region_sha256": a[6], "cxl_shm_params": a[7],
           "dir_offset": int(a[8]), "dir_bytes": int(a[9]), "cxl_swmc_commit": a[10], "cxl_swmc_dirty_files": int(a[11]),
           "topo": a[12], "xml_sources": a[13].strip(), "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
          open(a[0], "w"), indent=1)
open(a[0], "a").write("\n")
PY
(cd "$OUT" && find . -type f ! -name packet.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > packet.sha256)
echo "BUNDLE PASS $OUT packet $(sh_ "$OUT/packet.sha256")"
