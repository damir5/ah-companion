"""Run with python3 tests/messaging.py."""
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ahc", Path(__file__).parents[1] / "hooks/ahc.py")
ahc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ahc)


class MessagingTest(unittest.TestCase):
    def test_current_sender_ignores_newer_same_harness_and_other_harness_state(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_STATE_HOME": directory}):
            for session, token in [("current-codex", "current-token"), ("newer-codex", "peer-token"), ("newest-claude", "other-token")]:
                ahc.save_state(session, {"session_id": session, "token": token, "slug": session})
            calls = []

            def request(payload):
                calls.append(payload)
                if payload["type"] == "session.resolve":
                    return {"ok": True, "session_id": "current-codex", "token": "current-token", "agent_slug": "current-codex"}
                return {"ok": True}

            with patch.object(ahc, "request", request), patch.object(sys, "argv", ["ahc.py", "send-current", "target", "body"]):
                self.assertEqual(ahc.main(), 0)
            self.assertEqual(calls, [
                {"type": "session.resolve"},
                {"type": "message.send", "token": "current-token", "agent_slug": "current-codex", "dm": "target", "body": "body"},
            ])

    def test_unregistered_sender_never_borrows_peer_state(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_STATE_HOME": directory}):
            ahc.save_state("peer", {"token": "peer-token", "session_id": "peer"})
            with patch.object(ahc, "request", return_value={"error_code": "sender_identity_missing", "error": "no enclosing session"}) as request, patch.object(sys, "argv", ["ahc.py", "send-current", "target", "body"]):
                self.assertEqual(ahc.main(), 1)
                request.assert_called_once_with({"type": "session.resolve"})


if __name__ == "__main__":
    unittest.main()
