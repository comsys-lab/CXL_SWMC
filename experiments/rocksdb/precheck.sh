#!/bin/bash
# RocksDB guest pre-check (reports/ROCKSDB-V1-packet.md), per guest, read-only + sudo -n fuser (standing grant A):
#   ssh comsys@<ip> 'EXPECT_K=<release> L=<install dir> EXPECT_SHA="<sha server> <sha node.sh> <sha region>" bash -s' < precheck.sh
# optional EXPECT_DAX_UUID (namespace0.0 uuid), EXPECT_DAX_SIZE (103060340736), MIN_MEM_G (16).
# FAILS (exit 1, "PRECHECK FAIL <item>") unless: kernel = EXPECT_K, cxl_shm not loaded, no famfs, /dev/dax0.0 root:root 600
# and unused, no rocksdb-server/kv/lmdb/vdb/recsys process (command line), the installed files' sha256 = EXPECT_SHA
# (in that order: bin/rocksdb-server bin/rocksdb-node.sh cfg/cxl_region.yaml), ldd complete, available memory >= MIN_MEM_G.
fail() { echo "PRECHECK FAIL $*"; exit 1; }
echo "host=$(hostname) uname=$(uname -r) nproc=$(nproc) $(date -Is)"
[ "$(uname -r)" = "${EXPECT_K:?}" ] || fail "kernel $(uname -r) != $EXPECT_K"
echo "cxl_shm_loaded=$(lsmod | grep -c cxl_shm) famfs_mounts=$(grep -c famfs /proc/mounts)"
[ "$(grep -c famfs /proc/mounts)" = 0 ] || fail famfs
[ "$(lsmod | grep -c cxl_shm)" = 0 ] || fail "cxl_shm loaded"
[ "$(stat -c '%U:%G %a' /dev/dax0.0)" = "root:root 600" ] || fail "dax0.0 not root:root 600"
echo "dax size=$(cat /sys/bus/dax/devices/dax0.0/size) align=$(cat /sys/bus/dax/devices/dax0.0/align)"
[ "$(cat /sys/bus/dax/devices/dax0.0/size)" = "${EXPECT_DAX_SIZE:-103060340736}" ] && [ "$(cat /sys/bus/dax/devices/dax0.0/align)" = 4096 ] || fail dax
f=$(sudo -n fuser -v /dev/dax0.0 2>&1); echo "fuser: [$f]"
echo "$f" | grep -q "sudo:" && fail "sudo denied"
echo "$f" | grep -qE '[0-9]+' && fail "dax0.0 in use"
if [ -n "${EXPECT_DAX_UUID:-}" ]; then
  u=$(ndctl list -n namespace0.0 2>/dev/null | python3 -I -B -c 'import json,sys
try:
    j=json.load(sys.stdin); j=j[0] if isinstance(j,list) else j; print(j.get("uuid",""))
except Exception:
    print("")')
  echo "namespace0.0_uuid=$u"; [ "$u" = "$EXPECT_DAX_UUID" ] || fail "dax uuid '$u' != $EXPECT_DAX_UUID"
fi
anc=" $$ "; q=$$; while [ "$q" -gt 1 ] 2>/dev/null; do q=$(awk '{print $4}' /proc/$q/stat 2>/dev/null) || break; anc="$anc$q "; done
c=0; for x in $(pgrep -u comsys -f '(^|[ /])bin/(rocksdb-serve[r]|kv-serve[r]|lmdb-serve[r]|lmdb-stres[s]|vdb-serve[r]|recsys-serve[r])( |$)'); do
  case "$anc" in *" $x "*) ;; *) c=$((c + 1));; esac; done
echo "procs_cmdline=$c"; [ "$c" = 0 ] || fail "procs (command line)"
got=$(cd "${L:?}" && for f in bin/rocksdb-server bin/rocksdb-node.sh cfg/cxl_region.yaml; do sha256sum < $f | cut -c1-64; done | tr '\n' ' ')
echo "install_sha=[${got% }] expect=[${EXPECT_SHA:?}]"
[ "${got% }" = "$EXPECT_SHA" ] || fail "install sha256 mismatch"
ldd "$L/bin/rocksdb-server" | grep -q "not found" && fail "ldd rocksdb-server"
m=$(free -g | awk '/Mem/{print $7}'); echo "mem_avail=${m}G"
[ "$m" -ge "${MIN_MEM_G:-16}" ] || fail "mem_avail ${m}G < ${MIN_MEM_G:-16}G"
echo PRECHECK PASS
