"""
Regression tests for the 2026-09-22 hardening (@ciso #36b B4/B1 → @cto).

- login errors distinguish "no client identity" from "session store failed"
- get_profile hides the contact e-mail from anonymous callers
- check_room_inbox fails closed with a reason instead of "0 unread"
- the web UI (app.py) holds no service-role path
- send_weekly_matches_email needs a logged-in owner
"""
import inspect
import re
from types import SimpleNamespace

import pytest

from auth import magic_link as ml
from core.profiles import crud

BEARER = "e" * 64


@pytest.fixture
def remote(monkeypatch):
    state = SimpleNamespace(headers={}, save=True)
    monkeypatch.setenv("MCP_TRANSPORT", "http")
    monkeypatch.setattr(ml, "_request_headers", lambda: state.headers)
    monkeypatch.setattr(ml, "_save_session", lambda s: state.save)
    monkeypatch.setattr(ml, "_purge_stale_sid_sessions", lambda: None)
    return state


def _session():
    return {"access_token": "jwt", "refresh_token": "rt", "user_id": "u", "email": "o@example.com",
            "expires_at": 4102444800}


def test_finish_login_reports_missing_identity(remote):
    remote.headers = {}
    r = ml._finish_login(_session())
    assert r["success"] is False and r["reason"] == "no_client_identity"


def test_finish_login_reports_store_failure_separately(remote):
    remote.headers = {"authorization": "Bearer " + BEARER}
    remote.save = False
    r = ml._finish_login(_session())
    assert r["success"] is False and r["reason"] == "session_store_failed"
    assert "Bearer" not in r["error"]  # not the client's fault


def test_finish_login_success(remote):
    remote.headers = {"authorization": "Bearer " + BEARER}
    r = ml._finish_login(_session())
    assert r["success"] is True and r["user"]["email"] == "o@example.com"


def test_profile_email_hidden_without_session():
    p = {"id": "x", "name": "X", "email": "x@example.com"}
    anon = crud.public_profile_view(p, logged_in=False)
    assert anon["email"] is None and "email_hidden" in anon
    assert p["email"] == "x@example.com"  # input untouched
    assert crud.public_profile_view(p, logged_in=True)["email"] == "x@example.com"


def test_inbox_fails_closed_with_reason(monkeypatch):
    from enterprise.messaging import inbox
    captured = {}

    class Mcp:
        def tool(self, fn):
            captured[fn.__name__] = fn
            return fn

    inbox.register_tools(Mcp())
    monkeypatch.setattr(inbox, "get_supabase", lambda: object())
    monkeypatch.setattr(inbox, "_caller_is_logged_in", lambda: False)
    r = captured["check_room_inbox"]("victim")
    assert r["authenticated"] is False and "Not authenticated" in r["error"]
    assert r["unread_count"] is None


def test_web_ui_has_no_service_role_path():
    src = open("app.py", encoding="utf-8").read()
    assert "SERVICE_ROLE" not in src
    assert "_service_headers" not in src


def test_weekly_mail_tool_requires_login(monkeypatch):
    from core.profiles import quality
    captured = {}

    class Mcp:
        def tool(self, fn):
            captured[fn.__name__] = fn
            return fn

    quality.register_tools(Mcp())
    monkeypatch.setattr(quality, "get_supabase", lambda: object())
    monkeypatch.setattr(ml, "get_session", lambda: None)
    r = captured["send_weekly_matches_email"]("victim")
    assert "Not authenticated" in r["error"]
