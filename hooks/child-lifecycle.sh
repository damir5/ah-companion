#!/bin/sh
# Claude native child lifecycle; the Python collector validates attribution,
# records before sending, and retains bounded evidence while the daemon is down.
set -eu
[ "${AH_COMPANION_DISABLE:-}" = 1 ] && exit 0
[ -n "${AGENT_HUB_RUN_ID:-}" ] && exit 0
"$CLAUDE_PLUGIN_ROOT/hooks/ahc.py" child-hook >/dev/null 2>&1 || true
