#!/bin/sh
# SessionEnd hook (claude + codex): flush evidence and end the exact registration.
# stdin: hook JSON {session_id}
set -eu
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
# Sessions whose harness pid dies are reaped by the daemon anyway; this is
# best-effort cleanliness.
exit 0
