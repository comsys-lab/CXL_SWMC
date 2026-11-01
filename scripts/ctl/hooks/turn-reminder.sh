#!/usr/bin/env bash
# UserPromptSubmit: one short line, re-injected every user turn so it survives compaction (~45 tokens).
P=/home/comsys/sungsu/destijl-control
lock=$([ -e "$P/workspaces/MEASUREMENT.lock" ] && echo "LOCK ON: Host builds only via scripts/ctl/build-wrap.sh (node 1); no session command text with experiments/eval/ or -chain" || echo "no lock")
echo "Korean reply, technical terms in English. Mechanical decisions: do+log, never ask; user away: default+log. $lock."
exit 0
