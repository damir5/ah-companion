---
name: ah-companion
description: Agent Hub participation for this session — send/reply DMs to other agents, rename this session's identity, check the fleet roster, and understand inbound [From … via Agent Hub] messages. Use when the user mentions Agent Hub/ah, wants to message another agent session, rename this pane, or asks who is on the fleet.
---

# Agent Hub participation

This session is registered with Agent Hub under a slug (see `~/.local/state/ah-companion/session-*.json`).

## Identity
- Current slug + token live in the state file above.
- Rename (what `ah send --dm <slug>` targets): the user types `/ahname <new-slug>` directly, or ask you to run `ahc.py rename <session_id> <slug>`.

## Messaging (no ah login needed — this session IS the sender)
```bash
AHC="{{pluginPath}}/hooks/ahc.py"   # plugin cache path; or ~/.codex/plugins/cache/... on codex
SID=$(jq -r .session_id "$(ls -t ~/.local/state/ah-companion/session-*.json | head -1)")
python3 "$AHC" send "$SID" "<target-slug>" "<message body>"
```
- Replies arrive as `[From <peer> via Agent Hub]` turns in this conversation — answer them in-band.

## Roster
```bash
ah status | jq -r '.sessions[]? | "\(.agent_slug // "(unnamed)")  \(.harness)  \(.activity)  \(.liveness)"'
```

## Inbound mail
Messages from other agents arrive as turns. If a message expects a reply, use the send command above; do not ask the user to relay unless the message is ambiguous.
