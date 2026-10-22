#!/bin/sh
# UserPromptSubmit hook (claude + codex): report the session working and
# drain pending AH mail into the turn as additional context; the next hook
# acks what was delivered (see ahc.py deliver).
# stdin: hook JSON {session_id, prompt, cwd}
set -eu
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

# ah-on [name] and ah-off connect or disconnect only this session. Both
# harnesses: codex has no plugin slash commands, so these words are its only
# way to do this from inside. The codex TUI rejects unknown "/..." input before
# hooks run, so the words have no "/".
# A blocked Codex prompt runs no turn, so Codex sends no Stop and herdr would
# show the pane working until the next turn ends; herdr-idle resets it.
consumed() {
	[ "${AH_COMPANION_HARNESS:-}" = codex ] && "$AHC" herdr-idle "$SESSION_ID" >/dev/null 2>&1 || true
	exit 0
}
case "$PROMPT" in
	ah-on|"ah-on "*)
		NAME=$(printf '%s' "${PROMPT#ah-on}" | tr -d " \"'")
		if [ -n "$NAME" ]; then
			"$AHC" rename "$SESSION_ID" "$NAME" >/dev/null 2>&1 || true
		elif [ ! -f "$STATE" ]; then
			printf '%s' "$INPUT" | AH_COMPANION_AUTOREGISTER=1 "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh"
		fi
		SLUG=$(jq -r '.slug // empty' "$STATE" 2>/dev/null || true)
		NOTE=""
		if [ "$(jq -r '.shared_daemon // false' "$STATE" 2>/dev/null)" = true ]; then
			NOTE=" Warning: this Codex runs under the shared codex app-server daemon, so Agent Hub sees the daemon, not this pane (Drover cannot find the pane; the session ends only with the daemon). Start codex with --no-daemon to fix this."
		fi
		if [ -n "$SLUG" ] && { [ -z "$NAME" ] || [ "$SLUG" = "$NAME" ]; }; then
			jq -cn --arg slug "$SLUG" --arg note "$NOTE" '{decision:"block",reason:("[Agent Hub] connected as "+$slug+"."+$note)}'
		elif [ -n "$NAME" ] && [ -n "$SLUG" ]; then
			jq -cn --arg slug "$SLUG" --arg name "$NAME" '{decision:"block",reason:("[Agent Hub] could not use the name "+$name+" (another live session may hold it); still connected as "+$slug+".")}'
		else
			printf '{"decision":"block","reason":"[Agent Hub] connection failed; check that the ah daemon is running (ah status), then try again."}'
		fi
		consumed
		;;
	ah-off)
		"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
		rm -f "$STATE" 2>/dev/null || true
		printf '{"decision":"block","reason":"[Agent Hub] disconnected. Claude: /ah:on to reconnect; Codex: type ah-on."}'
		consumed
		;;
esac

[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

"$AHC" activity "$SESSION_ID" working >/dev/null 2>&1 || true
"$AHC" flush-children "$SESSION_ID" >/dev/null 2>&1 || true

# Pending mail that fits the delivery budget is attached as context; the rest
# stays pending for the next delivery point.
CONTEXT=$("$AHC" deliver "$SESSION_ID" 2>/dev/null || true)
if [ -n "$CONTEXT" ]; then
	jq -cn --arg context "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("[Agent Hub mail]\n"+$context)}}'
fi
exit 0
