#!/bin/bash
# Start a measurement process (loadgen) inside measure.slice (reports/H1-main-packet.md §env; scripts/host/
# measure-env-part.sh). After the partition, user.slice may only use 18-23,50-55, so a loadgen started from the harness
# (user.slice) cannot reach its LG_CPUS (56-63) without this launcher: `numactl --physcpubind=56-63` then fails.
# usage: measure-run.sh [--env K=V]... -- <command> [args...]
#   Runs `sudo -n systemd-run --scope --slice=measure.slice` (the SYSTEM manager: a --user scope would sit below
#   user.slice and inherit its CPU set), drops back to the calling user with setpriv, re-checks inside the scope that
#   its cgroup is below /measure.slice/ and its allowed CPUs are within measure.slice's AllowedCPUs, then execs the
#   command in the caller's working directory with a clean environment (HOME USER LOGNAME PATH LANG + every --env).
#   Needs non-interactive sudo for systemd-run (sudo -n; a password prompt is never waited for).
# Fail closed: if sudo, systemd-run or the in-scope check fails, the command is NOT run; exit 125 with a
#   "MEASURE-RUN FAIL" line on stderr. Otherwise the exit status is the command's.
# Internal: measure-run.sh --inner <mark file> <cwd> -- <command...> (the in-scope part).
set -uo pipefail
SELF=$(readlink -f "$0")
if [ "${1:-}" = --inner ]; then
  MARK=$2 CWD=$3; shift 3; [ "${1:-}" = -- ] && shift
  cg=$(sed -n 's/^0:://p' /proc/self/cgroup)
  case "$cg" in /measure.slice/*) ;; *) echo "MEASURE-RUN FAIL: in-scope cgroup '$cg' is not below /measure.slice/" >&2; exit 125;; esac
  allowed=$(systemctl show -p AllowedCPUs --value measure.slice | tr ' ' ',')
  mine=$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status)
  python3 -I -c 'import sys
def s(x):
    o=set()
    for p in x.split(","):
        if p:
            a,_,b=p.partition("-"); o.update(range(int(a), int(b or a)+1))
    return o
a, m = s(sys.argv[1]), s(sys.argv[2])
sys.exit(0 if a and m and m <= a else 1)' "$allowed" "$mine" \
    || { echo "MEASURE-RUN FAIL: allowed CPUs '$mine' not within measure.slice AllowedCPUs '$allowed'" >&2; exit 125; }
  echo "scope=$cg cpus=$mine slice_cpus=$allowed" > "$MARK" || exit 125
  cd "$CWD" || { echo "MEASURE-RUN FAIL: cd $CWD" >&2; exit 125; }
  exec "$@"
fi
XENV=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  case $1 in --env) [[ ${2:-} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "MEASURE-RUN FAIL: bad --env '${2:-}'" >&2; exit 125; }
                    XENV+=("$2"); shift 2;;
             *) echo "MEASURE-RUN FAIL: usage: measure-run.sh [--env K=V]... -- <command...>" >&2; exit 125;; esac
done
[ "${1:-}" = -- ] && [ $# -ge 2 ] || { echo "MEASURE-RUN FAIL: usage: measure-run.sh [--env K=V]... -- <command...>" >&2; exit 125; }
shift
[ "$(systemctl show -p ActiveState --value measure.slice)" = active ] || { echo "MEASURE-RUN FAIL: measure.slice not active (measure-env-part.sh apply)" >&2; exit 125; }
MARK=$(mktemp /tmp/measure-run.XXXXXX) || exit 125; rm -f "$MARK"
U=$(id -un) G=$(id -gn)
sudo -n systemd-run --quiet --scope --collect --slice=measure.slice --unit="h1-measure-$(date +%s)-$$" \
  -- setpriv --reuid="$U" --regid="$G" --init-groups \
  env -i HOME="$HOME" USER="$U" LOGNAME="$U" PATH="$PATH" LANG=C "${XENV[@]}" \
  bash "$SELF" --inner "$MARK" "$PWD" -- "$@"
RC=$?
if [ ! -s "$MARK" ]; then
  echo "MEASURE-RUN FAIL: scope not created or not verified (rc $RC); command not run" >&2; rm -f "$MARK"; exit 125
fi
rm -f "$MARK"
exit $RC
