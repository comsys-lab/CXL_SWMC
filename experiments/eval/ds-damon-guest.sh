# ds-damon-guest.sh: DAMON control for De Stijl replica_mode damon (experiment de-stijl-evaluation-run1, outline §6).
# Never executed on the Host: h2n-block.sh streams it to a guest as root,
#   ssh <guest> "sudo -n sh -s -- <cmd> [args]" < ds-damon-guest.sh
# POSIX sh (the guest's /bin/sh). Uses only the DAMON sysfs interface (/sys/kernel/mm/damon/admin, CONFIG_DAMON_SYSFS);
# no damo tool. One kdamond, one paddr context, one target region = the De Stijl managed CXL range (physical bytes,
# from /sys/kernel/swmc/destijl/registered), one DAMOS scheme "replicate" (mm/damon/paddr.c DAMOS_REPLICATE ->
# ds_replica_replicate() per 4 KiB page; pool full -> LRU eviction inside the kernel, no "evict" scheme).
# Commands:
#   start <start_byte> <end_byte> <sample_us> <aggr_us> <update_us> <min_regions> <max_regions> <min_acc> <quota_ms>
#         <quota_bytes> <reset_ms>
#         min_acc = minimum nr_accesses (samples with the accessed bit per aggregation interval, 0..aggr/sample);
#         quota: at most <quota_ms> ms of action time and <quota_bytes> bytes replicated per <reset_ms> ms window
#         (hot regions first: DAMOS weights nr_accesses / age). Refuses when a kdamond already exists.
#   stats  scheme stats (nr_tried sz_tried nr_applied sz_applied qt_exceeds), kdamond pid / state / CPU ticks, replica
#          counters of /sys/kernel/swmc/destijl (one line, key=value)
#   stop   kdamond off, nr_kdamonds 0 (idempotent: "DAMON OFF" also when none exists)
set -u
# DS_DAMON_TEST_ROOT: Host-side test only (experiments/eval/test/test_ds_damon_guest.sh, a fake sysfs tree); never set
# on a guest (sudo -n sh -s passes no environment)
TR=${DS_DAMON_TEST_ROOT:-}
A=$TR/sys/kernel/mm/damon/admin
K=$A/kdamonds
DS=$TR/sys/kernel/swmc/destijl
die() { echo "DAMON FAIL: $*"; exit 1; }
w() { printf '%s\n' "$2" > "$1" 2>/dev/null || die "write '$2' > $1"; }
isnum() { case "$1" in ''|*[!0-9]*) return 1;; esac; return 0; }
kstat() {  # kdamond pid, state, utime+stime ticks
  pid=$(cat $K/0/pid 2>/dev/null); st=$(cat $K/0/state 2>/dev/null)
  ticks=-; if isnum "$pid" && [ "$pid" -gt 0 ] && [ -r /proc/$pid/stat ]; then
    ticks=$(sed 's/^.*) //' /proc/$pid/stat | awk '{print $12 + $13}'); fi
  echo "kdamond_pid=${pid:--} state=${st:--} cpu_ticks=$ticks clk_tck=$(getconf CLK_TCK)"; }
cmd=${1:-}; shift 2>/dev/null || true
case $cmd in
start)
  [ $# = 11 ] || die "start needs 11 arguments (got $#)"
  for x in "$@"; do isnum "$x" || die "non-integer argument '$x'"; done
  S=$1 E=$2 SU=$3 AU=$4 UU=$5 RMIN=$6 RMAX=$7 MACC=$8 QMS=$9; shift 9; QB=$1 RMS=$2
  [ -d $A ] || die "no $A (kernel without CONFIG_DAMON_SYSFS)"
  [ "$(cat $DS/replica_mode 2>/dev/null)" = damon ] || die "replica_mode is '$(cat $DS/replica_mode 2>/dev/null)', not damon"
  [ "$E" -gt "$S" ] || die "empty range $S..$E"
  [ "$(cat $K/nr_kdamonds)" = 0 ] || die "a kdamond exists already (nr_kdamonds $(cat $K/nr_kdamonds))"
  MAXACC=$((AU / SU)); [ "$MACC" -ge 1 ] && [ "$MACC" -le "$MAXACC" ] || die "min_acc $MACC outside 1..$MAXACC"
  w $K/nr_kdamonds 1
  C=$K/0/contexts; w $C/nr_contexts 1
  grep -qw paddr $C/0/avail_operations || die "no paddr operations"
  w $C/0/operations paddr
  M=$C/0/monitoring_attrs
  w $M/intervals/sample_us "$SU"; w $M/intervals/aggr_us "$AU"; w $M/intervals/update_us "$UU"
  w $M/nr_regions/min "$RMIN"; w $M/nr_regions/max "$RMAX"
  w $C/0/targets/nr_targets 1
  R=$C/0/targets/0/regions; w $R/nr_regions 1
  w $R/0/start "$S"; w $R/0/end "$E"
  w $C/0/schemes/nr_schemes 1
  H=$C/0/schemes/0
  w $H/action replicate
  w $H/access_pattern/sz/min 4096; w $H/access_pattern/sz/max "$((E - S))"
  w $H/access_pattern/nr_accesses/min "$MACC"; w $H/access_pattern/nr_accesses/max "$MAXACC"
  w $H/access_pattern/age/min 0; w $H/access_pattern/age/max 4294967295
  w $H/quotas/ms "$QMS"; w $H/quotas/bytes "$QB"; w $H/quotas/reset_interval_ms "$RMS"
  w $H/quotas/weights/sz_permil 0; w $H/quotas/weights/nr_accesses_permil 1000; w $H/quotas/weights/age_permil 0
  w $H/watermarks/metric none
  w $K/0/state on
  i=0; while [ "$(cat $K/0/state)" != on ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(cat $K/0/state)" = on ] || die "kdamond state $(cat $K/0/state) after 'on'"
  echo "DAMON ON range=$S-$E sample_us=$SU aggr_us=$AU update_us=$UU regions=$RMIN-$RMAX nr_accesses=$MACC-$MAXACC quota_ms=$QMS quota_bytes=$QB reset_ms=$RMS action=$(cat $H/action) $(kstat)" ;;
stats)
  if [ -d $K/0 ] && [ "$(cat $K/0/state 2>/dev/null)" = on ]; then
    printf 'update_schemes_stats\n' > $K/0/state 2>/dev/null || true
    H=$K/0/contexts/0/schemes/0/stats
    s="nr_tried=$(cat $H/nr_tried) sz_tried=$(cat $H/sz_tried) nr_applied=$(cat $H/nr_applied) sz_applied=$(cat $H/sz_applied) qt_exceeds=$(cat $H/qt_exceeds)"
  else s="scheme=none"; fi
  r=; for f in $DS/replica_*; do [ -f "$f" ] && r="$r $(basename $f)=$(head -n 1 $f)"; done
  echo "DAMON STATS $s $(kstat) mem_available_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)$r" ;;
stop)
  [ -d $A ] || { echo "DAMON OFF (no $A)"; exit 0; }
  n=$(cat $K/nr_kdamonds)
  if [ "$n" != 0 ]; then
    [ "$(cat $K/0/state)" = off ] || printf 'off\n' > $K/0/state 2>/dev/null
    i=0; while [ "$(cat $K/0/state)" != off ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    [ "$(cat $K/0/state)" = off ] || die "kdamond still $(cat $K/0/state)"
    w $K/nr_kdamonds 0
  fi
  echo "DAMON OFF (nr_kdamonds $(cat $K/nr_kdamonds), was $n)" ;;
*) die "usage: start ... | stats | stop" ;;
esac
