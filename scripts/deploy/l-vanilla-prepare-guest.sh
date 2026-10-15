#!/bin/bash
# Guest-side install of a kernel-variant module tree + initramfs build.
# Generic form of the P3c prepare-guest.sh: G = this script's directory,
# K and the kernel.config hash come from modules-manifest.json (both covered by
# preparation.sha256, which the caller checks before running this as root).
# Writes only /lib/modules/$K (new; must not exist) and files under $G.
set -euo pipefail
G=$(dirname "$(readlink -f "$0")")
K=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["release"])' "$G/modules-manifest.json")
CSHA=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["config_sha256"])' "$G/modules-manifest.json")
[[ "$K" =~ ^6\.14\.0-[A-Za-z0-9.+-]+$ ]]
[[ "$G" =~ ^/var/tmp/[A-Za-z0-9._-]+$ ]]
test "$(id -u)" -eq 0
test ! -e "/lib/modules/$K"
test ! -L "/lib/modules/$K"
test ! -L "$G"
for p in conf tmp; do test ! -e "$G/$p"; test ! -L "$G/$p"; done
python3 -I -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); assert p.resolve()==p; assert pathlib.Path("/lib/modules").resolve() in (pathlib.Path("/lib/modules"),pathlib.Path("/usr/lib/modules"))' "$G"
for tool in python3 tar depmod mkinitramfs lsinitramfs gzip; do command -v "$tool" >/dev/null; done
test "$(df -Pk /lib/modules | awk 'NR==2 {print $4}')" -ge 6291456
python3 -I "$G/verify-module-payload.py"
printf '%s  %s\n' "$CSHA" "$G/kernel.config" | sha256sum -c -
# Validated archive has regular files/directories only, no paths outside this new tree.
install -d -m 0755 "/lib/modules/$K"
tar --no-same-owner --no-same-permissions -C "/lib/modules/$K" -xf "$G/modules.tar"
install -d -m 0755 "/lib/modules/$K/build"
install -m 0644 "$G/kernel.config" "/lib/modules/$K/build/.config"
chmod -R u=rwX,go=rX "/lib/modules/$K"
depmod "$K"
install -d -m 0700 "$G/conf" "$G/conf/conf.d" "$G/conf/hooks" "$G/tmp"
printf 'MODULES=list\nBUSYBOX=auto\nCOMPRESS=gzip\nFSTYPE=ext4\n' > "$G/conf/initramfs.conf"
printf 'virtio_blk\n' > "$G/conf/modules"
cat > "$G/conf/hooks/zz-destijl-safe" <<HOOK
#!/bin/sh
set -eu
case "\${1:-}" in prereqs) exit 0;; esac
python3 -I $G/sanitize-initrd.py "\$DESTDIR"
HOOK
chmod 0700 "$G/conf/hooks/zz-destijl-safe"
cut -d" " -f1 /proc/modules | sort > "$G/modules-before.txt"
TMPDIR="$G/tmp" mkinitramfs -d "$G/conf" -o "$G/initrd.img-$K" "$K"
cut -d" " -f1 /proc/modules | sort > "$G/modules-after.txt"
cmp "$G/modules-before.txt" "$G/modules-after.txt"
python3 -I "$G/verify-initrd.py" "$G/initrd.img-$K" "$G/modules-manifest.json"
lsinitramfs "$G/initrd.img-$K" > "$G/initrd-members.txt"
sha256sum "$G/initrd.img-$K" > "$G/initrd.sha256"
chown "${SUDO_UID:?}:${SUDO_GID:?}" "$G/initrd.img-$K" "$G/initrd-members.txt" "$G/initrd.sha256"
chmod 0600 "$G/initrd.img-$K" "$G/initrd-members.txt" "$G/initrd.sha256"
echo "prepare-guest PASS ($K)"
