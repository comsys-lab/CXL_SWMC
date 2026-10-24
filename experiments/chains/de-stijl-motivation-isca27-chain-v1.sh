#!/bin/bash
# de-stijl-motivation-isca27 launch wrapper (reports/experiments/de-stijl-motivation-isca27.md; approved 2026-10-22).
# Starts ONE run k (1..3) of the whole set (Hypothesis 1 on 2 x 16 vCPU, then Hypothesis 2 on N = 2/4/8, restore, export)
# through workspaces/runs123/run-chain-v1.sh, detached, and returns at once (vmN phases refuse while another command
# line names a chain script). Extra args are passed through (e.g. --start h2:4 --h2-args "...").
# usage: bash de-stijl-motivation-isca27-chain-v1.sh <k> [--dry-run] [run-chain-v1.sh args...]
# log: workspaces/runs123/run<k>.log (real run); this wrapper's own lines: workspaces/de-stijl-motivation-isca27-chain.log
# Repo copy (experiments/chains/, README.md there) of workspaces/de-stijl-motivation-isca27-chain-v1.sh; only the paths
# are parameterised (same defaults): DESTIJL_ROOT [/home/comsys/sungsu/destijl-control] = P; EVAL2_RUN_DIR
# [$P/workspaces/runs123] (run<k>.log); MOTIVATION_LAUNCH_LOG [$P/workspaces/de-stijl-motivation-isca27-chain.log];
# run-chain-v1.sh = the copy next to this script.
P=${DESTIJL_ROOT:-/home/comsys/sungsu/destijl-control}
CH=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
R=${EVAL2_RUN_DIR:-$P/workspaces/runs123}
LOG=${MOTIVATION_LAUNCH_LOG:-$P/workspaces/de-stijl-motivation-isca27-chain.log}
K=${1:-}; shift || true
[[ $K =~ ^[1-3]$ ]] || { echo "usage: $0 <k 1..3> [--dry-run] [args]"; exit 2; }
if [[ " $* " == *" --dry-run "* ]]; then
  exec bash "$CH/run-chain-v1.sh" --run "$K" "$@"
fi
[ -e "$P/workspaces/MEASUREMENT.lock" ] && { echo "$(date -Is) STOP: MEASUREMENT.lock exists" | tee -a "$LOG"; exit 2; }
pgrep -x 'make|cc1|cc1plus|cargo|rustc|ld' >/dev/null && { echo "$(date -Is) STOP: Host build running" | tee -a "$LOG"; exit 2; }
git -C "$P/CXL_SWMC" merge-base --is-ancestor runs123 HEAD 2>/dev/null \
  || { echo "$(date -Is) STOP: live CXL_SWMC does not contain branch runs123 (merge first)" | tee -a "$LOG"; exit 2; }
[ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 0 ] \
  || { echo "$(date -Is) STOP: kernel.perf_event_paranoid > 0 (CXL sampler needs 0; user sets it)" | tee -a "$LOG"; exit 2; }
echo "$(date -Is) LAUNCH run $K: run-chain-v1.sh --run $K $* (live $(git -C "$P/CXL_SWMC" rev-parse --short=9 HEAD))" >> "$LOG"
export EVAL2_RUN_DIR=$R
setsid nohup bash "$CH/run-chain-v1.sh" --run "$K" "$@" > /dev/null 2>&1 < /dev/null &
echo "$(date -Is) launched run $K (pid $!); log $R/run$K.log" | tee -a "$LOG"
