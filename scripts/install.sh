#!/bin/sh
# ah-companion installer: add the marketplace + plugin for claude and codex.
# Requires: git, jq, python3, an ah daemon running (ah health).
set -eu

REPO_URL="${1:-https://github.com/damir5/ah-companion.git}"

say() { printf '  %s\n' "$1"; }

command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1 || HAVE_CLAUDE=0
command -v codex >/dev/null 2>&1 && HAVE_CODEX=1 || HAVE_CODEX=0

if [ "$HAVE_CLAUDE" = 1 ]; then
	say "claude: adding marketplace"
	claude plugin marketplace add "$REPO_URL" 2>/dev/null || say "claude: marketplace already added (or add failed — check output above)"
	say "claude: installing plugin"
	claude plugin install ah@ah-companion 2>/dev/null \
		|| claude plugin enable ah 2>/dev/null \
		|| say "claude: open claude, run /plugin, and enable ah (or trust prompts)"
fi

if [ "$HAVE_CODEX" = 1 ]; then
	say "codex: adding marketplace"
	codex plugin marketplace add "$REPO_URL" 2>/dev/null || say "codex: marketplace already added"
	say "codex: installing plugin"
	codex plugin add ah 2>/dev/null || say "codex: plugin already installed (or run: codex plugin add ah)"
fi

say "done. One-time per machine: trust the hooks (claude /plugin, codex /hooks) on next session start."
