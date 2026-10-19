#!/bin/sh
# Hook and command tests against a fake ah daemon. Run: sh tests/hooks.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill "$DAEMON" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_ROOT="$ROOT" XDG_STATE_HOME="$WORK/state" AGENT_HUB_CONFIG_DIR="$WORK/hub"
export AH_COMPANION_HARNESS_PID=$$
unset AH_COMPANION_AUTOREGISTER AH_COMPANION_HARNESS 2>/dev/null || true
mkdir -p "$AGENT_HUB_CONFIG_DIR" "$WORK/projects/app"
AHC="$ROOT/hooks/ahc.py"
FAILED=0

# Answers every request with ok and appends its type to requests.log.
start_daemon() {
	python3 - "$AGENT_HUB_CONFIG_DIR/daemon.sock" "$WORK/requests.log" <<'PY' &
import json, os, socket, sys
path, log = sys.argv[1], sys.argv[2]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen()
while True:
    conn, _ = server.accept()
    data = b""
    while not data.endswith(b"\n"):
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    request = json.loads(data)
    with open(log, "a") as f:
        f.write(request["type"] + " " + request.get("session_id", "") + "\n")
    conn.sendall((json.dumps({"ok": True, "messages": []}) + "\n").encode())
    conn.close()
PY
	DAEMON=$!
	while [ ! -S "$AGENT_HUB_CONFIG_DIR/daemon.sock" ]; do sleep 0.05; done
}
stop_daemon() {
	kill "$DAEMON" 2>/dev/null || true
	wait "$DAEMON" 2>/dev/null || true
	rm -f "$AGENT_HUB_CONFIG_DIR/daemon.sock"
}
check() {
	if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}
prompt() {
	printf '{"session_id":"%s","cwd":"%s","prompt":"%s"}' "$1" "$2" "$3" | "$ROOT/hooks/user-prompt-submit.sh"
}
# Runs a command's bash block the way Claude Code does: ${CLAUDE_PLUGIN_ROOT}
# and ${CLAUDE_SESSION_ID} are substituted in the text before it runs.
command_md() {
	sed -n '/^```bash$/,/^```$/p' "$ROOT/commands/$1.md" | sed '1d;$d' |
		sed -e "s|\${CLAUDE_PLUGIN_ROOT}|$ROOT|g" -e "s|\${CLAUDE_SESSION_ID}|$2|g" >"$WORK/cmd.sh"
	(cd "$3" && sh "$WORK/cmd.sh")
}
state() { python3 "$AHC" state-path "$1"; }
# /ah:on with a name: the model puts the argument into NAME="".
command_on_named() {
	sed "s/^NAME=\"\"/NAME=\"$3\"/" "$ROOT/commands/on.md" >"$WORK/on-named.md"
	sed -n '/^```bash$/,/^```$/p' "$WORK/on-named.md" | sed '1d;$d' |
		sed -e "s|\${CLAUDE_PLUGIN_ROOT}|$ROOT|g" -e "s|\${CLAUDE_SESSION_ID}|$1|g" >"$WORK/cmd.sh"
	(cd "$2" && sh "$WORK/cmd.sh")
}

A=11111111-1111-4111-8111-111111111111
B=22222222-2222-4222-8222-222222222222
APP="$WORK/projects/app"

# Daemon down: ah-on reports failure; ah-off still answers.
OUT=$(prompt "$A" "$APP" ah-on)
check "ah-on with the daemon down reports failure" 'printf "%s" "$OUT" | grep -q "connection failed"'
OUT=$(prompt "$A" "$APP" ah-off)
check "ah-off without a state file answers" 'printf "%s" "$OUT" | grep -q disconnected'

start_daemon
# Sessions the user opens stay disconnected until they run /ah:on.
printf '{"session_id":"%s","cwd":"%s"}' "$A" "$APP" | "$ROOT/hooks/session-start.sh"
prompt "$A" "$APP" hello >/dev/null
check "a new session does not connect by itself" '[ ! -f "$(state "$A")" ]'
printf '{"session_id":"%s","cwd":"%s"}' "$A" "$APP" | AH_COMPANION_AUTOREGISTER=1 "$ROOT/hooks/session-start.sh"
check "AH_COMPANION_AUTOREGISTER=1 connects at session start" '[ -f "$(state "$A")" ]'

# /ah:on connects only the current session.
OUT=$(command_md on "$B" "$APP")
check "/ah:on connects this session" 'printf "%s" "$OUT" | grep -q "connected as: claude-app"'
OUT=$(command_md on "$B" "$APP")
check "/ah:on on a connected session reports its name" 'printf "%s" "$OUT" | grep -q "already connected as: claude-app"'
D=44444444-4444-4444-8444-444444444444
prompt "$D" "$APP" hello >/dev/null
check "/ah:on in one session does not connect others" '[ ! -f "$(state "$D")" ]'

# /ah:on <name> connects an unconnected session under that name, and renames a connected one.
command_on_named "$D" "$APP" team-worker >/dev/null
check "/ah:on <name> connects an unconnected session under that name" '[ "$(jq -r .slug "$(state "$D")")" = team-worker ]'
command_on_named "$D" "$APP" lead >/dev/null
check "/ah:on <name> renames a connected session" '[ "$(jq -r .slug "$(state "$D")")" = lead ]'

# /ah:off ends only the current session, not the newest one.
: >"$WORK/requests.log"
OUT=$(command_md off "$A" "$APP")
check "/ah:off ends the current session" 'grep -q "^session.end" "$WORK/requests.log" && [ ! -f "$(state "$A")" ] && [ "$OUT" = disconnected ]'
check "/ah:off leaves the other session connected" '[ -f "$(state "$B")" ]'
OUT=$(command_md off "" "$APP")
check "/ah:off without a session id ends nothing" 'printf "%s" "$OUT" | grep -q "could not be identified" && [ -f "$(state "$B")" ]'

# Codex has no plugin commands: the words are its only way to connect or disconnect.
C=thr_codex
OUT=$(AH_COMPANION_HARNESS=codex prompt "$C" "$APP" ah-on)
check "codex ah-on connects the session as codex" 'printf "%s" "$OUT" | grep -q "connected as codex-app" && [ -f "$(state "$C")" ]'
OUT=$(AH_COMPANION_HARNESS=codex prompt "$C" "$APP" "ah-on reviewer")
check "codex ah-on <name> renames the session" 'printf "%s" "$OUT" | grep -q "connected as reviewer" && [ "$(jq -r .slug "$(state "$C")")" = reviewer ]'
OUT=$(AH_COMPANION_HARNESS=codex prompt "$C" "$APP" ah-off)
check "codex ah-off disconnects" 'printf "%s" "$OUT" | grep -q disconnected && [ ! -f "$(state "$C")" ]'
stop_daemon

python3 "$ROOT/tests/messaging.py" || FAILED=1
python3 "$ROOT/tests/capture.py" || FAILED=1

[ "$FAILED" = 0 ] && echo "all passed"
exit "$FAILED"
