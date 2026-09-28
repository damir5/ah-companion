# ah-companion

Agent Hub companion plugin for **Claude Code** and **Codex**: semantic
delivery of Agent Hub messages into *interactive* sessions — no keystroke
injection, no screen scraping.

## What it does

| Event | Behavior |
|---|---|
| `SessionStart` | if the project is switched on (see below), registers the session with the local ah daemon (`claude-<project>` / `codex-<project>` slug) and (claude) arms a background waiter |
| **idle + claude** | `asyncRewake` waiter long-polls the daemon; an arriving message wakes Claude with the message as a system reminder — a real triggered turn |
| turn boundary | `Stop` hook blocks the stop with the first pending message — the harness processes it as turn continuation (claude + codex) |
| your next prompt | `UserPromptSubmit` drains pending mail into the turn as context and acks it; on claude the `ah-wake` nudge word is swallowed and replaced by the mail |
| `SessionEnd` | ends the daemon registration |
| idle + codex | senders use the native `codex queue --thread <id> --message` (no asyncRewake in codex) |

All daemon traffic speaks the same unix-socket protocol as the ah CLI
(`session.register` / `wait` / `message.ack` / `message.fail` / `session.end`).

## Opt-in registration

Sessions do not register by default, so the hub is not flooded with a
`<harness>-<folder>` identity for every session. A session registers at start
only when one of these holds:

- the project was switched on with `/ah:on` (or the `/ah-on` magic word), which
  also registers the current session immediately. The switch is a marker file
  in `~/.local/state/ah-companion/`, keyed by the project's Git root.
- `AH_COMPANION_AUTOREGISTER=1` is set in the harness environment.

`/ah:off` (or `/ah-off`) disconnects the session and removes the project's
marker.

## Install

```sh
./scripts/install.sh   # or: install.sh git@github.com:damir5/ah-companion.git
```

Then one-time per machine: trust the hooks — claude `/plugin`, codex `/hooks`
(hash-trust; hook script changes re-trigger review).

Manual:
```sh
claude plugin marketplace add https://github.com/damir5/ah-companion.git
claude plugin install ah@ah
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

## Commands

Every command works two ways: as a plugin slash command (`/ah:<name>`) or as a magic word typed directly (intercepted before the model — zero token cost).

| What | Plugin command | Magic word |
|---|---|---|
| Show identity + fleet roster | `/ah:status` | `ah-wake` |
| Rename this session | `/ah:name <slug>` | `/ah-name <slug>` |
| DM another agent | `/ah:send <slug> <msg>` | — |
| Disconnect and switch the project off | `/ah:off` | `/ah-off` |
| Connect and switch the project on | `/ah:on` | `/ah-on` |

## Limits / notes

- codex background hooks don't wake idle sessions — idle codex delivery is
  sender-side via `codex queue`; the plugin covers active sessions.
- Hook processes see the session cwd; registration slug derives from it
  (`claude-<basename>`), same convention as the pi ah-session extension.
- Kill switch: disable the plugin (`/plugin`), or `AH_COMPANION_DISABLE=1` env.
