#!/bin/bash
# Measurement hygiene on the Host (reports/M4-vdb-packet.md §2.4).
# usage: host-gate.sh lock <owner>       create the measurement lock (fails if it exists)
#        host-gate.sh unlock <owner>     remove it (only if <owner> holds it)
#        host-gate.sh check <log file>   wait until the Host is quiet, append every probe to <log file>
# Lock: $LOCK (default /home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock), one line
# "owner=<owner> pid=<pid> start=<iso time>". Other agents must not start Host builds or heavy jobs (index builds,
# GT, data preparation, Host tests) while it exists (rule handed to them by the main session).
# Quiet = no compiler/build tool running (same pattern as run.sh), 1-min load average <= LOAD_MAX (default 4; the
# VMs are idle between runs), and no process above CPU_MAX % (default 25) over a 5 s top sample except commands
# matching GATE_IGNORE (regex, default ^qemu-system; recorded in the log).
# Waits up to GATE_WAIT_S (default 1800) re-probing every 60 s; exit 1 if still not quiet.
set -uo pipefail
LOCK=${LOCK:-/home/comsys/sungsu/destijl-control/workspaces/MEASUREMENT.lock}
LOAD_MAX=${LOAD_MAX:-4} CPU_MAX=${CPU_MAX:-25} GATE_WAIT_S=${GATE_WAIT_S:-1800} GATE_IGNORE=${GATE_IGNORE:-^qemu-system}
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
      builds=$(pgrep -a -x 'make|cc1|cc1plus|ld|ld.gold|lld|cargo|rustc|ninja|cmake|conan' | tr '\n' ';')
      load=$(cut -d' ' -f1 /proc/loadavg)
      hot=$(top -b -n 2 -d 5 -w 200 | awk -v m="$CPU_MAX" -v ign="$GATE_IGNORE" '/^top -/{n++} n==2 && $1 ~ /^[0-9]+$/ && $9+0 > m && $12 !~ ign && $12 != "top" {printf "%s:%s:%s%%;", $1, $12, $9}')
      ok=1
      [ -z "$builds" ] || ok=0
      awk -v l="$load" -v m="$LOAD_MAX" 'BEGIN{exit !(l <= m)}' || ok=0
      [ -z "$hot" ] || ok=0
      echo "$(date -Is) gate ok=$ok ignore=$GATE_IGNORE load1=$load builds=[$builds] hot=[$hot] lock=[$(cat "$LOCK" 2>/dev/null)]" >> "$LOG"
      [ $ok = 1 ] && exit 0
      [ "$(date +%s)" -lt $deadline ] || { echo "host gate: not quiet after ${GATE_WAIT_S}s (see $LOG)"; exit 1; }
      sleep 60
    done;;
  *) sed -n 2,4p "$0" >&2; exit 2;;
esac
