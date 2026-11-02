# ds-damon-guest.sh: DAMON control for De Stijl replica_mode damon (experiment de-stijl-evaluation-run1, outline §6;
# extended for damon-policy-exploration, workspaces/destijl-v2/damon-replication/DESIGN.md §4-6, §9).
# Never executed on the Host: h2n-block.sh / damonx-hook.sh stream it to a guest as root,
#   ssh <guest> "sudo -n sh -s -- <cmd> [args]" < ds-damon-guest.sh
# POSIX sh (the guest's /bin/sh). Uses only the DAMON sysfs interface (/sys/kernel/mm/damon/admin, CONFIG_DAMON_SYSFS);
# no damo tool. One kdamond, one paddr context, one target region (physical bytes; the caller passes the managed CXL range
# of /sys/kernel/swmc/destijl/registered or the index extent inside it), one DAMOS scheme (mm/damon/paddr.c
# DAMOS_REPLICATE -> ds_replica_replicate() per 4 KiB page; pool full -> LRU eviction inside the kernel; no "evict").
# Commands:
#   start <start_byte> <end_byte> <sample_us> <aggr_us> <update_us> <min_regions> <max_regions> <min_acc> <quota_ms>
#         <quota_bytes> <reset_ms> [key=value ...]
#         min_acc = minimum nr_accesses (samples with the accessed bit per aggregation interval, 1..aggr/sample; 0 only
#         with action=stat); quota: at most <quota_ms> ms of action time and <quota_bytes> bytes per <reset_ms> ms
#         window (DAMON: 0 = no limit). Refuses when a kdamond already exists. Optional keys (absent = the run-1
#         behaviour): action=replicate|stat (default replicate), min_age=<aggregation intervals> (default 0),
#         w_sz=<permil> w_acc=<permil> w_age=<permil> (DAMOS quota priority weights; default 0 / 1000 / 0),
#         nice=<-20..19> (renice of the kdamond kernel thread after it starts; default untouched)
#   commit <action> <quota_ms> <quota_bytes> <reset_ms>
#         online change of the scheme's action and quotas (sysfs "commit"; regions, ages and the pattern are kept)
#   regions  scheme tried regions (update_schemes_tried_regions): "DAMON REGIONS t=<epoch> n=<n> total_bytes=<b>"
#          then one line "<start> <end> <nr_accesses> <age>" per region (shell builtins only: no fork per file)
#   stats  scheme stats (nr_tried sz_tried nr_applied sz_applied qt_exceeds), action, kdamond pid / state / CPU ticks /
#          nice, replica counters of /sys/kernel/swmc/destijl (one line, key=value)
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
kstat() {  # kdamond pid, state, utime+stime ticks, nice
  pid=$(cat $K/0/pid 2>/dev/null); st=$(cat $K/0/state 2>/dev/null)
  ticks=-; ni=-; if isnum "$pid" && [ "$pid" -gt 0 ] && [ -r /proc/$pid/stat ]; then
    ticks=$(sed 's/^.*) //' /proc/$pid/stat | awk '{print $12 + $13}'); ni=$(sed 's/^.*) //' /proc/$pid/stat | awk '{print $17}'); fi
  echo "kdamond_pid=${pid:--} state=${st:--} cpu_ticks=$ticks nice=$ni clk_tck=$(getconf CLK_TCK)"; }
cmd=${1:-}; shift 2>/dev/null || true
case $cmd in
start)
  [ $# -ge 11 ] || die "start needs 11 arguments (got $#)"
  S=$1 E=$2 SU=$3 AU=$4 UU=$5 RMIN=$6 RMAX=$7 MACC=$8 QMS=$9; shift 9; QB=$1 RMS=$2; shift 2
  for x in $S $E $SU $AU $UU $RMIN $RMAX $MACC $QMS $QB $RMS; do isnum "$x" || die "non-integer argument '$x'"; done
  ACT=replicate MAGE=0 WSZ=0 WACC=1000 WAGE=0 NICE=
  for kv in "$@"; do
    v=${kv#*=}
    case $kv in
      action=replicate|action=stat) ACT=$v ;;
      min_age=*) isnum "$v" || die "bad $kv"; MAGE=$v ;;
      w_sz=*) isnum "$v" || die "bad $kv"; WSZ=$v ;;
      w_acc=*) isnum "$v" || die "bad $kv"; WACC=$v ;;
      w_age=*) isnum "$v" || die "bad $kv"; WAGE=$v ;;
      nice=*) case $v in -*) isnum "${v#-}" || die "bad $kv";; *) isnum "$v" || die "bad $kv";; esac
              [ "$v" -ge -20 ] && [ "$v" -le 19 ] || die "bad $kv"; NICE=$v ;;
      *) die "unknown start key '$kv'" ;;
    esac
  done
  [ -d $A ] || die "no $A (kernel without CONFIG_DAMON_SYSFS)"
  [ "$(cat $DS/replica_mode 2>/dev/null)" = damon ] || die "replica_mode is '$(cat $DS/replica_mode 2>/dev/null)', not damon"
  [ "$E" -gt "$S" ] || die "empty range $S..$E"
  [ "$(cat $K/nr_kdamonds)" = 0 ] || die "a kdamond exists already (nr_kdamonds $(cat $K/nr_kdamonds))"
  MAXACC=$((AU / SU)); LO=1; [ $ACT = stat ] && LO=0
  [ "$MACC" -ge $LO ] && [ "$MACC" -le "$MAXACC" ] || die "min_acc $MACC outside $LO..$MAXACC"
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
  w $H/action $ACT
  w $H/access_pattern/sz/min 4096; w $H/access_pattern/sz/max "$((E - S))"
  w $H/access_pattern/nr_accesses/min "$MACC"; w $H/access_pattern/nr_accesses/max "$MAXACC"
  w $H/access_pattern/age/min "$MAGE"; w $H/access_pattern/age/max 4294967295
  w $H/quotas/ms "$QMS"; w $H/quotas/bytes "$QB"; w $H/quotas/reset_interval_ms "$RMS"
  w $H/quotas/weights/sz_permil "$WSZ"; w $H/quotas/weights/nr_accesses_permil "$WACC"; w $H/quotas/weights/age_permil "$WAGE"
  w $H/watermarks/metric none
  w $K/0/state on
  i=0; while [ "$(cat $K/0/state)" != on ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(cat $K/0/state)" = on ] || die "kdamond state $(cat $K/0/state) after 'on'"
  if [ -n "$NICE" ]; then
    pid=$(cat $K/0/pid 2>/dev/null)
    if isnum "$pid" && [ "$pid" -gt 0 ]; then renice -n "$NICE" -p "$pid" > /dev/null 2>&1 || die "renice $NICE kdamond $pid"
    elif [ -z "$TR" ]; then die "no kdamond pid for nice $NICE"; fi
  fi
  echo "DAMON ON range=$S-$E sample_us=$SU aggr_us=$AU update_us=$UU regions=$RMIN-$RMAX nr_accesses=$MACC-$MAXACC age_min=$MAGE quota_ms=$QMS quota_bytes=$QB reset_ms=$RMS weights=$WSZ/$WACC/$WAGE action=$(cat $H/action) $(kstat)" ;;
commit)
  [ $# = 4 ] || die "commit needs 4 arguments (got $#)"
  case $1 in replicate|stat) ;; *) die "commit: bad action '$1'";; esac
  for x in $2 $3 $4; do isnum "$x" || die "non-integer argument '$x'"; done
  [ -d $K/0 ] && [ "$(cat $K/0/state 2>/dev/null)" = on ] || die "commit: no running kdamond"
  H=$K/0/contexts/0/schemes/0
  w $H/action "$1"; w $H/quotas/ms "$2"; w $H/quotas/bytes "$3"; w $H/quotas/reset_interval_ms "$4"
  w $K/0/state commit
  [ -n "$TR" ] || [ "$(cat $K/0/state)" = on ] || die "kdamond state $(cat $K/0/state) after commit"
  echo "DAMON COMMIT action=$(cat $H/action) quota_ms=$(cat $H/quotas/ms) quota_bytes=$(cat $H/quotas/bytes) reset_ms=$(cat $H/quotas/reset_interval_ms) $(kstat)" ;;
regions)
  [ -d $K/0 ] && [ "$(cat $K/0/state 2>/dev/null)" = on ] || die "regions: no running kdamond"
  w $K/0/state update_schemes_tried_regions
  D=$K/0/contexts/0/schemes/0/tried_regions
  n=0; for d in $D/[0-9]*; do [ -d "$d" ] && n=$((n + 1)); done
  tb=-; [ -r $D/total_bytes ] && read tb < $D/total_bytes
  echo "DAMON REGIONS t=$(date +%s) n=$n total_bytes=$tb"
  for d in $D/[0-9]*; do
    [ -d "$d" ] || continue
    read rs < $d/start; read re < $d/end; read ra < $d/nr_accesses; read rg < $d/age
    echo "$rs $re $ra $rg"
  done ;;
stats)
  if [ -d $K/0 ] && [ "$(cat $K/0/state 2>/dev/null)" = on ]; then
    printf 'update_schemes_stats\n' > $K/0/state 2>/dev/null || true
    H=$K/0/contexts/0/schemes/0/stats
    s="nr_tried=$(cat $H/nr_tried) sz_tried=$(cat $H/sz_tried) nr_applied=$(cat $H/nr_applied) sz_applied=$(cat $H/sz_applied) qt_exceeds=$(cat $H/qt_exceeds) action=$(cat $K/0/contexts/0/schemes/0/action 2>/dev/null)"
  else s="scheme=none"; fi
  # replica counters by name (DS_DS_COUNTERS files of /sys/kernel/swmc/destijl; "absent" when a file is missing)
  r=; for f in replica_pages replica_create replica_evict replica_lru_evict replica_writeback replica_refresh replica_pool_full \
      replica_pool_max_bytes replica_mode; do r="$r $f=$(head -n 1 $DS/$f 2>/dev/null || echo absent)"; done
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
*) die "usage: start ... | commit ... | regions | stats | stop" ;;
esac
