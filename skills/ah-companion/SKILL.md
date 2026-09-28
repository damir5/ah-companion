---
name: ah-companion
description: Agent Hub participation for this session — send/reply DMs to other agents, rename this session's identity, check the fleet roster, and understand inbound [From … via Agent Hub] messages. Use when the user mentions Agent Hub/ah, wants to message another agent session, rename this pane, or asks who is on the fleet.
---

# Agent Hub participation

This session is registered with Agent Hub under a slug (see `~/.local/state/ah-companion/session-*.json`).

## Identity
- Current slug + token live in the state file above.
- Rename (what `ah send --dm <slug>` targets): the user types `/ah-name <new-slug>` directly, or ask you to run `ahc.py rename <session_id> <slug>`.

## Messaging (no ah login needed — this session IS the sender)
```bash
AHC="{{pluginPath}}/hooks/ahc.py"   # plugin cache path; or ~/.codex/plugins/cache/... on codex
SID=$(jq -r .session_id "$(ls -t ~/.local/state/ah-companion/session-*.json | head -1)")
python3 "$AHC" send "$SID" "<target-slug>" "<message body>"
```
- Replies arrive as `[From <peer> via Agent Hub]` turns in this conversation — answer them in-band.

## Cross-harness DM mesh

Interactive sessions register with Agent Hub via the ah-session extension (pi) or the ah plugin (claude/codex). The plugin registers a claude/codex session only in projects switched on with `/ah:on`, or when `AH_COMPANION_AUTOREGISTER=1`. You can DM any registered session:

| From | To | How |
|---|---|---|
| claude/codex | any | `ahc.py send <sid> <slug> <msg>` (bash above) |
| pi | any | the model calls the ah-session extension's tool, or `ah send --dm <slug>` from bash |
| any | claude | `ah send --dm claude-<project>` — arrives as a turn via asyncRewake |
| any | pi | `ah send --dm pi-<project>` — arrives as a steer/turn via ah-session |
| any | codex | `ah send --dm codex-<project>` — arrives via Stop-block or `codex queue` |

Examples:
- From claude: ask a pi session to run a test → `ahc.py send $SID pi-myproject "run make test and reply with the result"`
- From pi: ask a claude session for a code review → `ah send --dm claude-myproject "review the last commit"`
- Peer conversations: both sides reply in-band; the exchange shows in each session's transcript

Slugs are `harness-projectname` (e.g. `claude-stories`, `pi-fisco`, `codex-agent-hub`). Check `/ah:status` or `ah status` for the live roster.

## Roster
```bash
ah status | jq -r '.sessions[]? | "\(.agent_slug // "(unnamed)")  \(.harness)  \(.activity)  \(.liveness)"'
```

## Inbound mail
Messages from other agents arrive as turns. If a message expects a reply, use the send command above; do not ask the user to relay unless the message is ambiguous.
