"""
Auth errors do not echo exception text (@ciso Render review 17.11, LOW).

Pins: request_magic_link returns and logs only the exception class name,
and _try_refresh logs only the class name, never the message.
"""
from types import SimpleNamespace

from auth import magic_link as ml

SECRET = "SECRET-DETAIL https://abc.supabase.co key=sb_xyz"


def _boom(*_a, **_k):
    raise RuntimeError(SECRET)


def test_request_magic_link_error_has_no_exception_text(monkeypatch, capsys):
    fake = SimpleNamespace(auth=SimpleNamespace(sign_in_with_otp=_boom))
    monkeypatch.delenv("MCP_TRANSPORT", raising=False)
    monkeypatch.setattr(ml, "_anon_client", lambda: fake)
    monkeypatch.setattr(ml, "check_magic_link_allowed", lambda *a, **k: None)
    res = ml.request_magic_link("user@example.com")
    out = capsys.readouterr().out
    assert res["success"] is False
    assert "RuntimeError" in res["error"]
    assert SECRET not in res["error"] and "SECRET" not in res["error"]
    assert "SECRET" not in out and "RuntimeError" in out


def test_refresh_failure_log_has_no_exception_text(monkeypatch, capsys):
    fake = SimpleNamespace(auth=SimpleNamespace(refresh_session=_boom))
    monkeypatch.setattr(ml, "_anon_client", lambda: fake)
    assert ml._try_refresh({"refresh_token": "r" * 40}) is None
    out = capsys.readouterr().out
    assert "auto-refresh failed: RuntimeError" in out
    assert "SECRET" not in out
