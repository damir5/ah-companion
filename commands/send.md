---
description: Send an Agent Hub DM to another agent session from this pane's identity
---

The user wants to send an Agent Hub message to another agent. $ARGUMENTS holds `<target-slug> <message...>`.

Run exactly this bash:

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
SESSION_FILE=$(python3 "$AHC" state-path "${CLAUDE_SESSION_ID}")
SID=$(jq -r .session_id "$SESSION_FILE")
TARGET=$(echo "$ARGUMENTS" | awk '{print $1}')
BODY=$(echo "$ARGUMENTS" | cut -s -d' ' -f2-)
python3 "$AHC" send "$SID" "$TARGET" "$BODY"
```

Report the JSON result. On ok:true the message was delivered under THIS session's identity — no separate ah login needed. Replies from the peer arrive back in this conversation automatically (labeled `[From <peer> via Agent Hub]`).
If target or body is missing, ask which agent slug to message (see the fleet roster via `/ah:status`).
