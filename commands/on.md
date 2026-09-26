---
description: Reconnect this session to Agent Hub
---

Re-enable Agent Hub for this session. Run this bash:

```bash
AHC="{{pluginPath}}/hooks/ahc.py"
SESSION_FILE=$(ls -t ~/.local/state/ah-companion/session-*.json 2>/dev/null | head -1)
if [ -n "$SESSION_FILE" ]; then echo "already registered as: $(jq -r .slug "$SESSION_FILE")"; else
  # Re-register using the session id from the hook environment
  CWD=$(pwd); SLUG="claude-$(basename "$CWD" | tr -c 'a-z0-9-' '-' | sed 's/-*$//' | cut -c1-24)"
  echo "registration happens on the next SessionStart or Stop hook; type ah-wake to trigger it"
fi
```

Tell the user the result. If not yet registered, the next `ah-wake` or session restart will re-register.
