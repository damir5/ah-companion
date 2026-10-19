---
description: Connect this session to Agent Hub; /ah:on <name> also names or renames it (what ah send --dm targets)
---

Connect this session to Agent Hub. $ARGUMENTS is an optional name. Run this bash, replacing NAME with $ARGUMENTS stripped of whitespace and quotes (leave it empty when no name was given):

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
SID="${CLAUDE_SESSION_ID}"
NAME=""
STATE=$(python3 "$AHC" state-path "$SID")
if [ -n "$NAME" ]; then
  python3 "$AHC" rename "$SID" "$NAME"
elif [ -f "$STATE" ]; then
  echo "already connected as: $(jq -r .slug "$STATE")"
else
  printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$(pwd)" | AH_COMPANION_AUTOREGISTER=1 CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" sh "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
  if [ -f "$STATE" ]; then echo "connected as: $(jq -r .slug "$STATE")"; else echo "connection failed; check that the ah daemon is running (ah status), then run /ah:on again"; fi
fi
```

Tell the user the result. With a name, report the JSON result: on ok:true the fleet reaches this session as `ah send --dm NAME`; `identity_unavailable` means another live session holds that name, so ask for another. Names use lowercase letters, digits, and dashes. Only this session connects; other sessions stay disconnected until they run `/ah:on`.
