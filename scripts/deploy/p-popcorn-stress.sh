#!/bin/bash
# Popcorn MSI high-contention stress (faultlat contend) on the 2 VMs, driven from the Host.
# Grant-gated except `list` and `summary`: writes to the guests' home, sudo status reads, /dev/dax0.0
# (SWcc hot sets + the HWcc app range below msg_ring).  cxl_shm load/enable/chown/teardown stay with
# p-popcorn-shm.sh.  Packet: reports/P-popcorn-stress-packet.md.
#
#   p-popcorn-stress.sh install                 new $GS on both guests (as comsys) from bundle $B; hashes
#   p-popcorn-stress.sh precheck                kernel K, tool hashes, cxl_shm loaded with init_state
#                                               $INIT_STATE, coherence on/off ($ENABLED=1|0), recv_mode
#                                               $RECV_MODE, dax0.0 comsys:root 600, no faultlat/vdb-server
#   p-popcorn-stress.sh list <scenarios>        print the per-scenario guest commands (no ssh)
#   p-popcorn-stress.sh preload <scenarios>     init_state=shared before enable: node 0 writes the init stamp
#                                               (salt $SALT) on every scenario window through a plain mapping
#   p-popcorn-stress.sh run <scenarios>         each scenario: status/dmesg pre, both nodes at once, status/dmesg
#                                               post, acceptance, collect; stops at the first failure
#   p-popcorn-stress.sh diag                    read-only evidence after a failure (kernel stacks of faultlat
#                                               threads via sudo cat /proc/<pid>/task/*/stack, dmesg, status)
#   p-popcorn-stress.sh soak-pick <summary.csv> <out>   scenario line for the soak (see packet)
#   p-popcorn-stress.sh summary                 $R/summary.csv from every scenario dir under $R
#
# Scenario file: one per line, `#` comments:
#   name threads pages read_pct_node0 read_pct_node1 dist duration_s [extra faultlat args]
# dist: uniform | zipf | partition.  Extra args go to both nodes; the tokens @0 / @1 / @a switch the target of
# the following args to node 0 / node 1 / both.  Windows (swcc pages) are assigned in file order from $BASE:
# each scenario starts at the previous start + pages rounded up to 1024; the run refuses to pass $END.
#
# Env (required for guest phases): K GT R B; optional: IP0 IP1, GS (default /home/comsys/popcorn-stress-v1),
# BASE END (default 25020000 25060000), RUNTAG (guest result dir name, default basename of R), INIT_STATE
# (invalid), ENABLED (1), RECV_MODE (poll), WATCHDOG_S (20), SALT (shared mode: --skip-init --salt SALT),
# SCEN_TIMEOUT_EXTRA (s added to duration for the Host-side per-scenario limit, default 300),
# STRESS_SSH / STRESS_SCP (test shims replacing ssh / scp).
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
IP=("${IP0:-192.168.122.100}" "${IP1:-192.168.122.101}")
GS=${GS:-/home/comsys/popcorn-stress-v1}
BASE=${BASE:-25020000} END=${END:-25060000}
INIT_STATE=${INIT_STATE:-invalid} ENABLED=${ENABLED:-1} RECV_MODE=${RECV_MODE:-poll}
WATCHDOG_S=${WATCHDOG_S:-20} SCEN_TIMEOUT_EXTRA=${SCEN_TIMEOUT_EXTRA:-300}
FLAGS=(-F /dev/null -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ForwardAgent=no -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=8 -o ConnectionAttempts=1)
SSH=${STRESS_SSH:-ssh} SCP=${STRESS_SCP:-scp}
# dmesg lines that stop the run (status.dmesg_bad covers only BUG/Oops/WARNING/Call Trace)
BADPAT='BUG:|Oops|WARNING:|Call Trace|blocked for more than|hung_task|stale response|response without outstanding|transaction for pfn .* failed|send of type .* failed|send failed|link to node .* (down|broken)|bad request from node|bad message from node|error message from node|plain \(non-coherent\) mapping|contract violation|soft lockup|rcu_sched|rcu: INFO'

on() { local k=$1; shift; $SSH -T "${FLAGS[@]}" "comsys@${IP[$k]}" "$@" < /dev/null; }
G() { local k=$1; shift; on "$k" "sudo -n $GT/p-popcorn-guest.sh $*"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$R/steps.log"; }
need() { : "${K:?}" "${GT:?}" "${R:?}" "${B:?}"; [ -d "$R" ] || { test -d "$(dirname "$R")" && mkdir -m 0700 "$R"; }; }
wait_no_faultlat() {  # bounded wait (120 s) until no faultlat runs on either guest
  local i k busy
  for ((i = 0; i < 60; i++)); do
    busy=0
    for k in 0 1; do [ -z "$(on "$k" "pgrep -x faultlat || true")" ] || busy=1; done
    [ "$busy" = 0 ] && return 0
    sleep 2
  done
  return 1
}

# parse <file>: emits "name|T|H|R0|R1|dist|D|offset|args0|args1|extra" per scenario
parse() {
  local f=$1 off=$BASE line name T H R0 R1 dist D rest tgt a0 a1 tok
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    [ -n "${line// /}" ] || continue
    read -r name T H R0 R1 dist D rest <<< "$line"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$T" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ && "$R0" =~ ^[0-9]+$ && "$R1" =~ ^[0-9]+$ &&
       "$dist" =~ ^(uniform|zipf|partition)$ && "$D" =~ ^[0-9]+$ ]] || { echo "bad scenario line: $line" >&2; exit 2; }
    tgt=a a0="" a1=""
    for tok in $rest; do
      case "$tok" in
        @0) tgt=0 ;; @1) tgt=1 ;; @a) tgt=a ;;
        *) [[ "$tok" =~ ^[A-Za-z0-9._:=,-]+$ ]] || { echo "bad token '$tok' in $name" >&2; exit 2; }
           case $tgt in 0) a0+=" $tok" ;; 1) a1+=" $tok" ;; a) a0+=" $tok"; a1+=" $tok" ;; esac ;;
      esac
    done
    (( off + H <= END )) || { echo "scenario $name: window [$off, +$H) passes END $END" >&2; exit 2; }
    echo "$name|$T|$H|$R0|$R1|$dist|$D|$off|$a0|$a1|${rest:-}"
    off=$(( off + (H + 1023) / 1024 * 1024 ))
  done < "$f"
}

# gcmd <node> <runid> <fields...>: the guest command line for one node
gcmd() {
  local k=$1 rid=$2 name=$3 T=$4 H=$5 R0=$6 R1=$7 dist=$8 D=$9 off=${10} a0=${11} a1=${12} app=${13} rp extra shared=""
  if [ "$k" = 0 ]; then rp=$R0 extra=$a0; else rp=$R1 extra=$a1; fi
  [ -z "${SALT:-}" ] || shared=" --skip-init --salt $SALT"
  echo "CXL_REGION_CONFIG=$GS/cxl_region.yaml CXL_APP_HWCC_BYTES=$app $GS/run.sh /home/comsys/popcorn-results/${RUNTAG:-$(basename "${R:-stress}")}/$name $name contend --node $k --nodes 2 --run-id $rid --threads $T --pages $H --page-offset $off --read-pct $rp --dist $dist --duration-s $D --watchdog-s $WATCHDOG_S$shared$extra"
}
appbytes() { "$B/faultlat" contend --app-bytes --nodes 2 --threads "$1" --pages "$2"; }

accept() {  # accept <dir> <node>: counters that must not move, dmesg, in-flight
  python3 -I - "$1/status-pre-vm$2.txt" "$1/status-post-vm$2.txt" "$2" <<'PY'
import sys
def kv(p):
    d = {}
    for l in open(p):
        if '=' in l and not l.startswith('dmesg: '):
            k, v = l.rstrip('\n').split('=', 1); d[k] = v
    return d
b, a, node = kv(sys.argv[1]), kv(sys.argv[2]), sys.argv[3]
bad = []
for c in ('transaction_error_count', 'send_drop_count', 'late_response_count'):
    if int(a['swmc.' + c]) - int(b['swmc.' + c]) != 0: bad.append(c)
if a.get('swmc.in_flight_transaction_count') != '0': bad.append('in_flight %s' % a.get('swmc.in_flight_transaction_count'))
if a.get('dmesg_bad') != b.get('dmesg_bad'): bad.append('dmesg_bad %s -> %s' % (b.get('dmesg_bad'), a.get('dmesg_bad')))
if not a.get('release', '').endswith(' loaded=1'): bad.append('cxl_shm not loaded after the scenario')
print('vm%s %s' % (node, 'OK' if not bad else 'FAIL ' + ', '.join(bad)))
sys.exit(1 if bad else 0)
PY
}

run_one() {  # run_one <fields>: one scenario on both nodes (called under ||: every check is explicit)
  local name T H R0 R1 dist D off a0 a1 extra
  IFS='|' read -r name T H R0 R1 dist D off a0 a1 extra <<< "$1"
  local d=$R/$name rid app k rc0=0 rc1=0 p1 lim builds ok=0
  mkdir -m 0700 "$d" || { log "STOP: $d exists"; return 1; }
  rid=$(( $(date +%s%N) / 1000 % 9000000000000000 + 1 ))
  app=$(appbytes "$T" "$H")
  builds=$(pgrep -c -x 'make|cc1|cc1plus|ld|rustc|cargo' || true)
  {
    echo "scenario=$name"; echo "threads=$T"; echo "pages=$H"; echo "read_pct0=$R0"; echo "read_pct1=$R1"
    echo "dist=$dist"; echo "duration_s=$D"; echo "page_offset=$off"; echo "extra=$extra"; echo "run_id=$rid"
    echo "app_bytes=$app"; echo "salt=${SALT:-}"; echo "host_build_procs=$builds"; echo "host_loadavg=$(cat /proc/loadavg)"
    echo "start=$(date -Is)"
  } > "$d/scenario.txt"
  [[ "$app" =~ ^[0-9]+$ ]] || { log "STOP: app bytes '$app'"; return 1; }
  for k in 0 1; do
    G $k status > "$d/status-pre-vm$k.txt" || { log "STOP: status pre vm$k failed"; return 1; }
    test -z "$(on $k 'pgrep -a -x faultlat || true')" || { log "STOP: faultlat already running on vm$k"; return 1; }
    on $k 'dmesg | wc -l' > "$d/dmesg-lines-pre-vm$k.txt" || { log "STOP: dmesg vm$k failed"; return 1; }
    gcmd $k "$rid" "$name" "$T" "$H" "$R0" "$R1" "$dist" "$D" "$off" "$a0" "$a1" "$app" > "$d/cmd-vm$k.txt"
  done
  log "scenario $name: T=$T H=$H R=$R0/$R1 $dist D=${D}s pages [$off,+$H) extra '$extra'"
  lim=$(( D + SCEN_TIMEOUT_EXTRA ))
  timeout "$lim" $SSH -T "${FLAGS[@]}" "comsys@${IP[1]}" "$(cat "$d/cmd-vm1.txt")" < /dev/null > "$d/run-vm1.log" 2>&1 & p1=$!
  timeout "$lim" $SSH -T "${FLAGS[@]}" "comsys@${IP[0]}" "$(cat "$d/cmd-vm0.txt")" < /dev/null > "$d/run-vm0.log" 2>&1 || rc0=$?
  wait "$p1" || rc1=$?
  echo "end=$(date -Is)" >> "$d/scenario.txt"
  if [ "$rc0" != 0 ] || [ "$rc1" != 0 ]; then
    wait_no_faultlat && log "faultlat gone on both guests" || log "faultlat still running after 120 s"
  fi
  for k in 0 1; do
    G $k status > "$d/status-post-vm$k.txt" || ok=1
    on $k "dmesg | tail -n +\$(( $(cat "$d/dmesg-lines-pre-vm$k.txt") + 1 ))" > "$d/dmesg-new-vm$k.txt" || true
    grep -E "$BADPAT" "$d/dmesg-new-vm$k.txt" > "$d/dmesg-bad-vm$k.txt" || true
    mkdir -p "$d/vm$k"
    $SCP -q "${FLAGS[@]}" "comsys@${IP[$k]}:/home/comsys/popcorn-results/${RUNTAG:-$(basename "$R")}/$name/*" "$d/vm$k/" || true
  done
  for k in 0 1; do
    accept "$d" $k >> "$d/accept.txt" 2>&1 || ok=1
    [ ! -s "$d/dmesg-bad-vm$k.txt" ] || { echo "vm$k FAIL dmesg: $(wc -l < "$d/dmesg-bad-vm$k.txt") bad lines" >> "$d/accept.txt"; ok=1; }
  done
  { echo "rc0=$rc0"; echo "rc1=$rc1"; echo "accept=$([ "$ok" = 0 ] && echo OK || echo FAIL)"; } > "$d/rc.txt"
  python3 -I "$B/stress_summary.py" "$R" > "$R/summary.csv" || true
  cat "$d/accept.txt" | sed "s/^/  /" | tee -a "$R/steps.log"
  if [ "$rc0" != 0 ] || [ "$rc1" != 0 ] || [ "$ok" != 0 ]; then
    log "STOP: scenario $name failed (rc $rc0/$rc1, acceptance $([ "$ok" = 0 ] && echo OK || echo FAIL)); next: teardown"
    return 1
  fi
  log "scenario $name PASS"
}

case "${1:-}" in
list)
  : "${2:?scenario file}"
  B=${B:-$here}
  while IFS= read -r l; do
    IFS='|' read -r name T H R0 R1 dist D off a0 a1 extra <<< "$l"
    app=$(appbytes "$T" "$H" 2>/dev/null || echo '<app-bytes>')
    for k in 1 0; do echo "vm$k: $(gcmd $k '<run-id>' "$name" "$T" "$H" "$R0" "$R1" "$dist" "$D" "$off" "$a0" "$a1" "$app")"; done
  done < <(parse "$2") ;;
install)
  need
  for k in 0 1; do
    on $k "test ! -e $GS && mkdir -m 0700 $GS"
    $SCP -q "${FLAGS[@]}" "$B/faultlat" "$B/run.sh" "$B/cxl_region.yaml" "$B/tools.sha256" "comsys@${IP[$k]}:$GS/"
    on $k "cd $GS && sha256sum -c tools.sha256" | tee "$R/install-vm$k.txt"
    on $k "cmp $GS/cxl_region.yaml $GT/cxl_region.yaml && echo region-same"  | tee -a "$R/install-vm$k.txt"
    grep -qx 'region-same' "$R/install-vm$k.txt"
  done
  log "install PASS ($GS on both guests)" ;;
precheck)
  need
  ! pgrep -x 'make|cc1|cc1plus|ld' > /dev/null || log "note: Host build processes running (recorded per scenario)"
  for k in 0 1; do
    test "$(on $k 'uname -r')" = "$K"
    on $k "cd $GS && sha256sum --quiet -c tools.sha256"
    G $k status > "$R/status-precheck-vm$k.txt"
    s=$R/status-precheck-vm$k.txt
    grep -qx "release=$K loaded=1" "$s"
    grep -qx "param.recv_mode=$RECV_MODE" "$s"
    grep -qx 'param.nr_nodes=2' "$s"
    grep -qx "param.init_state=$INIT_STATE" "$s"
    grep -qx 'dax0.0=comsys:root 600' "$s"
    grep -qx 'swmc.in_flight_transaction_count=0' "$s"
    if [ "$ENABLED" = 1 ]; then ! grep -qx 'swmc.managed_bytes=0' "$s"; else grep -qx 'swmc.managed_bytes=0' "$s"; fi
    test -z "$(on $k "pgrep -a -x 'faultlat|vdb-server' || true")"
  done
  log "stress precheck PASS (init_state $INIT_STATE, enabled $ENABLED, recv_mode $RECV_MODE)" ;;
preload)
  need; : "${2:?scenario file}" "${SALT:?SALT}"
  [ "$INIT_STATE" = shared ] || { echo "preload needs INIT_STATE=shared"; exit 2; }
  G 0 status > "$R/status-preload-vm0.txt"
  grep -qx 'swmc.managed_bytes=0' "$R/status-preload-vm0.txt"   # coherence still off: plain mapping
  grep -qx 'swmc.init_state=shared' "$R/status-preload-vm0.txt"
  while IFS='|' read -r name T H R0 R1 dist D off a0 a1 extra; do
    on 0 "CXL_REGION_CONFIG=$GS/cxl_region.yaml $GS/faultlat contend --init-only --pages $H --page-offset $off --salt $SALT" \
      | tee -a "$R/preload.log"
  done < <(parse "$2")
  test -z "$(on 0 'pgrep -x faultlat || true')"
  log "preload PASS (init stamps, salt $SALT)" ;;
run)
  need; : "${2:?scenario file}"
  [ -f "$2" ] || { echo "scenario file $2 not found"; exit 2; }
  test ! -e "$R/scenarios.parsed" || { echo "$R already has a run (scenarios.parsed); use a new R"; exit 2; }
  cp "$2" "$R/$(basename "$2")"
  parse "$R/$(basename "$2")" > "$R/scenarios.parsed"
  [ -s "$R/scenarios.parsed" ] || { echo "no scenarios in $2"; exit 2; }
  while IFS= read -r l; do run_one "$l" || exit 1; done < "$R/scenarios.parsed"
  log "run PASS ($(wc -l < "$R/scenarios.parsed") scenarios from $(basename "$2"))" ;;
diag)
  # after a failed scenario, before teardown: read-only evidence (kernel stacks of any faultlat left, dmesg, status)
  need; dg=$R/diag-$(date +%H%M%S); mkdir -m 0700 "$dg"
  for k in 0 1; do
    on $k 'for p in $(pgrep -x faultlat); do echo "== pid $p"; for t in /proc/$p/task/*; do echo "-- $t $(cat $t/comm) $(cut -d" " -f3 $t/stat) wchan=$(cat $t/wchan)"; sudo -n cat $t/stack; done; done' > "$dg/stacks-vm$k.txt" 2>&1 || true
    on $k 'dmesg | tail -n 300' > "$dg/dmesg-tail-vm$k.txt" 2>&1 || true
    G $k status > "$dg/status-vm$k.txt" 2>&1 || true
  done
  log "diag recorded in $dg" ;;
soak-pick)
  : "${2:?summary.csv}" "${3:?out}"
  # worst point of part (1) = ww-* scenario with the largest write max latency (ties: lowest Jain fairness)
  python3 -I - "$2" "$3" "${SOAK_S:-1800}" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r['scenario'].startswith('ww-') and r['write_max_ns']]
if not rows: sys.exit('no ww-* rows with latency')
r = max(rows, key=lambda r: (int(r['write_max_ns']), -float(r['jain_all'] or 1)))
open(sys.argv[2], 'w').write('soak-%s %s %s %s %s %s %s %s\n' % (r['scenario'], r['threads'], r['pages'], r['read_pct0'],
                             r['read_pct1'], r['dist'], sys.argv[3], r['extra']))
print('soak point:', r['scenario'], 'write_max_ns', r['write_max_ns'], 'jain', r['jain_all'])
PY
  cat "$3" ;;
summary)
  : "${R:?}"; B=${B:-$here}
  python3 -I "$B/stress_summary.py" "$R" > "$R/summary.csv"; column -s, -t < "$R/summary.csv" | cut -c1-220 ;;
*) awk 'NR > 1 && !/^#/ {exit} NR > 1' "$0"; exit 2 ;;
esac
