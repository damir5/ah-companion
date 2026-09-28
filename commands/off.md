---
description: Disconnect this session from Agent Hub and stop registering new sessions in this project
---

Disable Agent Hub for this session and project. Run this bash:

```bash
AHC="{{pluginPath}}/hooks/ahc.py"
rm -f "$(python3 "$AHC" project-marker "$(pwd)")"
SESSION_FILE=$(ls -t ~/.local/state/ah-companion/session-*.json 2>/dev/null | head -1)
if [ -n "$SESSION_FILE" ]; then SID=$(jq -r .session_id "$SESSION_FILE"); python3 "$AHC" end "$SID"; rm -f "$SESSION_FILE"; echo "disconnected"; else echo "not registered"; fi
```

Tell the user the session is disconnected and new sessions in this project will not register. To reconnect they can use `/ah:on` or type `/ah-on`.
