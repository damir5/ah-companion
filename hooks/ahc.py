#!/usr/bin/env python3
"""ahc — Agent Hub companion CLI for claude/codex plugin hooks.

Speaks the ah daemon's local unix-socket protocol: one JSON request per
connection, one JSON response (line-delimited). Resolves the socket from
AGENT_HUB_CONFIG_DIR / config.json, same rules as the ah CLI.

Subcommands (all print the daemon response JSON to stdout, exit non-zero on
connection errors):
  register <harness> <slug> <session_id> [model]   → token in response
  wait <token> [timeout_sec]                       → blocks; message or timeout
  ack <token> <message_id>
  fail <token> <message_id> <reason>
  pending <token>                                  → queued messages
  end <token>
  project-marker <dir>                             → path of the auto-register marker
  send-current <slug> <body>                       → DM as the enclosing session

Session state (token/slug) is kept by the caller; hooks store it in the
state dir next to this script's data directory.
"""

import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import uuid


def config_dir() -> str:
    env = os.environ.get("AGENT_HUB_CONFIG_DIR")
    if env:
        return env
    if sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "agent-hub")


def socket_path() -> str:
    d = config_dir()
    cfg = os.path.join(d, "config.json")
    try:
        with open(cfg, "r", encoding="utf-8") as f:
            s = os.path.join(d, json.load(f).get("socket") or "daemon.sock")
            return s
    except Exception:
        return os.path.join(d, "daemon.sock")


def request(payload: dict, timeout: float = 35.0) -> dict:
    path = socket_path()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(path)
    except OSError as e:
        print(json.dumps({"error": f"connect {path}: {e}"}), file=sys.stderr)
        sys.exit(3)
    try:
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            try:
                data = sock.recv(65536)
            except socket.timeout:
                break
            if not data:
                break
            chunks.append(data)
        raw = b"".join(chunks).decode("utf-8", "replace").strip()
        if not raw:
            return {"error": "empty response"}
        # Tolerate trailing lines; parse the first JSON object.
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            dec = json.JSONDecoder()
            obj, _ = dec.raw_decode(raw)
            return obj
    finally:
        sock.close()



def _ps_command(pid: int) -> str:
    try:
        with os.popen(f"ps -o command= -p {pid} 2>/dev/null") as p:
            return p.read().strip()
    except Exception:
        return ""


def resolve_harness_pid(harness: str) -> int:
    """Walk from this hook's parent up to the topmost ancestor whose command
    names the harness binary; register THAT pid so the session lives as long
    as the harness, not a transient worker."""
    needle = "claude" if harness == "claude" else harness
    pid = os.getppid()
    best = 0
    for _ in range(12):  # bound the walk
        if pid <= 1:
            break
        cmd = _ps_command(pid)
        if not cmd:
            break
        if needle in cmd.split(" ")[0] or f"/{needle}" in cmd or cmd.startswith(needle):
            best = pid
        ppid = 0
        try:
            with os.popen(f"ps -o ppid= -p {pid} 2>/dev/null") as p:
                ppid = int((p.read().strip() or "0"))
        except ValueError:
            break
        if ppid <= 1:
            break
        pid = ppid
    return best or os.getppid()

def state_dir() -> str:
    # NEVER use CLAUDE_PLUGIN_DATA / PLUGIN_DATA here: harnesses may point
    # them at per-session temp dirs that are wiped when the session ends.
    # A single stable dir shared by claude/codex keeps tokens findable by
    # every hook across the session lifetime.
    base = os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "ah-companion",
    )
    os.makedirs(base, exist_ok=True)
    return base


def state_file(session_id: str) -> str:
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in session_id)
    return os.path.join(state_dir(), f"session-{safe}.json")


def project_marker(directory: str) -> str:
    """Marker file whose presence opts a project (its Git root, else the
    directory) into auto-registration at SessionStart. /ah:on creates it,
    /ah:off removes it."""
    try:
        root = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        root = directory
    # Key by a hash of the canonical path: replacing separators alone made
    # /tmp/a.b and /tmp/a/b share one marker.
    root = os.path.realpath(root)
    name = "".join(c if c.isalnum() or c in "-_" else "_" for c in os.path.basename(root))
    digest = hashlib.sha256(root.encode("utf-8")).hexdigest()[:16]
    return os.path.join(state_dir(), f"project-{name[:32]}-{digest}.on")


def save_state(session_id: str, data: dict) -> None:
    with open(state_file(session_id), "w", encoding="utf-8") as f:
        json.dump(data, f)


def load_state(session_id: str) -> dict:
    try:
        with open(state_file(session_id), "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = args[0], args[1:]

    if cmd == "register":
        harness, slug, session_id = rest[0], rest[1], rest[2]
        model = rest[3] if len(rest) > 3 else ""
        # The daemon requires a UUID session id; codex threads are thr_…
        # strings, so derive a stable UUID from the harness-native id.
        try:
            uuid.UUID(session_id)
        except (ValueError, AttributeError):
            session_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{harness}:{session_id}"))
        token = f"ahc-{int(time.time()*1000)}-{session_id[-8:]}"
        # The session must live as long as the HARNESS process, not this
        # short-lived hook. Hooks may run under transient harness workers,
        # so climb the ancestor chain to the TOPMOST matching harness
        # process — the daemon reaps sessions whose pid dies.
        harness_pid = int(os.environ.get("AH_COMPANION_HARNESS_PID") or 0) or resolve_harness_pid(harness)
        resp = request(
            {
                "type": "session.register",
                "session_id": session_id,
                "agent_slug": slug,
                "pid": harness_pid,
                "token": token,
                "harness": harness,
                "driver": "stream",
                "cwd": os.getcwd(),
                "project": os.path.basename(os.getcwd()),
                "activity": "idle",
                "owner_ref": f"{harness}:{session_id}",
                **({"model": model} if model else {}),
            }
        )
        if resp.get("ok"):
            save_state(session_id, {"token": token, "slug": slug, "session_id": session_id, "harness_pid": harness_pid})
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "wait":
        token, session_id = rest[0], rest[1]
        timeout = int(rest[2]) if len(rest) > 2 else 600
        resp = request({"type": "wait", "token": token, "timeout_ms": timeout * 1000}, timeout + 20)
        print(json.dumps(resp))
        return 0

    if cmd == "ack":
        token, message_id = rest[0], rest[1]
        resp = request({"type": "message.ack", "token": token, "message_id": message_id})
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "fail":
        token, message_id = rest[0], rest[1]
        reason = rest[2] if len(rest) > 2 else "delivered-failed"
        resp = request({"type": "message.fail", "token": token, "message_id": message_id, "reason": reason})
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "pending":
        token = rest[0]
        resp = request({"type": "message.pending", "token": token})
        print(json.dumps(resp))
        return 0

    if cmd == "end":
        state = load_state(rest[0]) if rest else {}
        token = rest[1] if len(rest) > 1 else state.get("token", "")
        session_id = rest[0] if rest else state.get("session_id", "")
        if not token:
            print(json.dumps({"ok": True, "skipped": "no state"}))
            return 0
        resp = request({"type": "session.end", "token": token})
        try:
            os.remove(state_file(session_id))
        except OSError:
            pass
        print(json.dumps(resp))
        return 0

    if cmd == "socket":
        print(socket_path())
        return 0

    if cmd == "project-marker":
        print(project_marker(rest[0]))
        return 0

    if cmd == "state-path":
        print(state_file(rest[0]))
        return 0

    if cmd == "rename":
        session_id, slug = rest[0], rest[1]
        state = load_state(session_id)
        token = rest[2] if len(rest) > 2 else state.get("token", "")
        if not token:
            print(json.dumps({"error": "no registration state for session"}))
            return 1
        resp = request({"type": "session.rename", "token": token, "agent_slug": slug})
        if resp.get("ok"):
            state["slug"] = slug
            save_state(session_id, state)
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "send-current":
        if len(rest) != 2 or not rest[0] or not rest[1]:
            print(json.dumps({"error": "usage: ahc.py send-current <target-slug> <message body>"}))
            return 2
        session = request({"type": "session.resolve"})
        if not session.get("token"):
            if session.get("error_code") == "sender_identity_missing":
                session["error"] = "this session is not registered; run /ah:on or ah connect in this session"
            print(json.dumps(session))
            return 1
        resp = request({"type": "message.send", "token": session["token"], "agent_slug": session.get("agent_slug", ""), "dm": rest[0], "body": rest[1]})
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "send":
        # send a DM as THIS session (the pane's agent identity) — no ah login needed
        session_id, target = rest[0], rest[1]
        body = rest[2] if len(rest) > 2 else ""
        state = load_state(session_id)
        token = state.get("token", "")
        if not token:
            print(json.dumps({"error": "no registration state for session"}))
            return 1
        resp = request({"type": "message.send", "token": token, "agent_slug": state.get("slug", ""), "dm": target, "body": body})
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "whoami":
        session_id = rest[0]
        state = load_state(session_id)
        if not state:
            print(json.dumps({"registered": False}))
            return 0
        st = request({"type": "status"})
        print(json.dumps({"registered": True, **{k: state[k] for k in ("slug", "session_id") if k in state}}))
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
