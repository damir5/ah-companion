#!/bin/sh
# SessionEnd hook (claude + codex): end the daemon registration. Tokens decay
# with their connection (by design), so re-register then end when needed.
# stdin: hook JSON {session_id}
set -eu
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
STATE=$("$AHC" state-path "$SESSION_ID" 2>/dev/null || true)
[ -n "$STATE" ] && [ -f "$STATE" ] || exit 0
SLUG=$(jq -r '.slug // empty' "$STATE" 2>/dev/null || true)

"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || {
	# token decayed: fresh registration, then end it
	[ -n "$SLUG" ] && "$AHC" register "${AH_COMPANION_HARNESS:-claude}" "$SLUG" "$SESSION_ID" >/dev/null 2>&1 || true
	"$AHC" end "$SESSION_ID" >/dev/null 2>&1 || true
}
# Sessions whose harness pid dies are reaped by the daemon anyway; this is
# best-effort cleanliness.
exit 0
