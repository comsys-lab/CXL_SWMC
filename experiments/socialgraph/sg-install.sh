#!/bin/bash
# socialgraph guest install (experiment socialgraph-serving; run by the chains inside the approval, never during another
# experiment's measurement): copies the Host builds into guest dirs below /home/comsys (as comsys, no sudo) and the graph
# image onto vm0's disk. Idempotent: a file whose sha256 already matches is not copied again.
# usage: sg-install.sh plan|install|image|verify [--conf <socialgraph.conf>] [--n 2|4|8]
#   install  plain build -> SG_VPLAIN (ring2m region) and SG_DS_VPLAIN (De Stijl region) on vm0..N-1; Megalon builds ->
#            SG_VMEG_N<N> (chunk yaml) and, N = 2, SG_VMEG_REC_N2 (record yaml) with lib/ + cfg/megalon.yaml
#   image    SG_IMAGE_HOST -> vm0:SG_IMAGE_GUEST (+ <img>.sha256 = "sha256=<hex>" after a full guest-side hash) and the
#            Host-side builds/socialgraph-image/<n>/image.sha256 (computed once, reused)
#   verify   install sha256s + image size / recorded hash on the guests (read only); "VERIFY PASS" or "VERIFY FAIL ..."
#   plan     what install / image would copy (Host only, no ssh)
# On the VM8 topology the guests 1..7 are overlays of vm0's disk taken at the switch (their files = vm0's at that time):
# install on vm0 + vm1 before the switch covers every VM (verify checks all N).
set -uo pipefail
P=/home/comsys/sungsu/destijl-control
EX=$(cd "$(dirname "$0")" && pwd); TREE=$(cd "$EX/../.." && pwd)
CMD=${1:-}; shift || true
CONF=$EX/socialgraph.conf N=2
while [ $# -gt 0 ]; do case $1 in --conf) CONF=$2; shift 2;; --n) N=$2; shift 2;; *) echo "usage: $0 plan|install|image|verify [--conf F] [--n N]"; exit 2;; esac; done
[[ $CMD =~ ^(plan|install|image|verify)$ ]] && [[ $N =~ ^[248]$ ]] || { echo "usage: $0 plan|install|image|verify [--conf F] [--n 2|4|8]"; exit 2; }
eval "$(python3 -I -B - "$CONF" <<'PY'
import re, shlex, sys
for line in open(sys.argv[1]):
    m = re.match(r'^([A-Z][A-Z0-9_]*)=("([^"]*)"|([^\s#]*))\s*(#.*)?$', line.strip())
    if m:
        print(f"{m.group(1)}={shlex.quote(m.group(3) if m.group(3) is not None else m.group(4))}")
PY
)"
ab() { case $1 in /*) echo "$1";; *) echo "$P/$1";; esac; }
SSH=(ssh -T -o BatchMode=yes -o ConnectTimeout=8)
IPS=(); for k in $(seq 0 $((N - 1))); do IPS+=(192.168.122.$((100 + k))); done
sha() { sha256sum < "$1" | cut -c1-64; }
PB=$(ab "$SG_PLAIN_BUILD")
# "<guest path below /home/comsys> <Host file>" lines per install dir
files_plain() {  # <guest dir> <region file>
  printf '%s %s\n' "$1/bin/sg-server" "$PB/bin/sg-server" "$1/bin/sg-node.sh" "$TREE/scripts/guest/sg-node.sh" "$1/cfg/cxl_region.yaml" "$2"; }
files_meg() {  # <guest dir> <build> <yaml>
  local f; printf '%s %s\n' "$1/bin/sg-server" "$2/bin/sg-server" "$1/bin/sg-node.sh" "$TREE/scripts/guest/sg-node.sh" \
    "$1/cfg/cxl_region.yaml" "$(ab "$REGION")" "$1/cfg/megalon.yaml" "$3"
  for f in libmegalon-objapi.so libmegalon.so libtbb.so.12 libtbbmalloc.so.2 libhwloc.so.15 libatomic.so.1; do printf '%s %s\n' "$1/lib/$f" "$2/lib/$f"; done; }
ALL=$(files_plain "$SG_VPLAIN" "$(ab "$REGION")"; files_plain "$SG_DS_VPLAIN" "$(ab "$SG_DS_REGION")")
v=SG_MG_BUILD_N$N; c=SG_MG_CFG_N$N; m=SG_VMEG_N$N
ALL+=$'\n'$(files_meg "${!m}" "$(ab "${!v}")" "$(ab "${!c}")")
[ "$N" != 2 ] || ALL+=$'\n'$(files_meg "$SG_VMEG_REC_N2" "$(ab "$SG_MG_BUILD_N2")" "$(ab "$SG_MG_CFG_REC_N2")")
while read -r g h; do [ -f "$h" ] || { echo "INSTALL STOP: missing Host file $h"; exit 2; }; done <<< "$ALL"
IMG=$(ab "$SG_IMAGE_HOST") IS=$(dirname "$(ab "$SG_IMAGE_HOST")")/image.sha256
img_sha() {  # Host image sha256 (computed once into image.sha256 next to the image; the image build is immutable)
  [ -s "$IS" ] && [ "$(sed -n 's/^bytes=//p' "$IS")" = "$(stat -c %s "$IMG")" ] || { printf 'sha256=%s\nbytes=%s\n' "$(sha "$IMG")" "$(stat -c %s "$IMG")" > "$IS"; }
  sed -n 's/^sha256=//p' "$IS"; }
case $CMD in
  plan) echo "$ALL" | sed 's/^/PLAN install /'; echo "PLAN image $IMG ($(stat -c %s "$IMG") B) -> vm0:$SG_IMAGE_GUEST"; echo "PLAN DONE";;
  install)
    for k in "${!IPS[@]}"; do
      while read -r g h; do
        want=$(sha "$h"); have=$("${SSH[@]}" comsys@${IPS[$k]} "sha256sum /home/comsys/$g 2>/dev/null | cut -c1-64" < /dev/null)
        [ "$have" = "$want" ] && continue
        "${SSH[@]}" comsys@${IPS[$k]} "mkdir -p /home/comsys/$(dirname "$g")" < /dev/null && scp -q -o BatchMode=yes -p "$h" "comsys@${IPS[$k]}:/home/comsys/$g" \
          || { echo "INSTALL FAIL vm$k $g"; exit 1; }
        echo "installed vm$k /home/comsys/$g ($want)"
      done <<< "$ALL"
    done; echo "INSTALL DONE (${#IPS[@]} VMs)";;
  image)
    hs=$(img_sha)
    have=$("${SSH[@]}" comsys@${IPS[0]} "cat $SG_IMAGE_GUEST.sha256 2>/dev/null; stat -c %s $SG_IMAGE_GUEST 2>/dev/null" < /dev/null | tr '\n' ' ')
    if [ "$have" = "sha256=$hs $(stat -c %s "$IMG") " ]; then echo "IMAGE PRESENT vm0:$SG_IMAGE_GUEST ($hs)"; exit 0; fi
    "${SSH[@]}" comsys@${IPS[0]} "mkdir -p $(dirname "$SG_IMAGE_GUEST") && rm -f $SG_IMAGE_GUEST.sha256 && test \$(df --output=avail -B1 $(dirname "$SG_IMAGE_GUEST") | tail -1) -gt $(( $(stat -c %s "$IMG") + 4294967296 ))" < /dev/null \
      || { echo "IMAGE FAIL: vm0 has no room for $(stat -c %s "$IMG") B + 4 GiB under $(dirname "$SG_IMAGE_GUEST")"; exit 1; }
    scp -q -o BatchMode=yes "$IMG" "comsys@${IPS[0]}:$SG_IMAGE_GUEST" || { echo "IMAGE FAIL: scp"; exit 1; }
    gs=$("${SSH[@]}" comsys@${IPS[0]} "sha256sum $SG_IMAGE_GUEST | cut -c1-64" < /dev/null)
    [ "$gs" = "$hs" ] || { echo "IMAGE FAIL: guest sha256 $gs != $hs"; exit 1; }
    "${SSH[@]}" comsys@${IPS[0]} "echo sha256=$gs > $SG_IMAGE_GUEST.sha256" < /dev/null
    echo "IMAGE DONE vm0:$SG_IMAGE_GUEST ($gs)";;
  verify)
    bad=
    for k in "${!IPS[@]}"; do
      while read -r g h; do
        [ "$("${SSH[@]}" comsys@${IPS[$k]} "sha256sum /home/comsys/$g 2>/dev/null | cut -c1-64" < /dev/null)" = "$(sha "$h")" ] || bad+=" vm$k:$g"
      done <<< "$ALL"
    done
    have=$("${SSH[@]}" comsys@${IPS[0]} "cat $SG_IMAGE_GUEST.sha256 2>/dev/null; stat -c %s $SG_IMAGE_GUEST 2>/dev/null" < /dev/null | tr '\n' ' ')
    [ "$have" = "sha256=$(img_sha) $(stat -c %s "$IMG") " ] || bad+=" vm0:image"
    [ -z "$bad" ] && echo "VERIFY PASS (${#IPS[@]} VMs, image $SG_IMAGE_GUEST)" || { echo "VERIFY FAIL$bad"; exit 1; };;
esac
