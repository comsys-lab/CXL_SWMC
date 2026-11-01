#!/usr/bin/env bash
# SessionStart: print only what the model cannot get by following CLAUDE.md "Start of session"
# (which already reads HANDOFF/TASKS/EXPERIMENTS): pending user decisions and what is running now.
P=/home/comsys/sungsu/destijl-control
echo "=== 결정 대기 (state/HANDOFF.md) ==="
awk '/^## 결정 대기|^### 결정 대기/{f=1;next} /^## |^### /{f=0} f' "$P/state/HANDOFF.md" 2>/dev/null | head -15
echo "=== running now ==="
[ -e "$P/workspaces/MEASUREMENT.lock" ] && { echo "MEASUREMENT.lock:"; head -2 "$P/workspaces/MEASUREMENT.lock"; } || echo "no measurement lock"
pgrep -af 'chain-|run\.sh' | grep -v pgrep | head -5
[ -s "$P/state/ALERTS.log" ] && { echo "=== last alerts ==="; tail -3 "$P/state/ALERTS.log"; }
exit 0
