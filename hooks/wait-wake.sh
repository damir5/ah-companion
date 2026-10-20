#!/bin/sh
# asyncRewake waiter (claude only): background long-poll of the daemon's wait.
# When an AH message arrives, exit 2 with the message on stderr — claude wakes
# and reacts to it as a system reminder. One message per run; the daemon wait
# is re-armed on every timeout while the session lives. SessionStart, every
# UserPromptSubmit and every Stop start a run, so the next hook after a wake
# arms the next one. A run that finds another waiter for the same session
# exits at once.
# stdin: hook JSON {session_id, prompt?}
set -u
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
[ -n "$STATE" ] || exit 0
# The async waiter can start before the session is registered: SessionStart
# and ah-on register in a synchronous hook that runs alongside it, /ah:on in
# a bash command later in that turn. Poll for the state before giving up.
TRIES=10
case $(printf '%s' "$INPUT" | jq -r '.prompt // empty') in
	/ah:on|"/ah:on "*) TRIES=120 ;;
esac
while [ ! -f "$STATE" ] && [ "$TRIES" -gt 0 ]; do
	sleep 1
	TRIES=$((TRIES - 1))
done
[ -f "$STATE" ] || exit 0
exec "$AHC" wake-wait "$SESSION_ID"
