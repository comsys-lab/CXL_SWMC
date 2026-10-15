# KV pilot guest pre-check (reports/M5-pilot-kv.md §2), per guest:
#   ssh comsys@<ip> 'EXPECT_K=<release> INSTALL_FILES="<files below /home/comsys>" bash -s' < precheck.sh
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
f=$(sudo -n fuser -v /dev/dax0.0 2>&1); echo "fuser: [$f]"
echo "$f" | grep -q "sudo:" && fail "sudo denied"
echo "$f" | grep -qE '[0-9]+' && fail "dax0.0 in use"
echo "procs kv-server=$(pgrep -c -x kv-server) recsys-server=$(pgrep -c -x recsys-server) vdb-server=$(pgrep -c -x vdb-server) faultlat=$(pgrep -c -x faultlat) kv-store=$(pgrep -c -x kv-store)"
[ "$(pgrep -c -x kv-server)" = 0 ] && [ "$(pgrep -c -x recsys-server)" = 0 ] && [ "$(pgrep -c -x vdb-server)" = 0 ] && [ "$(pgrep -c -x faultlat)" = 0 ] && [ "$(pgrep -c -x kv-store)" = 0 ] || fail procs
for f in $INSTALL_FILES; do sha256sum /home/comsys/$f || fail "install /home/comsys/$f"; done
for f in $INSTALL_FILES; do case $f in *.so|*/kv-server) ldd /home/comsys/$f | grep -q "not found" && fail "ldd $f";; esac; done
m=$(free -g | awk '/Mem/{print $7}'); echo "disk_free=$(df -h /home | tail -1 | awk '{print $4}') mem_avail=${m}G"
[ "$m" -ge 20 ] || fail "mem_avail ${m}G < 20G (kv index replica: ~0.2 GB per 1M keys)"
echo PRECHECK PASS
