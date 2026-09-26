#!/bin/sh
# Stop hook — semantic boundary delivery (claude + codex).
# If AH mail is pending when the turn ends, block the stop with the first
# message so the harness processes it as the continuation of the turn.
# stdin: hook JSON {session_id}
set -eu
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

PENDING=$("$AHC" pending "$TOKEN" 2>/dev/null || true)
FIRST=$(printf '%s' "$PENDING" | jq -c '[.. | objects | select(.body? != null)] | .[0] // empty' 2>/dev/null || true)
[ "$FIRST" != "" ] && [ "$FIRST" != "null" ] || exit 0

MID=$(printf '%s' "$FIRST" | jq -r '.id // empty')
SENDER=$(printf '%s' "$FIRST" | jq -r '.sender_id // .from // "ah"')
BODY=$(printf '%s' "$FIRST" | jq -r '.body' | head -c 4000)
[ -n "$MID" ] && "$AHC" ack "$TOKEN" "$MID" >/dev/null 2>&1 || true

printf '{"decision":"block","reason":"[From %s via Agent Hub]\\n%s"}' "$SENDER" "$BODY"
exit 0
