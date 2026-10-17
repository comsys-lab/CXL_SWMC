# recsys pilot guest pre-check (reports/RECSYS-design.md §8), per guest:
#   ssh comsys@<ip> 'EXPECT_K=<release> INSTALL_FILES="<files below /home/comsys>" [MEM_MIN=<GiB, default 20>] [EXPECT_DAX_UUID=<uuid>] bash -s' < precheck.sh
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
# optional EXPECT_DAX_UUID (H1 main): namespace0.0 info-block uuid from unprivileged `ndctl list -N` (as
# experiments/vectordb/m4-precheck.sh)
if [ -n "${EXPECT_DAX_UUID:-}" ]; then
  u=$(ndctl list -N 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,list) else [d]; n=[x for x in d if x.get("dev")=="namespace0.0"]; print(n[0].get("uuid","none") if len(n)==1 else "none")' 2>/dev/null)
  echo "dax uuid=$u"
  [ "$u" = "$EXPECT_DAX_UUID" ] || fail "namespace0.0 uuid $u != $EXPECT_DAX_UUID"
fi
f=$(sudo -n fuser -v /dev/dax0.0 2>&1); echo "fuser: [$f]"
echo "$f" | grep -q "sudo:" && fail "sudo denied"
echo "$f" | grep -qE '[0-9]+' && fail "dax0.0 in use"
echo "procs recsys-server=$(pgrep -c -x recsys-server) vdb-server=$(pgrep -c -x vdb-server) faultlat=$(pgrep -c -x faultlat) kv-store=$(pgrep -c -x kv-store)"
[ "$(pgrep -c -x recsys-server)" = 0 ] && [ "$(pgrep -c -x vdb-server)" = 0 ] && [ "$(pgrep -c -x faultlat)" = 0 ] && [ "$(pgrep -c -x kv-store)" = 0 ] || fail procs
for f in $INSTALL_FILES; do sha256sum /home/comsys/$f || fail "install /home/comsys/$f"; done
for f in $INSTALL_FILES; do case $f in *.so|*/recsys-server) ldd /home/comsys/$f | grep -q "not found" && fail "ldd $f";; esac; done
m=$(free -g | awk '/Mem/{print $7}'); echo "disk_free=$(df -h /home | tail -1 | awk '{print $4}') mem_avail=${m}G"
[ "$m" -ge "${MEM_MIN:-20}" ] || fail "mem_avail ${m}G < ${MEM_MIN:-20}G (Megalon index + placement)"
echo PRECHECK PASS
