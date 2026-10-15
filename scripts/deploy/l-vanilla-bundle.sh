#!/bin/bash
# Host-only, unprivileged: package a built kernel variant for P3c-style direct
# boot on one or more VMs. No sudo, no guest access, no VM change; the only
# libvirt call is a read-only `virsh dumpxml --inactive` per VM.
# Usage: l-vanilla-bundle.sh <build dir O> <kernel src> <cmdline-extra> <vm>...
#   e.g. l-vanilla-bundle.sh builds/linux-6.14/1 CXL_SWMC/kernels/linux-6.14 "" cxl_vm0 cxl_vm1
# Output (all under O/deploy, which must not exist):
#   stage/lib/modules/$K  modules_install tree (depmod -b run by kbuild)
#   modules.tar           tree minus build/source links, root-owned, sorted
#   <vm>/                 per-VM bundle: modules-manifest.json, modules.tar.sha256,
#                         kernel.config, bzImage.sha256, guest helpers, rollback-inactive.xml
#                         (= current inactive XML), candidate-{normal,restricted}.xml
#                         (only os kernel/initrd/cmdline changed), preparation.sha256,
#                         packet.sha256
# The VM cmdline is the current one minus page_replication_ext=* plus <cmdline-extra>.
set -euo pipefail
umask 022
O=$(readlink -f "$1"); SRC=$(readlink -f "$2"); EXTRA=$3; shift 3
HERE=$(dirname "$(readlink -f "$0")")
K=$(cat "$O/include/config/kernel.release")
OUT=$O/deploy
test ! -e "$OUT"
test -f "$O/arch/x86/boot/bzImage"
mkdir "$OUT"
PIN=(nice -n 19 numactl --cpunodebind=1 --membind=1)
"${PIN[@]}" make -s -C "$SRC" O="$O" ARCH=x86_64 INSTALL_MOD_PATH="$OUT/stage" modules_install > "$OUT/modules_install.log" 2>&1
M=$OUT/stage/lib/modules/$K
test -d "$M"
# Unresolved-symbol check of the staged tree (depmod -b, Host-local only).
depmod -b "$OUT/stage" -e -F "$O/System.map" "$K" > "$OUT/depmod-check.log" 2>&1
if [ -s "$OUT/depmod-check.log" ]; then cat "$OUT/depmod-check.log"; echo "STOP: depmod reported problems"; exit 1; fi
( cd "$M" && find . -mindepth 1 \( -path ./build -o -path ./source \) -prune -o -print0 | LC_ALL=C sort -z \
  | tar --null --no-recursion --owner=0 --group=0 --numeric-owner --mtime=@0 -cf "$OUT/modules.tar" -T - )
python3 -I - "$OUT/modules.tar" "$K" "$O/.config" "$OUT/modules-manifest.json" <<'PY'
import hashlib, json, sys, tarfile
tar, rel, cfg, out = sys.argv[1:]
def h(path):
    d = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): d.update(b)
    return d.hexdigest()
mods = {}
with tarfile.open(tar) as a:
    for m in a:
        n = m.name.removeprefix('./')
        if m.isfile() and n.endswith('.ko'):
            mods[n] = hashlib.sha256(a.extractfile(m).read()).hexdigest()
json.dump({'release': rel, 'archive_sha256': h(tar), 'config_sha256': h(cfg),
           'module_count': len(mods), 'modules': dict(sorted(mods.items()))},
          open(out, 'w'), indent=2)
print(f'manifest: {len(mods)} modules')
PY
for VM in "$@"; do
  B=$OUT/$VM; mkdir "$B"
  cp "$OUT/modules-manifest.json" "$B/"
  ( cd "$OUT" && sha256sum modules.tar ) > "$B/modules.tar.sha256"
  cp "$O/.config" "$B/kernel.config"
  ( cd "$O/arch/x86/boot" && sha256sum bzImage ) > "$B/bzImage.sha256"
  cp "$HERE/l-vanilla-prepare-guest.sh" "$B/prepare-guest.sh"
  cp "$HERE/l-vanilla-sanitize-initrd.py" "$B/sanitize-initrd.py"
  cp "$HERE/l-vanilla-verify-module-payload.py" "$B/verify-module-payload.py"
  cp "$HERE/l-vanilla-verify-initrd.py" "$B/verify-initrd.py"
  cp "$HERE/l-vanilla-deploy.sh" "$HERE/vm-console.py" "$B/"
  virsh -c qemu:///system dumpxml "$VM" --inactive > "$B/rollback-inactive.xml"
  N=${VM##*_}  # cxl_vm0 -> vm0
  D=/var/lib/libvirt/images/linux-$K-$N
  python3 -I - "$B" "$D" "$K" "$EXTRA" <<'PY'
import re, sys, pathlib
b, d, k, extra = sys.argv[1:]
b = pathlib.Path(b)
src = (b / 'rollback-inactive.xml').read_text()
lines = src.splitlines(keepends=True)
idx = {t: [i for i, l in enumerate(lines) if re.match(rf'\s*<{t}>.*</{t}>\s*$', l)] for t in ('kernel', 'initrd', 'cmdline')}
assert all(len(v) == 1 for v in idx.values()), f'expected exactly one kernel/initrd/cmdline line: {idx}'
old = re.search(r'<cmdline>(.*)</cmdline>', lines[idx['cmdline'][0]]).group(1)
args = [a for a in old.split() if not a.startswith('page_replication_ext=') and a != 'init=/bin/sh']
args += extra.split()
for name, add in (('normal', []), ('restricted', ['init=/bin/sh'])):
    out = list(lines)
    ind = lambda i: re.match(r'\s*', lines[i]).group(0)
    out[idx['kernel'][0]] = f"{ind(idx['kernel'][0])}<kernel>{d}/bzImage</kernel>\n"
    out[idx['initrd'][0]] = f"{ind(idx['initrd'][0])}<initrd>{d}/initrd.img-{k}</initrd>\n"
    out[idx['cmdline'][0]] = f"{ind(idx['cmdline'][0])}<cmdline>{' '.join(args + add)}</cmdline>\n"
    (b / f'candidate-{name}.xml').write_text(''.join(out))
print('cmdline old:', old)
print('cmdline new:', ' '.join(args))
PY
  diff "$B/rollback-inactive.xml" "$B/candidate-normal.xml" > "$B/candidate.diff" || true
  test "$(grep -c '^[<>]' "$B/candidate.diff")" -eq 6
  ( cd "$B" && sha256sum modules-manifest.json kernel.config prepare-guest.sh sanitize-initrd.py \
      verify-module-payload.py verify-initrd.py > preparation.sha256
    sha256sum l-vanilla-deploy.sh vm-console.py candidate-normal.xml candidate-restricted.xml \
      rollback-inactive.xml bzImage.sha256 modules.tar.sha256 > packet.sha256 )
  echo "bundle $B ($VM -> $D)"
done
