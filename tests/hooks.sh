#!/bin/sh
# Hook and command tests against a fake ah daemon. Run: sh tests/hooks.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill "$DAEMON" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_ROOT="$ROOT" XDG_STATE_HOME="$WORK/state" AGENT_HUB_CONFIG_DIR="$WORK/hub"
export AH_COMPANION_HARNESS_PID=$$
unset AH_COMPANION_AUTOREGISTER AH_COMPANION_HARNESS 2>/dev/null || true
mkdir -p "$AGENT_HUB_CONFIG_DIR" "$WORK/projects/a.b" "$WORK/projects/a/b" "$WORK/projects/app"
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
marker() { python3 "$AHC" project-marker "$1"; }
state() { python3 "$AHC" state-path "$1"; }

A=11111111-1111-4111-8111-111111111111
B=22222222-2222-4222-8222-222222222222
APP="$WORK/projects/app"

check "distinct directories get distinct markers" '[ "$(marker "$WORK/projects/a.b")" != "$(marker "$WORK/projects/a/b")" ]'
ln -s "$APP" "$WORK/link"
check "a symlinked path shares the canonical marker" '[ "$(marker "$WORK/link")" = "$(marker "$APP")" ]'

# Daemon down: /ah-on leaves a marker and no registration; /ah-off still clears it.
OUT=$(prompt "$A" "$APP" /ah-on)
check "/ah-on with the daemon down reports failure" 'printf "%s" "$OUT" | grep -q "registration failed"'
check "/ah-on with the daemon down leaves the marker" '[ -f "$(marker "$APP")" ]'
OUT=$(prompt "$A" "$APP" /ah-off)
check "/ah-off without a state file answers" 'printf "%s" "$OUT" | grep -q disconnected'
check "/ah-off without a state file removes the marker" '[ ! -f "$(marker "$APP")" ]'

start_daemon
# A marker set elsewhere: the next ordinary prompt registers the session.
touch "$(marker "$APP")"
prompt "$A" "$APP" hello >/dev/null
check "a prompt registers when the project is on" '[ -f "$(state "$A")" ]'
rm -f "$(marker "$APP")"
prompt "$B" "$APP" hello >/dev/null
check "a prompt does not register when the project is off" '[ ! -f "$(state "$B")" ]'

# /ah:on registers the current session immediately.
OUT=$(command_md on "$B" "$APP")
check "/ah:on registers this session" 'printf "%s" "$OUT" | grep -q "registered as: claude-app"'

# /ah:off ends only the current session, not the newest one.
: >"$WORK/requests.log"
touch "$(state "$B")"
OUT=$(command_md off "$A" "$APP")
check "/ah:off ends the current session" 'grep -q "^session.end" "$WORK/requests.log" && [ ! -f "$(state "$A")" ] && [ "$OUT" = disconnected ]'
check "/ah:off leaves the other session registered" '[ -f "$(state "$B")" ]'
check "/ah:off removes the marker" '[ ! -f "$(marker "$APP")" ]'
OUT=$(command_md off "" "$APP")
check "/ah:off without a session id ends nothing" 'printf "%s" "$OUT" | grep -q "could not be identified" && [ -f "$(state "$B")" ]'
stop_daemon

[ "$FAILED" = 0 ] && echo "all passed"
exit "$FAILED"
