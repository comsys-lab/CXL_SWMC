#!/bin/bash
# Measurement hygiene on the Host (reports/M4-vdb-packet.md §2.4).
# usage: host-gate.sh lock <owner>       create the measurement lock (fails if it exists)
#        host-gate.sh unlock <owner>     remove it (only if <owner> holds it)
#        host-gate.sh check <log file>   wait until the Host is quiet, append every probe to <log file>
# Lock: $LOCK (default /home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock), one line
# "owner=<owner> pid=<pid> start=<iso time>". Other agents must not start Host builds or heavy jobs (index builds,
# GT, data preparation, Host tests) while it exists (rule handed to them by the main session).
# Quiet = no compiler/build tool running (same pattern as run.sh), 1-min load average <= LOAD_MAX (default 4; the
# VMs are idle between runs), and no process above CPU_MAX % (default 25) over a 5 s top sample except QEMU
# (command ^qemu-system) and the exact command names in GATE_IGNORE (comma list, e.g. cpptools; default empty).
# Ignored processes above CPU_MAX are logged with their CPU% (ignored=[...]).
# Waits up to GATE_WAIT_S (default 1800) re-probing every 60 s; exit 1 if still not quiet.
# Measurement environment: every probe first runs `scripts/host/measure-env.sh check $MEASURE_ENV_DIR` (no root;
# default dir recovery/HOST-measure-env-v1) and appends its full output to <log file> ("measure-env:" lines). The
# gate fails at once (exit 1, no waiting: the setting does not recover by itself) unless the output ends in
# CHECK PASS with exit 0 (C-states C1E/C6 off, IRQs, workqueues, slices, emulatorpin; vm_setting/README.md §5).
set -uo pipefail
LOCK=${LOCK:-/home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock}
MEASURE_ENV=${MEASURE_ENV:-$(cd "$(dirname "$0")/../.." && pwd)/scripts/host/measure-env.sh}
MEASURE_ENV_DIR=${MEASURE_ENV_DIR:-/home/comsys/sungsu/destijl-control/recovery/HOST-measure-env-v1}
LOAD_MAX=${LOAD_MAX:-4} CPU_MAX=${CPU_MAX:-25} GATE_WAIT_S=${GATE_WAIT_S:-1800} GATE_IGNORE=${GATE_IGNORE:-}
case "${1:-}" in
  lock)
    [ -n "${2:-}" ] || exit 2
    (set -o noclobber; echo "owner=$2 pid=$PPID start=$(date -Is)" > "$LOCK") 2>/dev/null \
      || { echo "lock held: $(cat "$LOCK" 2>/dev/null)"; exit 1; }
    echo "locked: $(cat "$LOCK")";;
  unlock)
    grep -q "^owner=${2:-} " "$LOCK" 2>/dev/null || { echo "lock not held by ${2:-}: $(cat "$LOCK" 2>/dev/null)"; exit 1; }
    rm -f "$LOCK" && echo "unlocked";;
  check)
    LOG=${2:?log file}
    deadline=$(( $(date +%s) + GATE_WAIT_S ))
    while :; do
      env_out=$(bash "$MEASURE_ENV" check "$MEASURE_ENV_DIR" 2>&1); env_rc=$?
      echo "$(date -Is) measure-env: check $MEASURE_ENV_DIR rc=$env_rc" >> "$LOG"
      printf '%s\n' "$env_out" | sed 's/^/measure-env: /' >> "$LOG"
      if [ $env_rc != 0 ] || [ "$(printf '%s\n' "$env_out" | tail -n1)" != "CHECK PASS" ]; then
        echo "$(date -Is) gate ok=0 measure_env=FAIL" >> "$LOG"
        echo "host gate: measure-env check did not pass (rc=$env_rc, see $LOG)"; exit 1
      fi
      builds=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' | tr '\n' ';')
      load=$(cut -d' ' -f1 /proc/loadavg)
      sample=$(top -b -n 2 -d 5 -w 200 | awk -v m="$CPU_MAX" -v ign=",$GATE_IGNORE," '/^top -/{n++}
        n==2 && $1 ~ /^[0-9]+$/ && $9+0 > m && $12 != "top" {
          t = sprintf("%s:%s:%s%%;", $1, $12, $9)
          if ($12 ~ /^qemu-system/ || index(ign, "," $12 ",")) ig = ig t; else hot = hot t }
        END {print hot "|" ig}')
      hot=${sample%%|*} ignored=${sample#*|}
      ok=1
      [ -z "$builds" ] || ok=0
      awk -v l="$load" -v m="$LOAD_MAX" 'BEGIN{exit !(l <= m)}' || ok=0
      [ -z "$hot" ] || ok=0
      echo "$(date -Is) gate ok=$ok measure_env=PASS load1=$load builds=[$builds] hot=[$hot] ignored=[$ignored] ignore_list=[$GATE_IGNORE] lock=[$(cat "$LOCK" 2>/dev/null)]" >> "$LOG"
      [ $ok = 1 ] && exit 0
      [ "$(date +%s)" -lt $deadline ] || { echo "host gate: not quiet after ${GATE_WAIT_S}s (see $LOG)"; exit 1; }
      sleep 60
    done;;
  *) sed -n 2,4p "$0" >&2; exit 2;;
esac
