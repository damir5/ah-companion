---
description: Connect this session to Agent Hub and register new sessions in this project automatically
---

Switch Agent Hub on for this project and register this session. Run this bash:

```bash
AHC="{{pluginPath}}/hooks/ahc.py"
touch "$(python3 "$AHC" project-marker "$(pwd)")"
SID="${CLAUDE_SESSION_ID}"
STATE=$(python3 "$AHC" state-path "${SID:-none}")
if [ -n "$SID" ]; then
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$(pwd)" | CLAUDE_PLUGIN_ROOT="{{pluginPath}}" sh "{{pluginPath}}/hooks/session-start.sh"
fi
if [ -f "$STATE" ]; then echo "registered as: $(jq -r .slug "$STATE")"; else echo "project switched on; type /ah-on to register this session now"; fi
```

Tell the user the result. New sessions in this project register at start until `/ah:off`.
