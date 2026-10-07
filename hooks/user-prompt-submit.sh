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
if [ "${AH_COMPANION_HARNESS:-claude}" = "claude" ]; then
	case "$PROMPT" in
		/ah-on)
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
		/ah-off)
			"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
			rm -f "$STATE" "$("$AHC" project-marker "${CWD:-$PWD}")" 2>/dev/null || true
			printf '{"decision":"block","reason":"[Agent Hub] disconnected; this project no longer registers at session start. Type /ah-on to reconnect."}'
			exit 0
			;;
	esac
fi

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
					jq -cn --arg name "$NEW" '{decision:"block",reason:("[Agent Hub] session renamed to "+$name)}'
				else
					jq -cn --arg result "$(printf '%s' "$RES" | head -c 200)" '{decision:"block",reason:("[Agent Hub] rename failed: "+$result)}'
				fi
				exit 0
			fi
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
		jq -cn --arg context "$CONTEXT" '{decision:"block",reason:("[Agent Hub mail]\n"+$context)}'
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
	jq -cn --arg context "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("[Agent Hub mail]\n"+$context)}}'
fi
exit 0
