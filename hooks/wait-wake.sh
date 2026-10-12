#!/bin/sh
# asyncRewake waiter (claude only): background long-poll of the daemon's wait.
# When an AH message arrives, exit 2 with the message on stderr — claude wakes
# and reacts to it as a system reminder. One message per run; the daemon wait
# is re-armed on every timeout while the session lives, and the next Stop hook
# starts a new run after a wake. A run that finds another waiter for the same
# session exits at once.
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
exec "$AHC" wake-wait "$SESSION_ID"
