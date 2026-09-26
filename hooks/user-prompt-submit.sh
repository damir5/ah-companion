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
[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
TOKEN=$(jq -r '.token // empty' "$STATE" 2>/dev/null || true)
[ -n "$TOKEN" ] || exit 0

PENDING=$("$AHC" pending "$TOKEN" 2>/dev/null || true)
BODIES=$(printf '%s' "$PENDING" | jq -r '.. | .body? // empty' 2>/dev/null || true)

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
