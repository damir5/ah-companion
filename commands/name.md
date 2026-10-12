---
description: Name this session on Agent Hub (registers it if needed; what ah send --dm targets)
---

The user wants to rename this session's Agent Hub slug to the value in $ARGUMENTS.

Run exactly this bash (replace SLUG with $ARGUMENTS, stripped of whitespace and quotes):

```bash
AHC="${CLAUDE_PLUGIN_ROOT}/hooks/ahc.py"
python3 "$AHC" rename "${CLAUDE_SESSION_ID}" "SLUG"
```

An unregistered session is registered under SLUG. If another live session holds SLUG, the result is `identity_unavailable`; ask for another name.
Report the JSON result. On ok:true, the fleet can now reach this session as `ah send --dm SLUG`.
If the user gave no slug, ask for one (lowercase letters, digits and dashes only).
