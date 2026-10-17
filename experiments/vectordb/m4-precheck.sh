# M4/M5 guest pre-check (reports/M4-vdb-packet.md, reports/M5-pilot-packet.md), per guest (m4-lib.sh precheck):
#   ssh comsys@<ip> 'EXPECT_K=<release> [EXPECT_DAX_UUID=<uuid>] INIT_DIR=<guest image dir> INIT_SUMS=<sha256 of the Host image SHA256SUMS>
#                    INIT_CHECK=0|1 INSTALL_DIRS="<files below /home/comsys>" bash -s' < m4-precheck.sh
# Read-only + sudo -n fuser (standing grant A2 pre-check). Prints "PRECHECK PASS" or "PRECHECK FAIL <item>".
fail() { echo "PRECHECK FAIL $*"; exit 1; }
echo "host=$(hostname) uname=$(uname -r) nproc=$(nproc) $(date -Is)"
[ "$(uname -r)" = "$EXPECT_K" ] || fail "kernel $(uname -r) != $EXPECT_K"
echo "cxl_shm_loaded=$(lsmod | grep -c cxl_shm) famfs_mounts=$(grep -c famfs /proc/mounts)"
[ "$(grep -c famfs /proc/mounts)" = 0 ] || fail famfs
[ "$(lsmod | grep -c cxl_shm)" = 0 ] || fail "cxl_shm loaded"
[ "$(stat -c '%U:%G %a' /dev/dax0.0)" = "root:root 600" ] || fail "dax0.0 not root:root 600"
echo "dax size=$(cat /sys/bus/dax/devices/dax0.0/size) align=$(cat /sys/bus/dax/devices/dax0.0/align)"
[ "$(cat /sys/bus/dax/devices/dax0.0/size)" = 103060340736 ] && [ "$(cat /sys/bus/dax/devices/dax0.0/align)" = 4096 ] || fail dax
# optional EXPECT_DAX_UUID (VDB-V1 v1.3): namespace0.0 info-block uuid from unprivileged `ndctl list -N` (as
# scripts/deploy/p3c-devdax.sh snap/check); detects a re-created namespace since the expected devdax restore
if [ -n "${EXPECT_DAX_UUID:-}" ]; then
  u=$(ndctl list -N 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; n=[x for x in d if x.get("dev")=="namespace0.0"]; print(n[0].get("uuid","none") if len(n)==1 else "none")' 2>/dev/null)
  echo "dax uuid=$u"
  [ "$u" = "$EXPECT_DAX_UUID" ] || fail "namespace0.0 uuid $u != $EXPECT_DAX_UUID"
fi
# Popcorn build >= 11: instr/detail must be 0 (default; detail-only timings are not part of any measurement)
if [ -r /sys/kernel/swmc/instr/detail ]; then
  echo "instr enabled=$(cat /sys/kernel/swmc/instr/enabled 2>/dev/null) detail=$(cat /sys/kernel/swmc/instr/detail)"
  [ "$(cat /sys/kernel/swmc/instr/detail)" = 0 ] || fail "instr/detail != 0"
fi
f=$(sudo -n fuser -v /dev/dax0.0 2>&1); echo "fuser: [$f]"
echo "$f" | grep -q "sudo:" && fail "sudo denied"
echo "$f" | grep -qE '[0-9]+' && fail "dax0.0 in use"
echo "procs vdb-server=$(pgrep -c -x vdb-server) faultlat=$(pgrep -c -x faultlat)"
[ "$(pgrep -c -x vdb-server)" = 0 ] && [ "$(pgrep -c -x faultlat)" = 0 ] || fail procs
for f in $INSTALL_DIRS; do sha256sum /home/comsys/$f || fail "install /home/comsys/$f"; done
I=$INIT_DIR
if [ "${INIT_CHECK:-0}" = 1 ]; then
  [ "$(sha256sum < $I/SHA256SUMS | cut -d' ' -f1)" = "$INIT_SUMS" ] || fail "init SHA256SUMS differs from the Host image's"
  (cd $I && sha256sum -c --quiet SHA256SUMS) && echo "init SHA256SUMS OK $(wc -l < $I/SHA256SUMS) files" || fail init
fi
echo "disk_free=$(df -h /home | tail -1 | awk '{print $4}') mem_avail=$(free -g | awk '/Mem/{print $7}')G stat=$(stat -c '%U:%G %a' /dev/dax0.0)"
echo PRECHECK PASS
