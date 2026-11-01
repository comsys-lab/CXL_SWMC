#!/usr/bin/env bash
# PreToolUse(SendMessage): a session may always message the subagents it spawned itself.
# Messages to OTHER SESSIONS (uds:/... sockets, session titles) are denied by default, because in
# 10-14..10-19 they turned forks into second orchestrators negotiating roles with main (600+ messages).
# Switch: create state/ALLOW_SESSION_MESSAGES to turn this into log-only (messages pass, each is logged
# to state/ALERTS.log so the user can see the traffic). Delete the file to deny again.
P=/home/comsys/sungsu/destijl-control
in=$(cat)
to=$(printf '%s' "$in" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("to",""))' 2>/dev/null)
case "$to" in
  a[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) exit 0 ;;   # own subagent id
esac
if [ -e "$P/state/ALLOW_SESSION_MESSAGES" ]; then
  printf '%s session-message to %s\n' "$(date -u +%FT%TZ)" "$to" >> "$P/state/ALERTS.log"; exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Cross-session messages are off (state/ALLOW_SESSION_MESSAGES absent). Host-busy coordination: use workspaces/MEASUREMENT.lock + Monitor. Decisions/status: write state/HANDOFF or the experiment document; the user tells the other session to re-read."}}\n'
exit 0
