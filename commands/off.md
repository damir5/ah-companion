---
description: Disconnect this session from Agent Hub
---

Disconnect this session from Agent Hub. Run this bash:

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
SID="${CLAUDE_SESSION_ID}"
if [ -z "$SID" ]; then
  echo "this session could not be identified; type ah-off to disconnect it"
elif [ -f "$(python3 "$AHC" state-path "$SID")" ]; then
  python3 "$AHC" end "$SID" >/dev/null 2>&1; rm -f "$(python3 "$AHC" state-path "$SID")"; echo "disconnected"
else
  echo "this session was not connected"
fi
```

Tell the user the result. To connect again, use `/ah:on` (optionally `/ah:on <name>`).
