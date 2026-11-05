# ds-replica.sh: De Stijl replica_mode for the RecSys main block (sourced by experiments/recsys/main-block.sh; run 2
# widening 2026-11-06 "RecSys T = 1000 ms accuracy + staleness": replica_mode all so that the serving node reads a DRAM
# replica that stays stale until the FETCH_ACK / INV / local write, which makes staleness visible on the emulated
# (hardware-coherent) CXL device). Mirrors experiments/eval/h2n-block.sh replica_set / replica_off_check (vector DB).
# Caller globals: SSH (ssh command string), IPS (guest IPs, index = node), E (block evidence dir), DS_GT (guest tools
# dir: p-destijl-guest.sh replica-mode off|all), RPOOL (pool cap in bytes, DS_REPLICA_POOL_BYTES).
# Optional (Host tests only): DS_SYSFS (default /sys/kernel/swmc/destijl), DS_MEMINFO (default /proc/meminfo).
# Pool rule (user 2026-11-06: 96 GB requested, capped at what the guest allows; the vector-DB DAMON rule
# "pool + 4 GiB <= MemAvailable"): per VM, at every ds lifetime start (after the cxl_shm load, before the preload)
#   pool_vm = min(RPOOL, MemAvailable_vm - 4 GiB), rounded down to 1 MiB; pool_vm < 1 GiB = failure.
# The kernel takes any value (replica_pool_max_bytes_store: pages = min(v >> PAGE_SHIFT, LONG_MAX); default 50 % of
# RAM); a 1 MiB multiple reads back unchanged. Evidence: E/ds-replica-<name>.txt (MemAvailable, previous pool, chosen
# pool, readback, post counters), E/ds-replica-pool-<name>-vm<i> (chosen pool bytes), E/ds-replica-pool-prev-vm<i>
# (the value before the first all lifetime of the block; restored by "off").
DSR_GIB=1073741824
dsr_sys() { echo "${DS_SYSFS:-/sys/kernel/swmc/destijl}"; }
dsr_pool() {  # <MemAvailable kB> <cap bytes>: pool bytes by the rule above (no output when < 1 GiB)
  local p=$(( $1 * 1024 - 4 * DSR_GIB ))
  [ "$p" -le "$2" ] || p=$2
  p=$(( p / 1048576 * 1048576 ))
  [ "$p" -ge $DSR_GIB ] && echo "$p"
}
replica_set() {  # <name> <all|off>: on every VM; read back; 1 on a failure (details in E/ds-replica-<name>.txt)
  local i ip out prev ma pool D; D=$(dsr_sys)
  for i in "${!IPS[@]}"; do
    ip=${IPS[$i]}
    if [ "$2" = all ]; then
      out=$($SSH comsys@$ip "echo mem_available_kb=\$(awk '/^MemAvailable:/{print \$2}' ${DS_MEMINFO:-/proc/meminfo}) pool_prev=\$(cat $D/replica_pool_max_bytes) mode=\$(cat $D/replica_mode) replica_pages=\$(cat $D/replica_pages)" < /dev/null 2>&1)
      echo "$(date -Is) $1 vm$i $ip pre: $out cap=$RPOOL" >> "$E/ds-replica-$1.txt"
      ma=$(sed -n 's/.*mem_available_kb=\([0-9][0-9]*\) .*/\1/p' <<< "$out")
      prev=$(sed -n 's/.*pool_prev=\([0-9][0-9]*\) .*/\1/p' <<< "$out")
      [ -n "$ma" ] && [ -n "$prev" ] || { echo "$(date -Is) $1 vm$i $ip FAIL: MemAvailable / pool unreadable" >> "$E/ds-replica-$1.txt"; return 1; }
      [[ $out == *" mode=off replica_pages=0" ]] || { echo "$(date -Is) $1 vm$i $ip FAIL: replica_mode not off or replicas left before the lifetime" >> "$E/ds-replica-$1.txt"; return 1; }
      pool=$(dsr_pool "$ma" "$RPOOL") || { echo "$(date -Is) $1 vm$i $ip FAIL: MemAvailable ${ma} kB - 4 GiB < 1 GiB (no pool)" >> "$E/ds-replica-$1.txt"; return 1; }
      [ -f "$E/ds-replica-pool-prev-vm$i" ] || echo "$prev" > "$E/ds-replica-pool-prev-vm$i"
      echo "$(date -Is) $1 vm$i $ip pool=$pool (min(cap $RPOOL, MemAvailable $(( ma * 1024 )) - 4 GiB), 1 MiB floor)" >> "$E/ds-replica-$1.txt"
      out=$($SSH comsys@$ip "sudo -n sh -c 'echo $pool > $D/replica_pool_max_bytes' && echo pool=\$(cat $D/replica_pool_max_bytes) && sudo -n $DS_GT/p-destijl-guest.sh replica-mode all" < /dev/null 2>&1)
      out=${out//$'\n'/ | }   # one evidence line
      echo "$(date -Is) $1 vm$i $ip set all (pool_prev=$prev): $out" >> "$E/ds-replica-$1.txt"
      [[ $out == *"pool=$pool"* ]] && [[ $out == *"replica_mode OK (all"* ]] || return 1
      echo "$pool" > "$E/ds-replica-pool-$1-vm$i"
    else
      prev=$(cat "$E/ds-replica-pool-prev-vm$i" 2>/dev/null)
      out=$($SSH comsys@$ip "[ \"\$(cat $D/replica_mode)\" = off ] || sudo -n $DS_GT/p-destijl-guest.sh replica-mode off; ${prev:+sudo -n sh -c 'echo $prev > $D/replica_pool_max_bytes'; }echo mode=\$(cat $D/replica_mode) pool=\$(cat $D/replica_pool_max_bytes) replica_pages=\$(cat $D/replica_pages)" < /dev/null 2>&1)
      out=${out//$'\n'/ | }
      echo "$(date -Is) $1 vm$i $ip set off (pool restore ${prev:--}): $out" >> "$E/ds-replica-$1.txt"
      [[ $out == *"mode=off "* ]] && { [ -z "$prev" ] || [[ $out == *"pool=$prev "* ]]; } || return 1
    fi
  done
}
replica_post() {  # <name>: replica counters after the run (before the teardown); 1 when a VM reports a full pool
  local i ip out rc=0 D; D=$(dsr_sys)
  for i in "${!IPS[@]}"; do
    ip=${IPS[$i]}
    out=$($SSH comsys@$ip "for f in replica_mode replica_pool_max_bytes replica_pages replica_create replica_refresh replica_evict replica_writeback replica_pool_full; do printf '%s=%s ' \$f \"\$(cat $D/\$f 2>/dev/null)\"; done; echo" < /dev/null 2>&1)
    echo "$(date -Is) $1 vm$i $ip post: $out" >> "$E/ds-replica-$1.txt"
    [[ $out == *" replica_pool_full=0 "* ]] || rc=1
  done
  return $rc
}
