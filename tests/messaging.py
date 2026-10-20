"""Run with python3 tests/messaging.py."""
import contextlib
import fcntl
import importlib.util
import io
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


def fake_daemon(messages=(), waits=()):
    """request() stand-in: message.pending returns the messages not acked yet,
    wait returns the waits in order, ack answers ok. Every request is recorded."""
    calls, messages, waits = [], list(messages), list(waits)

    def request(payload, timeout=35.0):
        calls.append(payload)
        if payload["type"] == "message.pending":
            return {"ok": True, "messages": list(messages)}
        if payload["type"] == "wait":
            return waits.pop(0)
        if payload["type"] == "message.ack":
            messages[:] = [m for m in messages if m["id"] != payload["message_id"]]
        return {"ok": True}
    return request, calls


def acked(calls):
    return [c["message_id"] for c in calls if c["type"] == "message.ack"]


def handed_ids():
    return ahc.handed("s", lambda ids: ids)


class SessionStateTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        env = patch.dict(os.environ, {"XDG_STATE_HOME": directory.name})
        env.start()
        self.addCleanup(env.stop)
        ahc.save_state("s", {"token": "t", "harness_pid": os.getpid()})


class DeliveryTest(SessionStateTest):
    def test_header_names_sender_room_thread_id_and_reply_command(self):
        text = ahc.render_message({"id": "m2", "sender_id": "codex-api", "room": "team", "thread_root_id": "m1", "body": "hi"})
        self.assertEqual(text, '[From codex-api via Agent Hub; room team; thread m1; id m2; reply: ah reply --reply-to m2 "<text>"]\nhi')

    def test_header_without_room_or_thread_still_gives_the_reply_command(self):
        text = ahc.render_message({"id": "m1", "sender_id": "pi-app", "thread_root_id": "m1", "body": "hi"})
        self.assertEqual(text.splitlines()[0], '[From pi-app via Agent Hub; id m1; reply: ah reply --reply-to m1 "<text>"]')

    def test_only_whole_messages_that_fit_are_shown_and_acked(self):
        # A message that does not fit stays pending, and so does everything after it,
        # so the agent reads the thread in order at the next delivery point.
        big = "x" * ahc.DELIVERY_BUDGET
        request, calls = fake_daemon([{"id": "a", "body": "first"}, {"id": "b", "body": big}, {"id": "c", "body": "third"}])
        with patch.object(ahc, "request", request):
            text = ahc.deliver("s")
        self.assertEqual(handed_ids(), ["a"])
        self.assertIn("first", text)
        self.assertNotIn("xxx", text)
        self.assertIn("2 more Agent Hub message(s) pending", text)

    def test_a_first_message_larger_than_the_budget_is_cut_not_starved(self):
        request, calls = fake_daemon([{"id": "a", "body": "x" * (2 * ahc.DELIVERY_BUDGET)}])
        with patch.object(ahc, "request", request):
            text = ahc.deliver("s")
        self.assertEqual(handed_ids(), ["a"])
        self.assertLessEqual(len(text.encode()), ahc.DELIVERY_BUDGET)
        self.assertIn("message cut at", text)

    def test_stop_delivery_hands_over_only_the_message_it_shows(self):
        request, calls = fake_daemon([{"id": "a", "body": "one"}, {"id": "b", "body": "two"}])
        with patch.object(ahc, "request", request):
            text = ahc.deliver("s", 1)
        self.assertEqual(handed_ids(), ["a"])
        self.assertNotIn("two", text)

    def test_a_later_message_is_never_delivered_cut(self):
        # Only the first message may arrive cut (else it would never arrive).
        # A later one that does not fit whole stays pending, whatever the
        # multibyte boundary the cut would land on.
        for pad in range(1, 9):
            request, calls = fake_daemon([{"id": "a", "body": "x" * pad}, {"id": "b", "body": "\U0001F600" * ahc.DELIVERY_BUDGET}])
            ahc.handed("s", lambda ids: [])
            with patch.object(ahc, "request", request):
                text = ahc.deliver("s")
            self.assertEqual(handed_ids(), ["a"], pad)
            self.assertNotIn("message cut at", text, pad)

    def test_a_message_is_acked_only_by_the_hook_after_the_one_that_showed_it(self):
        # A crash between showing and the next hook must leave the message
        # unacked (still pending on the hub), not acked and lost.
        request, calls = fake_daemon([{"id": "a", "body": "one"}])
        with patch.object(ahc, "request", request):
            self.assertIn("one", ahc.deliver("s"))
            self.assertEqual(acked(calls), [])
            self.assertEqual(ahc.deliver("s"), "")
        self.assertEqual(acked(calls), ["a"])
        self.assertEqual(handed_ids(), [])

    def test_a_handed_message_whose_ack_fails_is_retried_and_never_shown_again(self):
        def request(payload, timeout=35.0):
            if payload["type"] == "message.pending":
                return {"ok": True, "messages": [{"id": "a", "body": "one"}]}
            return {"error": "hub is disconnected"}
        with patch.object(ahc, "request", request):
            self.assertIn("one", ahc.deliver("s"))
            self.assertEqual(ahc.deliver("s"), "")
            self.assertEqual(ahc.deliver("s"), "")
        self.assertEqual(handed_ids(), ["a"])

    def test_the_handed_list_stays_bounded(self):
        for i in range(ahc.HANDED_LIMIT + 5):
            ahc.hand_over("s", str(i))
        self.assertEqual(len(handed_ids()), ahc.HANDED_LIMIT)


class WakeWaitTest(SessionStateTest):

    def test_idle_waiter_keeps_waiting_past_daemon_timeouts(self):
        # An idle session must stay reachable for longer than one daemon wait.
        message = {"id": "m", "sender_id": "codex-api", "room": "team", "body": "ping"}
        request, calls = fake_daemon(waits=[{"ok": False, "status": "timeout"}] * 3 + [{"ok": True, "status": "message", "message": message}])
        stderr = io.StringIO()
        with patch.object(ahc, "request", request), patch.object(ahc, "report_activity") as activity, contextlib.redirect_stderr(stderr):
            self.assertEqual(ahc.wake_wait("s"), 2)
        self.assertEqual([c["type"] for c in calls].count("wait"), 4)
        # The wake is not proof Claude saw it; the next hook acks it.
        self.assertEqual(acked(calls), [])
        self.assertEqual(handed_ids(), ["m"])
        # The wake starts a turn.
        activity.assert_called_once_with("s", "working")
        self.assertIn("[From codex-api via Agent Hub; room team; id m;", stderr.getvalue())

    def test_waiter_survives_hub_disconnects_and_daemon_restarts(self):
        # A hub outage (status disconnect) or a daemon restart mid-wait (error
        # or empty response) must not leave an idle session without a waiter.
        message = {"id": "m", "sender_id": "codex-api", "body": "ping"}
        request, calls = fake_daemon(waits=[{"ok": False, "status": "disconnect"}, {"error": "empty response"},
            {"error": "hub request timed out", "error_code": "server_timeout"}, {"ok": True, "status": "message", "message": message}])
        with patch.object(ahc, "request", request), patch.object(ahc.time, "sleep") as sleep, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ahc.wake_wait("s"), 2)
        self.assertEqual(handed_ids(), ["m"])
        self.assertEqual(sleep.call_count, 3)

    def test_waiter_never_wakes_twice_for_a_handed_message(self):
        # A daemon reconnect pushes unacked mail again; the waiter must not
        # show a message an earlier hook already handed over.
        ahc.hand_over("s", "old")
        old, new = {"id": "old", "body": "seen"}, {"id": "new", "body": "fresh"}
        request, calls = fake_daemon(waits=[{"ok": True, "status": "message", "message": old}, {"ok": True, "status": "message", "message": new}])
        stderr = io.StringIO()
        with patch.object(ahc, "request", request), patch.object(ahc, "report_activity"), contextlib.redirect_stderr(stderr):
            self.assertEqual(ahc.wake_wait("s"), 2)
        self.assertNotIn("seen", stderr.getvalue())
        self.assertIn("fresh", stderr.getvalue())

    def test_waiter_stops_when_the_harness_is_gone(self):
        ahc.save_state("s", {"token": "t", "harness_pid": 999999})
        request, calls = fake_daemon()
        with patch.object(ahc, "request", request):
            self.assertEqual(ahc.wake_wait("s"), 0)
        self.assertEqual(calls, [])

    def test_waiter_stops_when_the_session_is_switched_off(self):
        def request(payload, timeout=35.0):
            os.remove(ahc.state_file("s"))
            return {"ok": False, "status": "timeout"}
        with patch.object(ahc, "request", request):
            self.assertEqual(ahc.wake_wait("s"), 0)

    def test_second_waiter_for_the_same_session_exits_without_waiting(self):
        with open(ahc.state_file("s") + ".waiter", "a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            request, calls = fake_daemon()
            with patch.object(ahc, "request", request):
                self.assertEqual(ahc.wake_wait("s"), 0)
        self.assertEqual(calls, [])

    def test_waiter_removes_its_lock_file_when_it_exits(self):
        def request(payload, timeout=35.0):
            os.remove(ahc.state_file("s"))
            return {"ok": False, "status": "timeout"}
        with patch.object(ahc, "request", request):
            self.assertEqual(ahc.wake_wait("s"), 0)
        self.assertFalse(os.path.exists(ahc.state_file("s") + ".waiter"))


class RegisterTest(unittest.TestCase):
    def test_second_session_in_a_directory_registers_under_a_hub_picked_name(self):
        # claude-app is held by another live session; the hub refuses it, and
        # later commands (send) must use the name the hub picked instead.
        calls = []

        def request(payload, timeout=35.0):
            calls.append(payload)
            if payload["type"] == "session.register":
                if not payload.get("auto_name"):
                    return {"error": "identity claude-app is already in use", "error_code": "identity_unavailable"}
                return {"ok": True, "session_id": payload["session_id"], "agent_slug": "otter"}
            return {"ok": True}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"XDG_STATE_HOME": directory, "AH_COMPANION_HARNESS_PID": str(os.getpid())}), \
                patch.object(ahc, "request", request), contextlib.redirect_stdout(io.StringIO()):
            with patch.object(sys, "argv", ["ahc.py", "register", "claude", "claude-app", "11111111-1111-4111-8111-111111111111"]):
                self.assertEqual(ahc.main(), 0)
            self.assertEqual(ahc.load_state("11111111-1111-4111-8111-111111111111")["slug"], "otter")
            with patch.object(sys, "argv", ["ahc.py", "send", "11111111-1111-4111-8111-111111111111", "target", "hi"]):
                self.assertEqual(ahc.main(), 0)
        registers = [c for c in calls if c["type"] == "session.register"]
        self.assertEqual([c.get("auto_name") for c in registers], [None, True])
        self.assertEqual(calls[-1]["agent_slug"], "otter")


if __name__ == "__main__":
    unittest.main()
