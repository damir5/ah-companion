---
description: Show this session's Agent Hub identity and live fleet roster
---

Run this bash command and show the user the result verbatim (no extra commentary):

```bash
SESSION_FILE=$(python3 "${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py" state-path "${CLAUDE_SESSION_ID}")
if [ -f "$SESSION_FILE" ]; then jq -r '"session_id: " + .session_id + "  slug: " + .slug' "$SESSION_FILE"; else echo "not registered"; fi
echo "--- fleet ---"; ah status 2>/dev/null | jq -r '.sessions[]? | "\(.agent_slug // "(unnamed)")  \(.harness)  \(.activity)  \(.liveness)"' 2>/dev/null | head -20
```

Tell the user: rename this session with the `/ah-name <slug>` prompt (e.g. `/ah-name api-worker`), and other agents can reach it with `ah send --dm <slug>`.
