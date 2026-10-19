#!/bin/sh
# UserPromptSubmit hook (claude + codex): drain pending AH mail into the turn
# as additional context; ack what was delivered. On claude, swallow the
# "ah-wake" nudge prompt so the daemon can wake an idle session with one
# tiny keystroke without polluting the conversation.
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
case "$PROMPT" in
	ah-on|"ah-on "*)
		NAME=$(printf '%s' "${PROMPT#ah-on}" | tr -d " \"'")
		if [ -n "$NAME" ]; then
			"$AHC" rename "$SESSION_ID" "$NAME" >/dev/null 2>&1 || true
		elif [ ! -f "$STATE" ]; then
			printf '%s' "$INPUT" | AH_COMPANION_AUTOREGISTER=1 "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh"
		fi
		SLUG=$(jq -r '.slug // empty' "$STATE" 2>/dev/null || true)
		if [ -n "$SLUG" ] && { [ -z "$NAME" ] || [ "$SLUG" = "$NAME" ]; }; then
			jq -cn --arg slug "$SLUG" '{decision:"block",reason:("[Agent Hub] connected as "+$slug+".")}'
		elif [ -n "$NAME" ] && [ -n "$SLUG" ]; then
			jq -cn --arg slug "$SLUG" --arg name "$NAME" '{decision:"block",reason:("[Agent Hub] could not use the name "+$name+" (another live session may hold it); still connected as "+$slug+".")}'
		else
			printf '{"decision":"block","reason":"[Agent Hub] connection failed; check that the ah daemon is running (ah status), then try again."}'
		fi
		exit 0
		;;
	ah-off)
		"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
		rm -f "$STATE" 2>/dev/null || true
		printf '{"decision":"block","reason":"[Agent Hub] disconnected. Claude: /ah:on to reconnect; Codex: type ah-on."}'
		exit 0
		;;
esac

[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

"$AHC" flush-children "$SESSION_ID" >/dev/null 2>&1 || true

# Pending mail that fits the delivery budget is rendered and acked; the rest
# stays pending for the next delivery point.
# claude wake-word: block the nudge prompt, deliver mail instead
if [ "${AH_COMPANION_HARNESS:-claude}" = "claude" ] && [ "$PROMPT" = "ah-wake" ]; then
	CONTEXT=$("$AHC" deliver "$TOKEN" 2>/dev/null || true)
	if [ -n "$CONTEXT" ]; then
		jq -cn --arg context "$CONTEXT" '{decision:"block",reason:("[Agent Hub mail]\n"+$context)}'
		exit 0
	fi
	printf '{"decision":"block","reason":"[Agent Hub] no pending mail."}'
	exit 0
fi

# Normal prompts: attach pending mail as context.
CONTEXT=$("$AHC" deliver "$TOKEN" 2>/dev/null || true)
if [ -n "$CONTEXT" ]; then
	jq -cn --arg context "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("[Agent Hub mail]\n"+$context)}}'
fi
exit 0
