---
description: Disconnect this session from Agent Hub and stop registering new sessions in this project
---

Disable Agent Hub for this session and project. Run this bash:

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
SID="${CLAUDE_SESSION_ID}"
rm -f "$(python3 "$AHC" project-marker "$(pwd)")"
if [ -z "$SID" ]; then
  echo "project switched off; this session could not be identified, so type /ah-off to disconnect it"
elif [ -f "$(python3 "$AHC" state-path "$SID")" ]; then
  python3 "$AHC" end "$SID" >/dev/null 2>&1; rm -f "$(python3 "$AHC" state-path "$SID")"; echo "disconnected"
else
  echo "project switched off; this session was not registered"
fi
```

Tell the user the result. New sessions in this project will not register. To reconnect they can use `/ah:on` or type `/ah-on`.
