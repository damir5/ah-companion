"""Native lifecycle, replay and hook-output checks: python3 tests/capture.py."""
import contextlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("ahc", ROOT / "hooks/ahc.py")
ahc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ahc)


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.env = patch.dict(os.environ, {"XDG_STATE_HOME": self.directory.name,
            "CLAUDE_PLUGIN_ROOT": str(ROOT), "AH_COMPANION_HARNESS_PID": "9999"})
        self.env.start()
        self.addCleanup(self.env.stop)
        os.environ.pop("AH_COMPANION_DISABLE", None)
        self.native = "native-parent"
        ahc.save_state(self.native, {"session_id": "hub-parent", "native_session_id": self.native,
            "harness": "claude", "token": "test-token", "slug": "test-parent"})

    def hook(self, child="child-a", event="SubagentStart"):
        return {"session_id": self.native, "agent_id": child, "agent_type": "Explore",
            "hook_event_name": event, "last_assistant_message": "private result", "prompt": "private prompt"}

    def test_child_identity_resume_and_private_payload(self):
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok": True}):
            ahc.child_hook(self.hook())
            ahc.child_hook(self.hook(event="SubagentStop"))
            ahc.child_hook(self.hook())
            ahc.child_hook(self.hook(child="child-b"))
        children = [c["child"] for c in calls if c["child"]["kind"] != "capability"]
        self.assertEqual([c["execution_key"] for c in children], ["child-a/1", "child-a/1", "child-a/2", "child-b/1"])
        self.assertEqual(children[1]["terminal_reason"], "response_ended")
        self.assertNotIn("private", json.dumps(calls))
        self.assertEqual(Path(ahc.state_dir()).stat().st_mode & 0o777, 0o700)
        self.assertEqual(Path(ahc.capture_path(self.native)).stat().st_mode & 0o777, 0o600)

    def test_outage_replay_retains_exact_event_and_can_flush_after_end(self):
        with patch.object(ahc, "request", side_effect=OSError("daemon down")):
            ahc.child_hook(self.hook())
        pending = ahc.load_capture(self.native)["events"][0]
        state = ahc.load_state(self.native)
        state["ended_at"] = time.time()
        ahc.save_state(self.native, state)
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok": True}):
            ahc.flush_children(self.native, time.monotonic() + 1)
            ahc.flush_children(self.native, time.monotonic() + 1)
        self.assertEqual(calls[0]["child"], pending)
        self.assertEqual(ahc.load_capture(self.native)["events"], [])
        self.assertEqual(sum(c["child"]["kind"] == "started" for c in calls), 1)

    def test_backlog_overflow_preserves_old_records_and_reports_loss(self):
        capture = ahc.load_capture(self.native)
        capture["events"] = [{"event_id": str(i)} for i in range(256)]
        ahc.atomic_json(ahc.capture_path(self.native), capture)
        with patch.object(ahc, "request", side_effect=OSError("daemon down")):
            ahc.child_hook(self.hook())
        saved = ahc.load_capture(self.native)
        self.assertEqual(saved["events"], capture["events"])
        self.assertEqual(saved["loss_count"], 1)
        self.assertLessEqual(Path(ahc.capture_path(self.native)).stat().st_size, 1024 * 1024)

    def test_missing_fields_disabled_and_codex_never_claim_claude_hooks(self):
        with patch.object(ahc, "request") as request:
            ahc.child_hook({})
            ahc.child_hook(dict(self.hook(), agent_id=42))
            with patch.dict(os.environ, {"AH_COMPANION_DISABLE": "1"}):
                ahc.child_hook(self.hook())
            state = ahc.load_state(self.native)
            state["harness"] = "codex"
            ahc.save_state(self.native, state)
            ahc.child_hook(self.hook())
            ahc.flush_children(self.native, time.monotonic() + 1)
            request.assert_not_called()

    def test_end_targets_hub_id_and_keeps_retained_child_credential(self):
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok": True}), \
             patch.object(sys, "argv", ["ahc.py", "end", self.native]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ahc.main(), 0)
        self.assertEqual(calls, [{"type": "session.end", "session_id": "hub-parent", "token": "test-token"}])
        self.assertIn("ended_at", ahc.load_state(self.native))
        self.assertEqual(ahc.load_state(self.native)["token"], "test-token")

    def test_permanent_refusal_preserves_rejected_evidence_and_continues(self):
        with patch.object(ahc, "request", side_effect=OSError("daemon down")):
            ahc.child_hook(self.hook())
            ahc.child_hook(self.hook(child="child-b"))
        head = ahc.load_capture(self.native)["events"][0]
        calls = []
        def respond(payload, **kw):
            calls.append(payload)
            return {"error_code": "invalid_child_event", "error": "fixture refused"} if payload["child"]["event_id"] == head["event_id"] else {"ok": True}
        with patch.object(ahc, "request", side_effect=respond):
            ahc.flush_children(self.native, time.monotonic() + 1)
        capture = ahc.load_capture(self.native)
        self.assertEqual(capture["events"], [])
        self.assertEqual(capture["rejected"][0]["event_id"], head["event_id"])
        self.assertEqual(capture["loss_count"], 1)
        self.assertTrue(any(c["child"].get("native_child_id") == "child-b" for c in calls))
        self.assertEqual(calls[-1]["child"]["capability"]["loss_count"], 1)

    def test_next_hook_drains_disconnected_parent_with_its_child_only_credential(self):
        with patch.object(ahc, "request", side_effect=OSError("daemon down")):
            ahc.child_hook(self.hook())
        pending = ahc.load_capture(self.native)["events"][0]
        def end_response(payload, **kw):
            return {"ok": True} if payload["type"] == "session.end" else {"error": "offline"}
        with patch.object(ahc, "request", side_effect=end_response), patch.object(sys, "argv", ["ahc.py", "end", self.native]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ahc.main(), 0)
        os.remove(ahc.state_file(self.native))
        ahc.save_state("new-parent", {"session_id": "hub-new", "native_session_id": "new-parent", "token": "new-token", "harness": "claude"})
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok": True}):
            ahc.child_hook(dict(self.hook(child="new-child"), session_id="new-parent"))
        replay = next(c for c in calls if c["child"]["event_id"] == pending["event_id"])
        self.assertEqual(replay["child"], pending)
        self.assertEqual(replay["token"], "test-token")
        self.assertEqual(ahc.load_capture(self.native)["events"], [])
        self.assertEqual(ahc.load_state(self.native), {})

    def test_failed_end_keeps_child_credential_when_off_removes_active_state(self):
        with patch.object(ahc, "request", side_effect=OSError("daemon down")):
            ahc.child_hook(self.hook())
            with patch.object(sys, "argv", ["ahc.py", "end", self.native]):
                with self.assertRaises(OSError):
                    ahc.main()
        os.remove(ahc.state_file(self.native))
        owner = ahc.load_child_state(self.native)
        original_end = owner["ended_at"]
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok":True}):
            ahc.flush_retained_children(time.monotonic()+1)
        self.assertEqual(ahc.load_capture(self.native)["events"], [])
        self.assertEqual(calls[0]["token"], "test-token")
        self.assertEqual(owner["ended_at"], original_end)
        self.assertEqual(ahc.load_state(self.native), {})

    def test_late_stop_after_off_uses_proven_child_and_never_starts_new_work(self):
        with patch.object(ahc, "request", return_value={"ok":True}), contextlib.redirect_stdout(io.StringIO()):
            ahc.child_hook(self.hook())
            with patch.object(sys, "argv", ["ahc.py", "end", self.native]):
                self.assertEqual(ahc.main(), 0)
        os.remove(ahc.state_file(self.native))
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok":True}):
            ahc.child_hook(self.hook(event="SubagentStop"))
            ahc.child_hook(self.hook(child="unknown", event="SubagentStop"))
            ahc.child_hook(self.hook(child="new-child"))
        observed = [c["child"] for c in calls if c["type"] == "session.child" and c["child"]["kind"] != "capability"]
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["kind"], "ended")
        self.assertEqual(observed[0]["execution_key"], "child-a/1")
        self.assertEqual(ahc.load_state(self.native), {})

    def test_old_rejections_do_not_permanently_exhaust_capture(self):
        capture = ahc.load_capture(self.native)
        capture["rejected"] = [{"event_id":str(i), "rejection_code":"invalid_child_event"} for i in range(256)]
        capture["loss_count"] = 256
        ahc.atomic_json(ahc.capture_path(self.native), capture)
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append(payload) or {"ok":True}):
            ahc.child_hook(self.hook(child="recovered-child"))
        self.assertTrue(any(c["child"].get("native_child_id") == "recovered-child" for c in calls))
        saved = ahc.load_capture(self.native)
        self.assertEqual(saved["loss_count"], 256)
        self.assertEqual(len(saved["rejected"]), 16)
        self.assertLessEqual(Path(ahc.capture_path(self.native)).stat().st_size, 1024 * 1024)

    def test_native_codex_state_mapping_and_wait_timeout(self):
        calls = []
        with patch.object(ahc, "request", side_effect=lambda payload, **kw: calls.append((payload, kw)) or {"ok": True}), \
             patch.object(sys, "argv", ["ahc.py", "register", "codex", "codex-test", "thr_native"]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ahc.main(), 0)
        self.assertEqual(calls[0][0]["owner_ref"], "codex:thr_native")
        self.assertNotEqual(calls[0][0]["session_id"], "thr_native")
        self.assertEqual(ahc.load_state("thr_native")["native_session_id"], "thr_native")
        self.assertEqual(len(calls), 1)
        with patch.object(ahc, "request", return_value={"ok": True}) as request, \
             patch.object(sys, "argv", ["ahc.py", "wait", "token", "1700"]), contextlib.redirect_stdout(io.StringIO()):
            ahc.main()
        request.assert_called_once_with({"type": "wait", "token": "token", "timeout_ms": 1700000}, 1720)

    def test_real_stop_and_prompt_hooks_escape_quotes_newlines_unicode(self):
        config = Path(self.directory.name) / "hub"
        config.mkdir()
        path = str(config / "daemon.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen()
        server.settimeout(0.1)
        stop = threading.Event()
        message = {"id": "message", "sender_id": 'sender"quoted', "body": 'line "one"\nline two\\three ž'}

        def serve():
            while not stop.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    chunks = b""
                    while not chunks.endswith(b"\n"):
                        part = conn.recv(65536)
                        if not part:
                            break
                        chunks += part
                    request = json.loads(chunks)
                    response = {"ok": True, "messages": [message]} if request["type"] == "message.pending" else {"ok": True}
                    conn.sendall((json.dumps(response) + "\n").encode())
        worker = threading.Thread(target=serve)
        worker.start()
        try:
            with patch.dict(os.environ, {"AGENT_HUB_CONFIG_DIR": str(config)}):
                for hook in ("stop.sh", "user-prompt-submit.sh"):
                    result = subprocess.run([str(ROOT / "hooks" / hook)], input=json.dumps({"session_id": self.native, "prompt": "hello"}), text=True, capture_output=True, check=True)
                    decoded = json.loads(result.stdout)
                    text = decoded.get("reason") or decoded["hookSpecificOutput"]["additionalContext"]
                    self.assertIn(message["body"], text)
        finally:
            stop.set()
            worker.join()
            server.close()


if __name__ == "__main__":
    unittest.main()
