"""ROADMAP #27: check_room_inbox counted one message twice.

Live cause (read-only check 2026-11-11): SNOW Sync is a personal room with two slots of the same
profile (owner slot assistant_profile_id NULL + assistant CEO). send_room_message writes one
message_recipients row per slot, and check_inbox returns one row per recipient row, so a caller
without assistant_id saw the message twice. 1 message = 1 item.
"""
from types import SimpleNamespace

import pytest


def _row(mid, subject="s", priority="normal"):
    return {"message_id": mid, "priority": priority, "sender_name": "P", "sender_assistant": "@ceo",
            "room_name": "SNOW Sync", "subject": subject, "message_type": "info",
            "deadline": None, "sent_at": "2026-11-11T14:29:13Z"}


@pytest.fixture
def check(monkeypatch):
    from enterprise.messaging import inbox
    captured, state = {}, SimpleNamespace(rows=[], calls=[])

    class Mcp:
        def tool(self, fn):
            captured[fn.__name__] = fn
            return fn

    class Client:
        def rpc(self, name, params):
            state.calls.append((name, params))
            return SimpleNamespace(execute=lambda: SimpleNamespace(data=list(state.rows)))

    inbox.register_tools(Mcp())
    monkeypatch.setattr(inbox, "get_supabase", lambda: object())
    monkeypatch.setattr(inbox, "_caller_is_logged_in", lambda: True)
    monkeypatch.setattr(inbox, "get_supabase_with_auth", lambda: Client())
    return captured["check_room_inbox"], state


def test_one_message_two_recipient_rows_is_one_item(check):
    fn, state = check
    state.rows = [_row("m1"), _row("m1")]  # owner slot row + assistant slot row
    r = fn("przemek_(snow)", room_id="6daf8274-cd26-4109-ae44-8e2bf9e4d591")
    assert r["unread_count"] == 1
    assert [m["id"] for m in r["messages"]] == ["m1"]


def test_distinct_messages_kept_in_order(check):
    fn, state = check
    state.rows = [_row("u", priority="urgent"), _row("a"), _row("u", priority="urgent"), _row("b"), _row("a")]
    r = fn("p")
    assert r["unread_count"] == 3
    assert [m["id"] for m in r["messages"]] == ["u", "a", "b"]


def test_empty_inbox_unchanged(check):
    fn, state = check
    state.rows = []
    r = fn("p")
    assert r["unread_count"] == 0 and r["messages"] == []
