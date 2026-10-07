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
| Claude `SubagentStart` / `SubagentStop` | records the native child ID under the enclosing parent and sends bounded durable observations to Agent Hub |
| idle + codex | senders use the native `codex queue --thread <id> --message` (no asyncRewake in codex) |

All daemon traffic speaks the same unix-socket protocol as the ah CLI
(`session.register` / `wait` / `message.ack` / `message.fail` / `session.end` / `session.child`).

Child completion means the native response or turn ended. The parent still reviews
checks and results before reporting completed work. Child observations create no
new Hub identities or credentials.

## Opt-in registration

Sessions do not register by default, so the hub is not flooded with a
`<harness>-<folder>` identity for every session. A session registers at start
only when one of these holds:

- the project was switched on with `/ah:on` (or the `/ah-on` magic word), which
  also registers the current session immediately. The switch is a marker file
  in `~/.local/state/ah-companion/`, keyed by a hash of the project's Git root
  (markers from 0.6.0 are not read; switch the project on again).
- `AH_COMPANION_AUTOREGISTER=1` is set in the harness environment.

A session that is not registered yet registers on its next prompt when its
project has a marker, for example after the daemon was down at session start.

`/ah:off` (or `/ah-off`) disconnects the current session and removes the
project's marker; it works even when the session never registered.

## Install

```sh
./scripts/install.sh   # or: install.sh git@github.com:damir5/ah-companion.git
```

Then one-time per machine: trust the hooks — claude `/plugin`, codex `/hooks`
(hash-trust; hook script changes re-trigger review).

Manual:
```sh
claude plugin marketplace add https://github.com/damir5/ah-companion.git
claude plugin install ah@ah-companion
codex plugin marketplace add https://github.com/damir5/ah-companion.git
codex plugin add ah
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
- `tests/hooks.sh` — hook, command, and caller-bound messaging tests (`sh tests/hooks.sh`)

## Requirements

Compatible ah daemon running (`ah status`), `python3` + `jq` on PATH (hooks run in a
limited environment), Claude with SubagentStart/SubagentStop support, or Codex
with hooks support. Changing hook code requires renewed human trust; installing
the package alone is not proof that capture works. These installation and trust
commands are for the human. Agents launch separate harness runs through `ah run`.

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

- Claude lifecycle capture is ready only after a native hook is observed and its
  evidence is accepted locally. Before then, Agent Hub shows capture as unverified.
  Hooks never imply that a recommended plan answer or a child result was approved.
- Codex 0.160.0 has no SubagentStart/SubagentStop hook names. Its companion preserves
  the exact native parent ID so the compatible daemon can inspect parent-linked
  rollouts and native turn IDs. It does not start another app-server or infer
  parentage from a directory, label or timestamp.
- When daemon intake fails, Claude observations stay in an owner-only spool capped
  at 256 records/1MiB per parent, including rejected evidence and incarnation counters.
  Permanent refusals retain a recent sample (16 records/64KiB), count cumulative loss and allow later valid
  observations through. Prompt/stop/end hooks replay the same event UUIDs;
  overflow or lock contention records visible loss instead of silently claiming
  complete capture. Inspect locally with `hooks/ahc.py capture-status <native-session-id>`.
- Parent end preserves child-only replay credentials for 30 days. Replaying evidence
  from an ended parent happens on later active hook ticks, including after `/ah:off`
  or failed end intake. A retained close intent retries ending that exact registration.
  Late stops remain observable for previously proven children; retained state cannot start new work.
  Replay does not reconnect the session or grant permission to send messages. A reconnect
  does not mark children stopped. Sessions launched by `ah run` are captured by the
  supervisor/daemon and are never registered again through companion hooks.

- codex background hooks don't wake idle sessions — idle codex delivery is
  sender-side via `codex queue`; the plugin covers active sessions.
- Hook processes see the session cwd; registration slug derives from it
  (`claude-<basename>`), same convention as the pi ah-session extension.
- Kill switch: disable the plugin (`/plugin`), or `AH_COMPANION_DISABLE=1` env.
