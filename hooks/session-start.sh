#!/bin/sh
# SessionStart hook (claude + codex): register this session with the ah daemon.
# stdin: hook JSON {session_id, cwd, source, model?}
set -eu
INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$CWD" ] && cd "$CWD" 2>/dev/null || true
SLUG_BASE=$(basename "$PWD" | tr -c 'a-z0-9-' '-' | sed 's/-*$//' | cut -c1-24)
HARNESS="${AH_COMPANION_HARNESS:-claude}"
[ -n "$SESSION_ID" ] || exit 0
"$CLAUDE_PLUGIN_ROOT/hooks/ahc.py" register "$HARNESS" "${HARNESS}-${SLUG_BASE:-session}" "$SESSION_ID" >/dev/null 2>&1 || true
exit 0
