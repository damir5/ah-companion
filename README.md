# ah-companion

Agent Hub companion plugin for **Claude Code** and **Codex**: semantic
delivery of Agent Hub messages into *interactive* sessions — no keystroke
injection, no screen scraping.

## What it does

| Event | Behavior |
|---|---|
| `SessionStart` | only with `AH_COMPANION_AUTOREGISTER=1` (see below), registers the session with the local ah daemon (`claude-<project>` / `codex-<project>` slug) and (claude) arms a background waiter |
| **idle + claude** | `asyncRewake` waiter long-polls the daemon and re-arms the wait while the session lives (one waiter per session); an arriving message wakes Claude with the message as a system reminder — a real triggered turn. `SessionStart`, every `UserPromptSubmit` (so `/ah:on` and `ah-on` too) and every `Stop` start the waiter when none runs |
| turn boundary | `Stop` hook blocks the stop with the first pending message — the harness processes it as turn continuation (claude + codex). A stop that ends the turn reports the session `idle` |
| your next prompt | `UserPromptSubmit` reports the session `working` and adds pending mail into the turn as context, whole messages up to 8000 bytes; the rest wait for the next delivery point |
| acknowledgement | a message is acked only by the next hook after the one that handed it to the harness (prompt, stop or wake), so a crash before that leaves it unacked instead of lost. A handed message is never shown again |
| `SessionEnd` | ends the daemon registration |
| Claude `SubagentStart` / `SubagentStop` | records the native child ID under the enclosing parent and sends bounded durable observations to Agent Hub |
| idle + codex | senders use the native `codex queue --thread <id> --message` (no asyncRewake in codex) |

All daemon traffic speaks the same unix-socket protocol as the ah CLI
(`session.register` / `wait` / `message.ack` / `message.fail` / `session.activity` / `session.end` / `session.child`).

Child completion means the native response or turn ended. The parent still reviews
checks and results before reporting completed work. Child observations create no
new Hub identities or credentials.

## Opt-in registration

Sessions you open do not connect by default, so the hub is not flooded with a
`<harness>-<folder>` identity for every session. Connect one session with
`/ah:on` (Codex: type `ah-on`); `/ah:on <name>` (Codex: `ah-on <name>`) also
names it, or renames it when it is already connected. Only that session
connects. `/ah:off` (Codex: `ah-off`) disconnects it.

Agents launched with `ah run` register through `ah run` itself; the plugin skips
them. Setting `AH_COMPANION_AUTOREGISTER=1` in the harness environment makes
every session register at start.

Version 0.10.0 removed the per-project switch: the `project-*.on` marker files
that older versions wrote in `~/.local/state/ah-companion/` are no longer read.

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

Codex 0.163 and later run the TUI against a shared `codex app-server` daemon by
default. Hooks then run under that daemon, so Agent Hub registers the daemon,
not the pane: Drover cannot match the session to its pane, and the session ends
only when the daemon does. Start Codex with `codex --no-daemon`; `ah-on` warns
when it detects the daemon.

## Commands

| What | Claude | Codex |
|---|---|---|
| Connect this session, optionally naming or renaming it | `/ah:on [name]` | type `ah-on [name]` |
| Show identity + fleet roster | `/ah:status` | `ah status` |
| Disconnect this session | `/ah:off` | type `ah-off` |
| DM another agent | `/ah:send <slug> <msg>` | `ah send --dm <slug> <msg>` |

Codex has no plugin slash commands and its TUI rejects unknown `/...` input, so
the words `ah-on` and `ah-off` are its only way to connect or disconnect. Claude also
accepts them.

## Limits / notes

- Each delivered message starts with one header line: sender, room, thread root id,
  message id, and the reply command `ah reply --reply-to <id> "<text>"`.

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
  When another live session holds that slug, the hub picks a free name
  (`auto_name`); the session keeps that name in its state.
- Kill switch: disable the plugin (`/plugin`), or `AH_COMPANION_DISABLE=1` env.
