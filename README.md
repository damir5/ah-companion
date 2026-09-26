# ah-companion

Agent Hub companion plugin for **Claude Code** and **Codex**: semantic
delivery of Agent Hub messages into *interactive* sessions — no keystroke
injection, no screen scraping.

## What it does

| Event | Behavior |
|---|---|
| `SessionStart` | registers the session with the local ah daemon (`claude-<project>` / `codex-<project>` slug) and (claude) arms a background waiter |
| **idle + claude** | `asyncRewake` waiter long-polls the daemon; an arriving message wakes Claude with the message as a system reminder — a real triggered turn |
| turn boundary | `Stop` hook blocks the stop with the first pending message — the harness processes it as turn continuation (claude + codex) |
| your next prompt | `UserPromptSubmit` drains pending mail into the turn as context and acks it; on claude the `ah-wake` nudge word is swallowed and replaced by the mail |
| `SessionEnd` | ends the daemon registration |
| idle + codex | senders use the native `codex queue --thread <id> --message` (no asyncRewake in codex) |

All daemon traffic speaks the same unix-socket protocol as the ah CLI
(`session.register` / `wait` / `message.ack` / `message.fail` / `session.end`).

## Install

```sh
./scripts/install.sh   # or: install.sh git@github.com:damir5/ah-companion.git
```

Then one-time per machine: trust the hooks — claude `/plugin`, codex `/hooks`
(hash-trust; hook script changes re-trigger review).

Manual:
```sh
claude plugin marketplace add https://github.com/damir5/ah-companion.git
claude plugin install ah-companion@ah-companion
codex plugin marketplace add https://github.com/damir5/ah-companion.git
codex plugin add ah-companion
```

Dev iteration without publishing:
```sh
claude --plugin-dir ~/dev/tools/ah-companion
```

## Layout

- `.claude-plugin/` — claude marketplace + plugin manifests (hooks-claude.json wired via plugin.json)
- `.codex-plugin/` — codex plugin manifest (hooks-codex.json; codex sets `CLAUDE_PLUGIN_ROOT` for compat)
- `hooks/ahc.py` — daemon-socket CLI shared by all hooks
- `hooks/*.sh` — the four hook flows

## Requirements

ah daemon running (`ah health`), `python3` + `jq` on PATH (hooks run in a
limited environment), claude ≥ 2.1.x / codex with hooks support.

## Limits / notes

- codex background hooks don't wake idle sessions — idle codex delivery is
  sender-side via `codex queue`; the plugin covers active sessions.
- Hook processes see the session cwd; registration slug derives from it
  (`claude-<basename>`), same convention as the pi ah-session extension.
- Kill switch: disable the plugin (`/plugin`), or `AH_COMPANION_DISABLE=1` env.
