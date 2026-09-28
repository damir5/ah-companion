---
description: Rename this session's Agent Hub identity (what ah send --dm targets)
---

The user wants to rename this session's Agent Hub slug to the value in $ARGUMENTS.

Run exactly this bash (replace SLUG with $ARGUMENTS, stripped of whitespace and quotes):

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
SESSION_FILE=$(python3 "$AHC" state-path "${CLAUDE_SESSION_ID}")
SID=$(jq -r .session_id "$SESSION_FILE")
python3 "$AHC" rename "$SID" "SLUG"
```

Report the JSON result. On ok:true, the fleet can now reach this session as `ah send --dm SLUG`.
If the user gave no slug, ask for one (lowercase letters, digits and dashes only).
