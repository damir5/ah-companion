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

# /ah-on and /ah-off must work whether or not this session is registered: a
# marker created while the daemon was down still has to be removable.
# Both harnesses: codex has no plugin slash commands, so these words are its
# only way to switch a session on or off from inside. The codex TUI rejects
# unknown "/..." input before hooks run, so the words also work without "/".
case "$PROMPT" in
	/ah-on | ah-on)
		touch "$("$AHC" project-marker "${CWD:-$PWD}")"
		printf '%s' "$INPUT" | "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh"
		SLUG=$(jq -r '.slug // empty' "$STATE" 2>/dev/null || true)
		if [ -n "$SLUG" ]; then
			jq -cn --arg slug "$SLUG" '{decision:"block",reason:("[Agent Hub] connected as "+$slug+"; new sessions in this project register automatically.")}'
		else
			printf '{"decision":"block","reason":"[Agent Hub] registration failed; check that the ah daemon is running (ah status)."}'
		fi
		exit 0
		;;
	/ah-off | ah-off)
		"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
		rm -f "$STATE" "$("$AHC" project-marker "${CWD:-$PWD}")" 2>/dev/null || true
		printf '{"decision":"block","reason":"[Agent Hub] disconnected; this project no longer registers at session start. Type /ah-on (codex: ah-on) to reconnect."}'
		exit 0
		;;
	# naming an unregistered session registers it under that name
	/ah-name\ *)
		NEW=$(printf '%s' "$PROMPT" | awk '{print $2}')
		if [ -n "$NEW" ] && [ "${AH_COMPANION_HARNESS:-claude}" = "claude" ]; then
			[ -n "$CWD" ] && cd "$CWD" 2>/dev/null || true
			RES=$("$AHC" rename "$SESSION_ID" "$NEW" 2>/dev/null || true)
			if printf '%s' "$RES" | grep -q '"ok": *true'; then
				jq -cn --arg name "$NEW" '{decision:"block",reason:("[Agent Hub] session named "+$name)}'
			else
				jq -cn --arg result "$(printf '%s' "$RES" | head -c 200)" '{decision:"block",reason:("[Agent Hub] naming failed: "+$result)}'
			fi
			exit 0
		fi
		;;
esac

# A project switched on after this session started, or a daemon that was down
# at session start: register now. Only the marker counts here, so /ah-off
# holds for the session even when AH_COMPANION_AUTOREGISTER=1.
if [ -n "$STATE" ] && [ ! -f "$STATE" ] && [ -f "$("$AHC" project-marker "${CWD:-$PWD}")" ]; then
	printf '%s' "$INPUT" | "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh" || true
fi

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
