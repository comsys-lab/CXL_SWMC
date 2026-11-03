#!/bin/bash
# Guest side, read-only, no sudo (run by the evaluation blocks as `ssh <guest> bash -s < recv-readback.sh`): one line
# with the cxl_shm receiver parameters (/sys/module/cxl_shm/parameters; "absent" when the module lacks one), the module
# srcversion and the CPU of the receiver threads so far (schedstat run ns summed over the threads): cxl_recv* (receive
# thread) and cxl_ipoll/<cpu> (adaptive idle pollers, SCHED_IDLE), reported separately. experiments/eval/recv-mode.sh.
p=/sys/module/cxl_shm/parameters
out=
for f in recv_mode ring_coherent ipoll fault_poll spin_us watch_us s_min_us s_max_us idle_spin_us idle_sleep_us; do
  v=$(cat "$p/$f" 2>/dev/null) || v=absent
  out+="$f=${v:-absent} "
done
sv=$(cat /sys/module/cxl_shm/srcversion 2>/dev/null) || sv=absent
in=0 ir=0 rn=0 rr=0
for d in /proc/[0-9]*; do
  c=$(cat "$d/comm" 2>/dev/null) || continue
  case $c in
    cxl_ipoll/*) read -r a _ < "$d/schedstat" 2>/dev/null && { in=$((in + 1)); ir=$((ir + a)); };;
    cxl_recv*) read -r a _ < "$d/schedstat" 2>/dev/null && { rn=$((rn + 1)); rr=$((rr + a)); };;
  esac
done
echo "${out}srcversion=${sv:-absent} ipoll_threads=$in ipoll_run_ns=$ir recv_threads=$rn recv_run_ns=$rr"
