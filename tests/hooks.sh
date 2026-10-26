#!/bin/sh
# Hook and command tests against a fake ah daemon. Run: sh tests/hooks.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'kill "$DAEMON" ${HERDR:-} 2>/dev/null || true; rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_ROOT="$ROOT" XDG_STATE_HOME="$WORK/state" AGENT_HUB_CONFIG_DIR="$WORK/hub"
export AH_COMPANION_HARNESS_PID=$$
unset AH_COMPANION_AUTOREGISTER AH_COMPANION_HARNESS HERDR_DROVER_ENV HERDR_SOCKET_PATH HERDR_PANE_ID 2>/dev/null || true
mkdir -p "$AGENT_HUB_CONFIG_DIR" "$WORK/projects/app"
AHC="$ROOT/hooks/ahc.py"
FAILED=0

# Answers every request with ok and appends its type (and activity) to
# requests.log. message.pending returns the messages in pending.json, if any.
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
        f.write(request["type"] + " " + request.get("session_id", "") + request.get("activity", "") + "\n")
    messages = []
    if request["type"] == "message.pending" and os.path.exists(log + ".pending.json"):
        with open(log + ".pending.json") as f:
            messages = json.load(f)
    try:
        conn.sendall((json.dumps({"ok": True, "messages": messages}) + "\n").encode())
    except BrokenPipeError:
        pass  # session.activity does not wait for the answer
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
OUT=$(AH_COMPANION_HARNESS=codex prompt "$A" "$APP" ah-on)
check "codex failed ah-on still blocks with the failure" 'printf "%s" "$OUT" | jq -e '\''.decision == "block" and (.reason | contains("connection failed")) and (has("stopReason") | not)'\'' >/dev/null'
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
check "codex successful ah-on stops with a success reason, not a block" 'printf "%s" "$OUT" | jq -e '\''.continue == false and (.stopReason | startswith("[Agent Hub] Success: connected as ")) and (has("decision") | not)'\'' >/dev/null'
OUT=$(AH_COMPANION_HARNESS=codex prompt "$C" "$APP" "ah-on reviewer")
check "codex ah-on <name> renames the session" 'printf "%s" "$OUT" | grep -q "connected as reviewer" && [ "$(jq -r .slug "$(state "$C")")" = reviewer ]'
# A Codex TUI on the shared app-server daemon: hooks run under the daemon.
python3 -c 'import time; time.sleep(30)' app-server &
APPSERVER=$!
OUT=$(AH_COMPANION_HARNESS=codex AH_COMPANION_HARNESS_PID=$APPSERVER prompt thr_codex_daemon "$APP" ah-on)
kill "$APPSERVER" 2>/dev/null || true
check "codex ah-on under the app-server daemon warns and names --no-daemon" 'printf "%s" "$OUT" | grep -q "connected as .*--no-daemon"'
# herdr learns Codex turn state from Codex hooks. A blocked ah-on/ah-off runs no
# turn and Codex sends no Stop, so the companion reports the pane idle itself.
python3 - "$WORK/herdr.sock" "$WORK/herdr.log" <<'PY2' &
import json, socket, sys
path, log = sys.argv[1], sys.argv[2]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen()
while True:
    conn, _ = server.accept()
    request = json.loads(conn.makefile().readline())
    if request["method"] == "pane.report_agent":
        with open(log, "a") as f:
            f.write(json.dumps(request["params"]) + "\n")
    conn.sendall((json.dumps({"id": request["id"], "result": {"pane": {"agent_status": "working"}}}) + "\n").encode())
    conn.close()
PY2
HERDR=$!
while [ ! -S "$WORK/herdr.sock" ]; do sleep 0.05; done
export HERDR_SOCKET_PATH="$WORK/herdr.sock" HERDR_PANE_ID=w1:p1
reported_idle() { jq -e --arg s "$1" 'select(.pane_id == "w1:p1" and .source == "herdr:codex" and .state == "idle" and .agent_session_id == $s)' "$WORK/herdr.log" >/dev/null 2>&1; }
: >"$WORK/herdr.log"
HERDR_DROVER_ENV=1 AH_COMPANION_HARNESS=codex prompt "$C" "$APP" ah-on >/dev/null
check "codex ah-on in a herdr pane reports the pane idle" 'reported_idle "$C"'
: >"$WORK/herdr.log"
OUT=$(HERDR_DROVER_ENV=1 AH_COMPANION_HARNESS=claude prompt "$B" "$APP" ah-on)
check "claude successful ah-on keeps its block response" 'printf "%s" "$OUT" | jq -e '\''.decision == "block" and (.reason | startswith("[Agent Hub] connected as "))'\'' >/dev/null'
check "claude ah-on reports nothing to herdr" '[ ! -s "$WORK/herdr.log" ]'
OUT=$(HERDR_DROVER_ENV=1 AH_COMPANION_HARNESS=codex prompt "$C" "$APP" ah-off)
check "codex ah-off disconnects" 'printf "%s" "$OUT" | grep -q disconnected && [ ! -f "$(state "$C")" ]'
check "codex successful ah-off stops with a success reason, not a block" 'printf "%s" "$OUT" | jq -e '\''.continue == false and .stopReason == "[Agent Hub] Success: disconnected." and (has("decision") | not)'\'' >/dev/null'
check "codex ah-off in a herdr pane reports the pane idle" 'reported_idle "$C"'
kill "$HERDR" 2>/dev/null || true
wait "$HERDR" 2>/dev/null || true
unset HERDR_DROVER_ENV HERDR_SOCKET_PATH HERDR_PANE_ID AH_COMPANION_HARNESS

# Activity: a prompt reports working; a stop that ends the turn reports idle;
# a stop that delivers a message continues the turn and reports nothing.
stop() { printf '{"session_id":"%s"}' "$1" | "$ROOT/hooks/stop.sh"; }
: >"$WORK/requests.log"
prompt "$B" "$APP" hello >/dev/null
check "a prompt reports the session working" 'grep -qx "session.activity working" "$WORK/requests.log"'
: >"$WORK/requests.log"
stop "$B" >/dev/null
check "a stop that ends the turn reports the session idle" 'grep -qx "session.activity idle" "$WORK/requests.log"'
printf '[{"id":"m1","sender_id":"pi-app","body":"ping"}]' >"$WORK/requests.log.pending.json"
: >"$WORK/requests.log"
OUT=$(stop "$B")
check "a stop that delivers a message blocks with it" 'printf "%s" "$OUT" | grep -q "\"decision\":\"block\".*ping"'
check "a stop that delivers a message does not report idle" '! grep -q "session.activity" "$WORK/requests.log"'
check "the stop that shows a message does not ack it" '! grep -q "^message.ack" "$WORK/requests.log"'
rm "$WORK/requests.log.pending.json"
: >"$WORK/requests.log"
stop "$B" >/dev/null
check "the next hook acks the shown message" 'grep -q "^message.ack" "$WORK/requests.log"'

# /ah:on starts the waiter: the prompt's async waiter waits for the command's
# bash to register, longer than the 10 s a plain prompt allows. A second
# waiter for the same session exits at once.
E=55555555-5555-4555-8555-555555555555
waiter() { printf '{"session_id":"%s","prompt":"%s"}' "$1" "$2" | "$ROOT/hooks/wait-wake.sh"; }
: >"$WORK/requests.log"
waiter "$E" "/ah:on" >/dev/null 2>&1 &
FIRST=$!
sleep 11
command_md on "$E" "$APP" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "^wait" "$WORK/requests.log" && break; sleep 0.5; done
check "/ah:on arms a waiter after connecting" 'grep -q "^wait" "$WORK/requests.log" && kill -0 "$FIRST" 2>/dev/null'
waiter "$E" hello >/dev/null 2>&1 &
SECOND=$!
for _ in 1 2 3 4 5 6; do kill -0 "$SECOND" 2>/dev/null || break; sleep 0.5; done
check "a second waiter for the session exits at once" '! kill -0 "$SECOND" 2>/dev/null && [ "$(grep -c "^wait" "$WORK/requests.log")" = 1 ]'
pkill -f "wake-wait $E" 2>/dev/null || true
wait "$FIRST" 2>/dev/null || true
check "every prompt can arm the waiter" 'jq -e ".hooks.UserPromptSubmit[0].hooks[] | select(.asyncRewake and (.command | endswith(\"wait-wake.sh\")))" "$ROOT/hooks/hooks-claude.json" >/dev/null'
stop_daemon

python3 "$ROOT/tests/messaging.py" || FAILED=1
python3 "$ROOT/tests/capture.py" || FAILED=1

[ "$FAILED" = 0 ] && echo "all passed"
exit "$FAILED"
