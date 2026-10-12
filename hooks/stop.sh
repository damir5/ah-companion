#!/bin/sh
# Stop hook — semantic boundary delivery (claude + codex).
# If AH mail is pending when the turn ends, block the stop with the first
# message so the harness processes it as the continuation of the turn.
# Only the delivered message is acked; the next stop delivers the next one.
# stdin: hook JSON {session_id}
set -eu
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

"$AHC" flush-children "$SESSION_ID" >/dev/null 2>&1 || true
TEXT=$("$AHC" deliver "$TOKEN" 1 2>/dev/null || true)
[ -n "$TEXT" ] || exit 0
jq -cn --arg text "$TEXT" '{decision:"block",reason:$text}'
exit 0
