#!/bin/bash
# Pretouch gate (standing rule, user 2026-10-17, state/TASKS.md grant F extension (2)): after every QEMU start and
# before any measurement, the whole /dev/dax0.0 of each VM must have been pre-touched once (reports/ENV-pretouch-packet.md,
# tool scripts/guest/dax-pretouch.py). Host-only and read-only: no SSH, no sudo, no virsh.
# usage: pretouch-gate.sh <pretouch evidence dir (recovery/ENV-pretouch-*)> [<log file>]
# PASS (exit 0, "PRETOUCH GATE PASS") iff for k = 0 and 1:
#   - /run/libvirt/qemu/cxl_vm<k>.pid names a live process whose command line contains "guest=cxl_vm<k>," (QEMU);
#   - <dir>/pretouch-vm<k>.txt has the line "PRETOUCH DONE pages=<PAGES>" and a line "first total pages=<PAGES> ..."
#     (PAGES = env PRETOUCH_PAGES, default 25161216 = 103060340736 / 4096, the dax0.0 size after the 2026-10-17
#     devdax restore) and its mtime is later than that QEMU process's start time (pretouch after the last QEMU start);
#   - <dir>/steps.log has the run script's "T<k> DONE" line (chown back, tool removed, post checks done);
#   - <dir>/steps.log has no "STOP:" line.
# Else "PRETOUCH GATE FAIL <reason>", exit 1. Every result line is also appended to <log file> if given.
set -uo pipefail
D=${1:?usage: pretouch-gate.sh <pretouch evidence dir> [log]} LOG=${2:-/dev/null}
PAGES=${PRETOUCH_PAGES:-25161216}
RUN=${QEMU_RUN_DIR:-/run/libvirt/qemu}   # override only for the Host self-test
out() { echo "$*"; echo "$(date -Is) $*" >> "$LOG"; }
fail() { out "PRETOUCH GATE FAIL $*"; exit 1; }
[ -d "$D" ] || fail "no evidence dir $D"
[ -f "$D/steps.log" ] || fail "no $D/steps.log"
! grep -q "STOP:" "$D/steps.log" || fail "$D/steps.log has a STOP line"
for k in 0 1; do
  pf=$RUN/cxl_vm$k.pid
  pid=$(cat "$pf" 2>/dev/null) || fail "cxl_vm$k: no pid file $pf"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "cxl_vm$k: bad pid '$pid'"
  tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | grep -q "guest=cxl_vm$k," || fail "cxl_vm$k: pid $pid is not its QEMU"
  st=$(date -d "$(ps -o lstart= -p "$pid")" +%s 2>/dev/null) || fail "cxl_vm$k: no start time for pid $pid"
  [[ "$st" =~ ^[0-9]+$ ]] || fail "cxl_vm$k: bad start time"
  f=$D/pretouch-vm$k.txt
  [ -f "$f" ] || fail "cxl_vm$k: no $f"
  grep -qx "PRETOUCH DONE pages=$PAGES" "$f" || fail "cxl_vm$k: no 'PRETOUCH DONE pages=$PAGES' in $f"
  grep -q "^first total pages=$PAGES " "$f" || fail "cxl_vm$k: no 'first total pages=$PAGES' in $f"
  mt=$(stat -c %Y "$f")
  [ "$mt" -gt "$st" ] || fail "cxl_vm$k: pretouch ($(date -d @$mt -Is)) not after the QEMU start ($(date -d @$st -Is))"
  grep -q " T$k DONE" "$D/steps.log" || fail "cxl_vm$k: no 'T$k DONE' in $D/steps.log"
  out "pretouch cxl_vm$k: qemu pid $pid started $(date -d @$st -Is), pretouch done $(date -d @$mt -Is) ($f)"
done
out "PRETOUCH GATE PASS ($D)"
