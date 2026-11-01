#!/usr/bin/env bash
# PreToolUse(Bash|Edit|Write): block writes to frozen evidence (existing recovery/ files), original repos,
# the verified baseline and reports/archive. Exit 0 always; a deny is expressed in the JSON output.
P=/home/comsys/sungsu/destijl-control
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"; exit 0; }
in=$(cat)
tool=$(printf '%s' "$in" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null)
target=$(printf '%s' "$in" | python3 -I -c 'import json,sys; i=json.load(sys.stdin).get("tool_input",{}); print(i.get("file_path") or i.get("command","").replace("\n"," ")[:2000])' 2>/dev/null)
frozen='(/home/comsys/sungsu/(CXL_SWMC|CXLSharedMemVM|CXLSHMSWcoherence)/|workspaces/destijl-authoritative-122d22dc-v1/|reports/archive/)'
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    printf '%s' "$target" | grep -Eq "$frozen" && deny "frozen path (original repo / verified baseline / archive)"
    if printf '%s' "$target" | grep -Eq "^$P/recovery/[^/]+/" && [ -e "$target" ]; then
      deny "existing recovery/ files are frozen evidence; create a new recovery/<id>-vN dir instead"; fi ;;
  Bash)
    printf '%s' "$target" | grep -Eq "(sed -i|tee |>>?|cp |mv |rm |rsync )[^;&|]*$frozen" && deny "write into a frozen path (original repo / baseline / archive)"
    if printf '%s' "$target" | grep -Eq "(sed -i|rm -r?f?|rm |mv |> ?)[^;&|]*$P/recovery/[^ /]+/[^ ]+\.(sh|md|txt|yaml|json|csv|sha256|log)"; then
      deny "modifying an existing recovery/ file; add a new versioned dir instead"; fi ;;
esac
exit 0
