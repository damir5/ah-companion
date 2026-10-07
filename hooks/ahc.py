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
  end <native_session_id> [token]
  flush-children <native_session_id>               → bounded child evidence replay
  capture-status <native_session_id>               → sanitized capture readiness/backlog
  project-marker <dir>                             → path of the auto-register marker
  send-current <slug> <body>                       → DM as the enclosing session

Session state (token/slug) is kept by the caller; hooks store it in the
state dir next to this script's data directory.
"""

import hashlib
import fcntl
import glob
import json
import os
import socket
import secrets
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
    os.makedirs(base, mode=0o700, exist_ok=True)
    os.chmod(base, 0o700)
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
    atomic_json(state_file(session_id), data)


def atomic_json(path: str, data) -> None:
    temporary = path + ".tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(temporary, path)


def load_state(session_id: str) -> dict:
    try:
        with open(state_file(session_id), "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def load_child_state(native_parent: str) -> dict:
    state = load_state(native_parent)
    if state:
        return state
    try:
        with open(state_file(native_parent) + ".children-owner", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def capture_path(native_parent: str) -> str:
    return state_file(native_parent) + ".children"


def capture_lock(native_parent: str):
    fd = os.open(capture_path(native_parent) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    lock = os.fdopen(fd, "w")
    deadline = time.monotonic() + 0.2
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                lock.close()
                return None
            time.sleep(0.01)
    return lock


def load_capture(native_parent: str) -> dict:
    try:
        with open(capture_path(native_parent), encoding="utf-8") as f:
            capture = json.load(f)
            capture.setdefault("rejected", [])
            trim_rejected(capture)
            return capture
    except FileNotFoundError:
        return {"events": [], "rejected": [], "children": {}, "loss_count": 0}


def trim_rejected(capture: dict) -> None:
    while len(capture["rejected"]) > 16 or len(json.dumps(capture["rejected"]).encode()) > 64 * 1024:
        capture["rejected"].pop(0)


def child_hook(payload: dict) -> None:
    if os.environ.get("AH_COMPANION_DISABLE") == "1":
        return
    parent = payload.get("session_id")
    child = payload.get("agent_id")
    event = payload.get("hook_event_name")
    if not isinstance(parent, str) or not parent or not isinstance(child, str) or not child or len(child) > 128:
        return
    if event not in ("SubagentStart", "SubagentStop"):
        return
    state = load_child_state(parent)
    if not state.get("token") or state.get("harness") != "claude":
        return
    if state.get("ended_at") and time.time() - state["ended_at"] > 30 * 24 * 3600:
        return
    if state.get("ended_at") and event == "SubagentStart":
        return
    lock = capture_lock(parent)
    if lock is None:
        # One bounded marker records at least one lost observation under contention.
        fd = os.open(capture_path(parent) + ".loss", os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
        return
    try:
        capture = load_capture(parent)
        if state.get("ended_at") and child not in capture["children"]:
            return
        capture["observed_hook"] = True
        generation = capture["children"].get(child, 0)
        if event == "SubagentStart":
            generation += 1
            children = dict(capture["children"], **{child: generation})
            if len(json.dumps(children).encode()) > 256 * 1024:
                capture["loss_count"] += 1
                atomic_json(capture_path(parent), capture)
                return
            capture["children"] = children
        at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        observation = {"event_id": str(uuid.uuid4()), "parent_session_id": state["session_id"],
            "source": "claude_hook", "execution_key": f"{child}/{generation}", "native_child_id": child,
            "kind": "started" if event == "SubagentStart" else "ended", "observed_at": at}
        label = payload.get("agent_type")
        if isinstance(label, str) and label:
            observation["label"] = label[:200]
        if event == "SubagentStop":
            observation["terminal_reason"] = "response_ended"
        proposed = dict(capture, events=capture["events"] + [observation])
        # Reserve space for incarnation counters and status in the 1 MiB spool.
        evidence = proposed["events"] + proposed["rejected"]
        if len(evidence) > 256 or len(json.dumps(evidence).encode()) > (768 * 1024 - 32768):
            capture["loss_count"] += 1
        else:
            capture = proposed
        atomic_json(capture_path(parent), capture)
    finally:
        lock.close()
    deadline = time.monotonic() + 1.5
    flush_children(parent, deadline=deadline)
    flush_retained_children(deadline)


def flush_children(native_parent: str, deadline: float) -> None:
    state = load_child_state(native_parent)
    if not state.get("token") or state.get("ended_at") and time.time() - state["ended_at"] > 30 * 24 * 3600:
        return
    lock = capture_lock(native_parent)
    if lock is None:
        return
    try:
        capture = load_capture(native_parent)
        if os.path.exists(capture_path(native_parent) + ".loss"):
            capture["loss_count"] += 1
            os.remove(capture_path(native_parent) + ".loss")
            atomic_json(capture_path(native_parent), capture)
        while capture["events"] and time.monotonic() < deadline:
            try:
                response = request({"type": "session.child", "token": state["token"], "child": capture["events"][0]}, timeout=min(0.5, deadline - time.monotonic()))
            except (SystemExit, OSError, ValueError):
                return
            if not response.get("ok"):
                capture["last_error"] = str(response.get("error", "child intake refused"))[:1000]
                code = response.get("error_code")
                if code in ("invalid_child_event", "child_event_conflict", "operation_conflict", "session_not_found", "sender_identity_missing", "sender_identity_invalid"):
                    rejected = dict(capture["events"].pop(0), rejection_code=str(code)[:64])
                    capture["rejected"].append(rejected)
                    trim_rejected(capture)
                    capture["loss_count"] += 1
                    atomic_json(capture_path(native_parent), capture)
                    continue
                atomic_json(capture_path(native_parent), capture)
                return
            capture["events"].pop(0)
            capture.pop("last_error", None)
            atomic_json(capture_path(native_parent), capture)
        if not capture["events"] and time.monotonic() < deadline:
            marker = capture.get("capability_pending")
            if marker is None and not capture.get("capability_rejected") and capture.get("observed_hook") and (capture["loss_count"] != capture.get("reported_loss_count", -1) or not capture.get("capture_ready")):
                marker = {"event_id": str(uuid.uuid4()), "parent_session_id": state["session_id"],
                    "source": "claude_hook", "kind": "capability", "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "capability": {"readiness": "offline" if capture["loss_count"] else "ready", "lifecycle": True,
                        "activity": False, "loss_count": capture["loss_count"], "backlog_count": 0,
                        "reason": "Capture lost observations" if capture["loss_count"] else "Native lifecycle hook observed"}}
                capture["capability_pending"] = marker
                atomic_json(capture_path(native_parent), capture)
            if marker:
                try:
                    response = request({"type": "session.child", "token": state["token"], "child": marker}, timeout=min(0.5, deadline - time.monotonic()))
                except (SystemExit, OSError, ValueError):
                    return
                if response.get("ok"):
                    capture["reported_loss_count"] = marker["capability"]["loss_count"]
                    capture["capture_ready"] = True
                    capture.pop("capability_pending", None)
                    atomic_json(capture_path(native_parent), capture)
                elif response.get("error_code") in ("invalid_child_event", "child_event_conflict", "operation_conflict", "session_not_found", "sender_identity_missing", "sender_identity_invalid"):
                    capture["capability_rejected"] = dict(marker, rejection_code=str(response.get("error_code"))[:64])
                    capture["loss_count"] += 1
                    capture["capture_ready"] = False
                    capture.pop("capability_pending", None)
                    capture["last_error"] = str(response.get("error", "capture capability refused"))[:1000]
                    atomic_json(capture_path(native_parent), capture)
    finally:
        lock.close()


def flush_retained_children(deadline: float) -> None:
    paths = sorted(glob.glob(os.path.join(state_dir(), "session-*.json.children-owner")) +
        glob.glob(os.path.join(state_dir(), "session-*.json")))
    if not paths or time.monotonic() >= deadline:
        return
    cursor_path = os.path.join(state_dir(), "retained-child-cursor.json")
    try:
        with open(cursor_path, encoding="utf-8") as f:
            position = json.load(f) % len(paths)
    except (OSError, ValueError, TypeError):
        position = 0
    for _ in range(min(len(paths), 64)):
        path = paths[position]
        position = (position + 1) % len(paths)
        if time.monotonic() >= deadline:
            break
        try:
            with open(path, encoding="utf-8") as f:
                state = json.load(f)
            native = state.get("native_session_id") or state.get("session_id")
            if native and state.get("ended_at") and time.time() - state["ended_at"] <= 30 * 24 * 3600:
                flush_children(native, deadline)
                if state.get("end_pending") and time.monotonic() < deadline:
                    response = request({"type":"session.end", "session_id":state["session_id"], "token":state["token"]}, timeout=min(0.5, deadline-time.monotonic()))
                    if response.get("ok") or response.get("error_code") in ("sender_identity_missing", "sender_identity_invalid"):
                        state["end_pending"] = False
                        atomic_json(path, state)
        except (OSError, ValueError, KeyError, SystemExit):
            continue
    atomic_json(cursor_path, position)


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = args[0], args[1:]
    if os.environ.get("AH_COMPANION_DISABLE") == "1" and cmd not in ("state-path", "project-marker", "socket"):
        print(json.dumps({"ok": True, "skipped": "disabled"}))
        return 0

    if cmd == "register":
        harness, slug, session_id = rest[0], rest[1], rest[2]
        native_id = session_id
        model = rest[3] if len(rest) > 3 else ""
        # The daemon requires a UUID session id; codex threads are thr_…
        # strings, so derive a stable UUID from the harness-native id.
        try:
            uuid.UUID(session_id)
        except (ValueError, AttributeError):
            session_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{harness}:{session_id}"))
        token = load_state(native_id).get("token") or secrets.token_urlsafe(32)
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
                "owner_ref": f"{harness}:{native_id}",
                **({"model": model} if model else {}),
            },
            timeout=2,
        )
        if resp.get("ok"):
            save_state(native_id, {"token": token, "slug": slug, "session_id": session_id,
                "native_session_id": native_id, "harness": harness, "harness_pid": harness_pid})
            deadline = time.monotonic() + 1
            flush_children(native_id, deadline=deadline)
            flush_retained_children(deadline)
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "wait":
        token = rest[0]
        timeout = int(rest[1]) if len(rest) > 1 else 600
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
        native_id = rest[0] if rest else ""
        session_id = state.get("session_id", native_id)
        if not token:
            print(json.dumps({"ok": True, "skipped": "no state"}))
            return 0
        owner_path = state_file(native_id) + ".children-owner"
        try:
            with open(owner_path, encoding="utf-8") as f:
                original = json.load(f)
        except (OSError, ValueError):
            original = {}
        state["native_session_id"] = native_id
        state["token"] = token
        state["session_id"] = session_id
        state["ended_at"] = original.get("ended_at") if original.get("token") == token and original.get("session_id") == session_id else time.time()
        owner = {key: state[key] for key in ("session_id", "native_session_id", "token", "harness", "ended_at") if key in state}
        owner["end_pending"] = True
        atomic_json(owner_path, owner)
        flush_children(native_id, deadline=time.monotonic() + 1)
        resp = request({"type": "session.end", "session_id": session_id, "token": token}, timeout=1)
        if resp.get("ok"):
            save_state(native_id, state)
            owner["end_pending"] = False
            atomic_json(owner_path, owner)
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1

    if cmd == "child-hook":
        try:
            payload = json.load(sys.stdin)
            if isinstance(payload, dict):
                child_hook(payload)
        except (json.JSONDecodeError, OSError, ValueError, KeyError):
            return 0
        return 0

    if cmd == "flush-children":
        deadline = time.monotonic() + 1.5
        flush_children(rest[0], deadline=deadline)
        flush_retained_children(deadline)
        return 0

    if cmd == "capture-status":
        capture = load_capture(rest[0])
        ready = capture.get("capture_ready") and not capture["events"] and not capture["loss_count"]
        print(json.dumps({"backlog_count": len(capture["events"]), "loss_count": capture["loss_count"],
            "readiness": "ready" if ready else "unverified",
            "reason": capture.get("last_error", "Native lifecycle hook observed" if ready else
                "No verified hook observation" if not capture.get("observed_hook") else "Pending or lost observations")}))
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
