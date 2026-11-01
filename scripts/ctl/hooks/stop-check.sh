#!/usr/bin/env bash
# Stop: if a decision is pending for the user (HANDOFF "Needs user" block non-empty) or a chain is running,
# append a line to ALERTS.log so the user sees it when they return. Never blocks.
P=/home/comsys/sungsu/destijl-control
# HANDOFF names the block "## 결정 대기 (Needs user)"; match either spelling (the old '^## Needs user' never matched).
if grep -qE '^## (결정 대기|Needs user)' "$P/state/HANDOFF.md" 2>/dev/null; then
  n=$(sed -n '/^## \(결정 대기\|Needs user\)/,/^## /p' "$P/state/HANDOFF.md" | grep -c '^- [^(]' )
  [ "$n" -gt 0 ] && printf '%s stop: %s decision(s) pending for the user (state/HANDOFF.md "Needs user")\n' "$(date -u +%FT%TZ)" "$n" >> "$P/state/ALERTS.log"
fi
exit 0
