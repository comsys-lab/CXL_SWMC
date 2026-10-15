# M4 guest pre-check (reports/M4-vdb-packet.md §3.2), per guest:
#   ssh comsys@<ip> 'EXPECT_K=<release> INIT_CHECK=0|1 INIT_SUMS=<sha256 of the Host image SHA256SUMS> bash -s' < m4-precheck.sh
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
echo "procs vdb-server=$(pgrep -c -x vdb-server) faultlat=$(pgrep -c -x faultlat)"
[ "$(pgrep -c -x vdb-server)" = 0 ] && [ "$(pgrep -c -x faultlat)" = 0 ] || fail procs
sha256sum /home/comsys/vdb8/bin/* /home/comsys/vdb8/cfg/* /home/comsys/vdbm5/bin/* /home/comsys/vdbm5/lib/* /home/comsys/vdbm5/cfg/* || fail install
I=/home/comsys/vdb/init/seg32c32m-a27m
if [ "${INIT_CHECK:-0}" = 1 ]; then
  [ "$(sha256sum < $I/SHA256SUMS | cut -d' ' -f1)" = "$INIT_SUMS" ] || fail "init SHA256SUMS differs from the Host image's"
  (cd $I && sha256sum -c --quiet SHA256SUMS) && echo "init SHA256SUMS OK $(wc -l < $I/SHA256SUMS) files" || fail init
fi
echo "disk_free=$(df -h /home | tail -1 | awk '{print $4}') mem_avail=$(free -g | awk '/Mem/{print $7}')G stat=$(stat -c '%U:%G %a' /dev/dax0.0)"
echo PRECHECK PASS
