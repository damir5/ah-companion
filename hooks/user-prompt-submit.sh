#!/bin/sh
# UserPromptSubmit hook (claude + codex): drain pending AH mail into the turn
# as additional context; ack what was delivered. On claude, swallow the
# "ah-wake" nudge prompt so the daemon can wake an idle session with one
# tiny keystroke without polluting the conversation.
# stdin: hook JSON {session_id, prompt}
set -eu
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)

# /ah-on must work before the session is registered: switch the project on
# (future sessions register at start) and register this session now.
if [ "${AH_COMPANION_HARNESS:-claude}" = "claude" ] && [ "$PROMPT" = "/ah-on" ]; then
	CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
	touch "$("$AHC" project-marker "${CWD:-$PWD}")"
	printf '%s' "$INPUT" | "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh"
	SLUG=$(jq -r '.slug // empty' "$STATE" 2>/dev/null || true)
	if [ -n "$SLUG" ]; then
		printf '{"decision":"block","reason":"[Agent Hub] connected as %s; new sessions in this project register automatically."}' "$SLUG"
	else
		printf '{"decision":"block","reason":"[Agent Hub] registration failed; check that the ah daemon is running (ah status)."}'
	fi
	exit 0
fi

[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

PENDING=$("$AHC" pending "$TOKEN" 2>/dev/null || true)
BODIES=$(printf '%s' "$PENDING" | jq -r '.. | .body? // empty' 2>/dev/null || true)

# claude magic words: deterministic, intercepted before the model sees them
if [ "${AH_COMPANION_HARNESS:-claude}" = "claude" ]; then
	case "$PROMPT" in
		/ah-name\ *)
			NEW=$(printf '%s' "$PROMPT" | awk '{print $2}')
			if [ -n "$NEW" ]; then
				RES=$("$AHC" rename "$SESSION_ID" "$NEW" 2>/dev/null || true)
				if printf '%s' "$RES" | grep -q '"ok": *true'; then
					printf '{"decision":"block","reason":"[Agent Hub] session renamed to %s"}' "$NEW"
				else
					printf '{"decision":"block","reason":"[Agent Hub] rename failed: %s"}' "$(printf '%s' "$RES" | head -c 200)"
				fi
				exit 0
			fi
			;;
		/ah-off)
			"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
			rm -f "$STATE" "$("$AHC" project-marker "$(printf '%s' "$INPUT" | jq -r '.cwd // empty')")" 2>/dev/null || true
			printf '{"decision":"block","reason":"[Agent Hub] disconnected; this project no longer registers at session start. Type /ah-on to reconnect."}'
			exit 0
			;;
	esac
fi

# claude wake-word: block the nudge prompt, deliver mail instead
if [ "${AH_COMPANION_HARNESS:-claude}" = "claude" ] && [ "$PROMPT" = "ah-wake" ]; then
	if [ -n "$BODIES" ]; then
		printf '%s' "$PENDING" | jq -c '[.. | objects | select(has("id"))] | map(select(.id != null)) | .[0:5] | .[] | {id}' 2>/dev/null | while read -r REF; do
			MID=$(printf '%s' "$REF" | jq -r '.id')
			[ -n "$MID" ] && "$AHC" ack "$TOKEN" "$MID" >/dev/null 2>&1 || true
		done
		CONTEXT=$(printf '%s' "$BODIES" | head -c 4000)
		printf '{"decision":"block","reason":"[Agent Hub mail]\\n%s"}' "$CONTEXT"
		exit 0
	fi
	printf '{"decision":"block","reason":"[Agent Hub] no pending mail."}'
	exit 0
fi

# Normal prompts: attach pending mail as context, ack it.
if [ -n "$BODIES" ]; then
	printf '%s' "$PENDING" | jq -c '[.. | objects | select(has("id"))] | map(select(.id != null)) | .[] | {id}' 2>/dev/null | while read -r REF; do
		MID=$(printf '%s' "$REF" | jq -r '.id')
		[ -n "$MID" ] && "$AHC" ack "$TOKEN" "$MID" >/dev/null 2>&1 || true
	done
	CONTEXT=$(printf '%s' "$BODIES" | head -c 4000)
	printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[Agent Hub mail]\\n%s"}}' "$CONTEXT"
fi
exit 0
