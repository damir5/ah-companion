---
description: Connect this session to Agent Hub and register new sessions in this project automatically
---

Switch Agent Hub on for this project and register this session. Run this bash:

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
SID="${CLAUDE_SESSION_ID}"
touch "$(python3 "$AHC" project-marker "$(pwd)")"
if [ -z "$SID" ]; then
  echo "project switched on; this session registers on your next prompt"
else
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$(pwd)" | CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" sh "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
  STATE=$(python3 "$AHC" state-path "$SID")
  if [ -f "$STATE" ]; then echo "registered as: $(jq -r .slug "$STATE")"; else echo "project switched on, but registration failed; check that the ah daemon is running (ah status). Your next prompt retries."; fi
fi
```

Tell the user the result. New sessions in this project register at start until `/ah:off`.
