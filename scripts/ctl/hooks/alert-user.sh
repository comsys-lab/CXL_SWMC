#!/usr/bin/env bash
# Notification(permission_prompt|idle_prompt): the harness is waiting on the user. Make it visible
# outside the terminal so hardware never idles unnoticed (the 10 h and 15 h losses of 10-16..10-19).
P=/home/comsys/sungsu/destijl-control
in=$(cat)
msg=$(printf '%s' "$in" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("notification_type",""), (d.get("message") or "")[:300].replace("\n"," "))' 2>/dev/null)
ts=$(date -u +%FT%TZ)
printf '%s %s\n' "$ts" "$msg" >> "$P/state/ALERTS.log"
# Desktop / phone channels: fill in whichever exists. Examples (uncomment one):
# notify-send "Claude Code waiting" "$msg" 2>/dev/null
curl -s -m 5 -H "Title: Claude Code is waiting" -H "Priority: high" -d "$msg" https://ntfy.sh/destijl-claude-22a453a5a3a1 >/dev/null 2>&1 || true
# ssh <laptop> osascript -e "display notification \"$msg\" with title \"Claude Code\""
exit 0
