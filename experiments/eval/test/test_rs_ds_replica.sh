#!/bin/bash
# Host test of experiments/recsys/ds-replica.sh (RecSys De Stijl replica_mode all; no VM, no sudo, no kernel): a fake
# ssh runs each remote command in a local shell against a per-VM fake sysfs dir, a fake sudo drops "-n", a fake
# p-destijl-guest.sh implements replica-mode off|all (EBUSY when <vm>/busy exists). Checks the pool rule
# min(cap, MemAvailable - 4 GiB) (1 MiB floor, >= 1 GiB), readback, evidence files, restore to off + previous pool,
# post counters, and the failure cases. usage: bash test_rs_ds_replica.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TD=$(mktemp -d /tmp/rs-ds-replica-test-XXXXXX)
[ -n "${KEEP:-}" ] && echo "KEEP: $TD" || trap 'rm -rf "$TD"' EXIT
fail() { echo "RS DS REPLICA TEST FAIL: $*"; exit 1; }
mkdir -p "$TD/bin" "$TD/E"
printf '#!/bin/bash\n[ "${1:-}" = -n ] && shift\nexec "$@"\n' > "$TD/bin/sudo"
cat > "$TD/bin/fakessh" << EOF
#!/bin/bash
ip=\${1#comsys@}; cmd=\${2//@VMROOT@/$TD/vm\$ip}
PATH=$TD/bin:\$PATH exec bash -c "\$cmd"
EOF
chmod +x "$TD/bin/sudo" "$TD/bin/fakessh"
GIB=1073741824
mkvm() {  # <ip> <MemAvailable kB>
  local r=$TD/vm$1
  mkdir -p "$r/sys" "$r/gt"
  printf 'MemTotal:       98000000 kB\nMemAvailable:   %s kB\n' "$2" > "$r/meminfo"
  echo off > "$r/sys/replica_mode"; echo 50590875648 > "$r/sys/replica_pool_max_bytes"
  for f in replica_pages replica_create replica_refresh replica_evict replica_writeback replica_pool_full; do echo 0 > "$r/sys/$f"; done
  cat > "$r/gt/p-destijl-guest.sh" << EOF
#!/bin/bash
[ "\$1" = replica-mode ] || exit 2
[ ! -e $r/busy ] || { echo "STOP: write replica_mode=\$2 refused (EBUSY)"; exit 1; }
echo "\$2" > $r/sys/replica_mode; echo 0 > $r/sys/replica_pages
echo "replica_mode OK (\$2; replica_pages 0)"
EOF
  chmod +x "$r/gt/p-destijl-guest.sh"; }
v() { cat "$TD/vm$1/sys/$2"; }
mkvm 10.0.0.1 $(( 94 * 1048576 + 123 ))   # 94 GiB + 123 kB available -> pool 90 GiB (MemAvailable - 4 GiB, 1 MiB floor)
mkvm 10.0.0.2 $(( 200 * 1048576 ))        # 200 GiB -> pool = cap 96 GiB
SSH=$TD/bin/fakessh IPS=(10.0.0.1 10.0.0.2) E=$TD/E DS_GT=@VMROOT@/gt RPOOL=$(( 96 * GIB ))
DS_SYSFS=@VMROOT@/sys DS_MEMINFO=@VMROOT@/meminfo
. "$HERE/../../recsys/ds-replica.sh"
# pool rule
[ "$(dsr_pool $(( 94 * 1048576 + 123 )) $RPOOL)" = $(( 90 * GIB )) ] || fail "dsr_pool 94 GiB"
[ "$(dsr_pool $(( 200 * 1048576 )) $RPOOL)" = $(( 96 * GIB )) ] || fail "dsr_pool cap"
[ "$(dsr_pool $(( 5 * 1048576 + 1000 )) $RPOOL)" = $GIB ] || fail "dsr_pool 1 GiB edge"
dsr_pool $(( 5 * 1048576 - 1 )) $RPOOL > /dev/null && fail "dsr_pool < 1 GiB accepted"
# all on both VMs
replica_set ds-u200-auc all || fail "replica_set all: $(cat $TD/E/ds-replica-ds-u200-auc.txt)"
[ "$(v 10.0.0.1 replica_mode)" = all ] && [ "$(v 10.0.0.2 replica_mode)" = all ] || fail "mode not all"
[ "$(v 10.0.0.1 replica_pool_max_bytes)" = $(( 90 * GIB )) ] && [ "$(v 10.0.0.2 replica_pool_max_bytes)" = $(( 96 * GIB )) ] || fail "pool values"
[ "$(cat $TD/E/ds-replica-pool-ds-u200-auc-vm0)" = $(( 90 * GIB )) ] && [ "$(cat $TD/E/ds-replica-pool-ds-u200-auc-vm1)" = $(( 96 * GIB )) ] || fail "pool evidence"
[ "$(cat $TD/E/ds-replica-pool-prev-vm0)" = 50590875648 ] || fail "prev pool evidence"
grep -q "vm1 10.0.0.2 set all (pool_prev=50590875648): pool=$(( 96 * GIB )) | replica_mode OK (all" $TD/E/ds-replica-ds-u200-auc.txt || fail "readback line"
# post counters: clean, then a full pool on vm1
replica_post ds-u200-auc || fail "replica_post clean"
grep -q "vm0 10.0.0.1 post: replica_mode=all replica_pool_max_bytes=$(( 90 * GIB )) replica_pages=0 .* replica_pool_full=0 " $TD/E/ds-replica-ds-u200-auc.txt || fail "post line"
echo 3 > $TD/vm10.0.0.2/sys/replica_pool_full
replica_post ds-u200-auc && fail "replica_post: full pool not reported"
echo 0 > $TD/vm10.0.0.2/sys/replica_pool_full
# off: mode off, previous pool restored
replica_set ds-u200-auc off || fail "replica_set off"
for ip in 10.0.0.1 10.0.0.2; do [ "$(v $ip replica_mode)" = off ] && [ "$(v $ip replica_pool_max_bytes)" = 50590875648 ] || fail "off restore $ip"; done
# second lifetime: the prev file keeps the boot value
echo $(( 7 * GIB )) > $TD/vm10.0.0.1/sys/replica_pool_max_bytes
replica_set ds-u400-auc all || fail "second all"
[ "$(cat $TD/E/ds-replica-pool-prev-vm0)" = 50590875648 ] || fail "prev overwritten"
replica_set ds-u400-auc off || fail "second off"
[ "$(v 10.0.0.1 replica_pool_max_bytes)" = 50590875648 ] || fail "second restore"
# failures: mode left all, too little memory, EBUSY
echo all > $TD/vm10.0.0.2/sys/replica_mode
replica_set x1 all && fail "all accepted with replica_mode already all"
grep -q "FAIL: replica_mode not off" $TD/E/ds-replica-x1.txt || fail "x1 reason"
[ "$(v 10.0.0.1 replica_mode)" = all ] || fail "x1: vm0 was set before vm1 failed"   # main-block: REPL_SET=1 -> finish restores
replica_set x1 off || fail "x1 off"
printf 'MemAvailable:   %s kB\n' $(( 4 * 1048576 )) > $TD/vm10.0.0.1/meminfo
replica_set x2 all && fail "all accepted with MemAvailable 4 GiB"
grep -q "FAIL: MemAvailable" $TD/E/ds-replica-x2.txt || fail "x2 reason"
printf 'MemAvailable:   %s kB\n' $(( 94 * 1048576 )) > $TD/vm10.0.0.1/meminfo
touch $TD/vm10.0.0.1/busy
replica_set x3 all && fail "all accepted on EBUSY"
rm $TD/vm10.0.0.1/busy
echo "RS DS REPLICA TEST PASS (pool rule, all/off on 2 fake VMs, readback, evidence, post counters, 4 failure cases)"
