#!/bin/bash
# Guest side, read-only, no sudo (run by experiments/rocksdb/part-hook.sh as `ssh <guest> bash -s` AFTER
# experiments/eval/recv-readback.sh in the same stdin): one line with the cxl_shm receiver instrumentation that the
# rocksdb-server stats do not carry (/sys/kernel/cxl_shm/instr: the vector DB server's sys.cxl_shm.instr.* keys, e.g.
# counters kthread_<state>_ns and uncovered_ns): "c.<file>=<v>" for single-integer files, "c.<file>.<name>=<v>" for
# "name value" lines; "c.absent=1" when the directory is missing. Prefixed by t_ns (guest CLOCK_REALTIME ns).
d=/sys/kernel/cxl_shm/instr
s="t_ns=$(date +%s%N) "
if [ -d "$d" ]; then
  for f in "$d"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    b=${f##*/}
    while read -r a v _; do
      [ -n "$a" ] || continue
      if [ -z "$v" ]; then [[ $a =~ ^-?[0-9]+$ ]] && s+="c.$b=$a "
      else [[ $v =~ ^-?[0-9]+$ ]] && [[ $a =~ ^[A-Za-z0-9_.]+$ ]] && s+="c.$b.$a=$v "; fi
    done < "$f" 2>/dev/null
  done
else s+="c.absent=1 "; fi
echo "$s"
