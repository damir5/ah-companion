---
description: Disconnect this session from Agent Hub (stop receiving messages)
---

Disable Agent Hub for this session. Run this bash:

```bash
AHC="{{pluginPath}}/hooks/ahc.py"
SESSION_FILE=$(ls -t ~/.local/state/ah-companion/session-*.json 2>/dev/null | head -1)
if [ -n "$SESSION_FILE" ]; then SID=$(jq -r .session_id "$SESSION_FILE"); python3 "$AHC" end "$SID"; rm -f "$SESSION_FILE"; echo "disconnected"; else echo "not registered"; fi
```

Tell the user the session is disconnected. To reconnect they can type `ah-wake` or restart the session.
