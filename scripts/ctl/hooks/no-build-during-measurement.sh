#!/usr/bin/env bash
# PreToolUse(Bash): Host builds while a measurement lock exists are allowed ONLY when confined to NUMA node 1.
# Policy (user decision 2026-11-01 23:5x, replaces the blanket "never build during a measurement"): the VMs are pinned
# to node 0 (vcpupin, numatune strict nodeset 0, /dev/dax1.0 node 0) and the sessions to node-1 CPUs 18-23,50-55
# during a measurement (measure-env-part.sh), so a build on node-1 CPUs with node-1 memory shares only the root LV
# with the VMs. Accepted forms while workspaces/MEASUREMENT.lock exists:
#   (a) the wrapper: `bash .../scripts/ctl/build-wrap.sh <build cmd>` (nice + ionice idle + numactl node 1);
#   (b) an explicit `numactl` with --membind=1 and a node-1 CPU binding (--cpunodebind=1 or --physcpubind= with
#       CPUs inside 16-31,48-63 only) and `nice` in the same command.
# Everything else that looks like a build is denied with the lock owner in the reason. MEASUREMENT_LOCK overrides the
# lock path for tests only.
P=/home/comsys/sungsu/destijl-control
LOCK=${MEASUREMENT_LOCK:-$P/workspaces/MEASUREMENT.lock}
in=$(cat)
cmd=$(printf '%s' "$in" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
[ -e "$LOCK" ] || exit 0
printf '%s' "$cmd" | grep -Eq '(^|[^a-zA-Z_-])(make|cargo (build|test)|cmake --build|ninja|gcc|g\+\+|clang|build[0-9]*\.sh)( |$)' || exit 0
deny() {
  owner=$(head -1 "$LOCK" 2>/dev/null)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"MEASUREMENT.lock present (%s): a Host build during a measurement must be confined to NUMA node 1: run it as `bash %s/CXL_SWMC/scripts/ctl/build-wrap.sh <cmd>` (or nice + numactl --membind=1 with a node-1 CPU set). %s"}}\n' "${owner//\"/}" "$P" "$1"
  exit 0
}
# (a) the wrapper
printf '%s' "$cmd" | grep -Eq '(^|[^a-zA-Z_./-])(bash +)?[^ ]*scripts/ctl/build-wrap\.sh( |$)' && exit 0
# (b) explicit node-1 binding
printf '%s' "$cmd" | grep -Eq '(^|[^a-zA-Z_-])nice( |$)' || deny "missing: nice"
printf '%s' "$cmd" | grep -Eq -- '--membind=1( |$)' || deny "missing: --membind=1"
if printf '%s' "$cmd" | grep -Eq -- '--cpunodebind=1( |$)'; then exit 0; fi
cpus=$(printf '%s' "$cmd" | grep -Eo -- '--physcpubind=[0-9,-]+' | head -1 | cut -d= -f2)
[ -n "$cpus" ] || deny "missing: --cpunodebind=1 or --physcpubind=<node-1 CPUs>"
python3 -I - "$cpus" <<'EOF' || deny "physcpubind must stay inside node 1 (16-31,48-63)"
import sys
ok = set(range(16, 32)) | set(range(48, 64))
want = set()
for part in sys.argv[1].split(','):
    a, _, b = part.partition('-')
    want.update(range(int(a), int(b or a) + 1))
sys.exit(0 if want and want <= ok else 1)
EOF
exit 0
