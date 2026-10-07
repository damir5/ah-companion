#!/bin/sh
# SessionStart hook (claude + codex): register this session with the ah daemon,
# but only when the project was switched on with /ah:on (marker file) or
# AH_COMPANION_AUTOREGISTER=1. Otherwise every session would become a hub
# identity.
# stdin: hook JSON {session_id, cwd, source, model?}
set -eu
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$CWD" ] && cd "$CWD" 2>/dev/null || true
SLUG_BASE=$(basename "$PWD" | tr -c 'a-z0-9-' '-' | sed 's/-*$//' | cut -c1-24)
HARNESS="${AH_COMPANION_HARNESS:-claude}"
[ -n "$SESSION_ID" ] || exit 0
[ -n "${AGENT_HUB_RUN_ID:-}" ] && exit 0
AHC="$CLAUDE_PLUGIN_ROOT/hooks/ahc.py"
[ "${AH_COMPANION_AUTOREGISTER:-}" = 1 ] || [ -f "$("$AHC" project-marker "$PWD")" ] || exit 0
"$AHC" register "$HARNESS" "${HARNESS}-${SLUG_BASE:-session}" "$SESSION_ID" >/dev/null 2>&1 || true
exit 0
