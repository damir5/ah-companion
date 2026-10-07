#!/bin/sh
# asyncRewake waiter (claude only): background long-poll of the daemon's wait.
# When an AH message arrives, exit 2 with the message on stderr — claude wakes
# and reacts to it as a system reminder. One message per run; re-armed by the
# next SessionStart/Stop hook firing.
# stdin: hook JSON {session_id}
set -u
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
# The async waiter can start before the synchronous SessionStart hook has
# written the registration state — poll briefly for it before giving up.
STATE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
	if [ -n "$STATE" ] && [ -f "$STATE" ]; then break; fi
	sleep 1
done
[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

RESP=$("$AHC" wait "$TOKEN" 1700 2>/dev/null || true)
STATUS=$(printf '%s' "$RESP" | jq -r '.status // empty' 2>/dev/null || true)
[ "$STATUS" = "message" ] || exit 0

MSG=$(printf '%s' "$RESP" | jq -c '.message // empty' 2>/dev/null || true)
MID=$(printf '%s' "$MSG" | jq -r '.id // empty')
SENDER=$(printf '%s' "$MSG" | jq -r '.sender_id // .from // "ah"')
BODY=$(printf '%s' "$MSG" | jq -r '.body // empty' | head -c 4000)
[ -n "$MID" ] && "$AHC" ack "$TOKEN" "$MID" >/dev/null 2>&1 || true

# exit 2 = wake claude; stderr becomes the system reminder it reacts to
printf '[From %s via Agent Hub]\n%s\n' "$SENDER" "$BODY" >&2
exit 2
