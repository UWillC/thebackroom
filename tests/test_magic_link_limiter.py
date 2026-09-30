"""
Rate limit on auth_request_magic_link (fix 2026-09-29, @ciso H8 S2).

Pins: per-e-mail and per-IP limits, reset after the window, fail-closed on a
broken store, one generic message (anti-enumeration), and that a denied
request never reaches Supabase sign_in_with_otp.
"""
from types import SimpleNamespace

import pytest

from auth import magic_link as ml
from utils import magic_link_limiter as rl


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def limiter(clock):
    return rl.MagicLinkLimiter(clock=clock)


def _allowed(limiter, email, ip):
    return rl.check_magic_link_allowed(email, ip, limiter=limiter) is None


def test_per_email_limit_15_min(limiter):
    for i in range(3):
        assert _allowed(limiter, "Victim@Example.com", f"10.0.0.{i}")
    # 4th from yet another IP, same address with different case/spaces
    denied = rl.check_magic_link_allowed("  victim@example.com ", "10.0.0.9", limiter=limiter)
    assert denied == {"success": False, "error": rl.LIMIT_MESSAGE}


def test_per_email_limit_24_h(limiter, clock):
    for _ in range(3):  # 3 bursts of 3 = 9, then 1 more = 10
        for _ in range(3):
            assert _allowed(limiter, "v@example.com", None)
        clock.t += 15 * 60 + 1
    assert _allowed(limiter, "v@example.com", None)
    clock.t += 15 * 60 + 1
    assert not _allowed(limiter, "v@example.com", None)
    clock.t += 24 * 60 * 60
    assert _allowed(limiter, "v@example.com", None)


def test_per_ip_limit(limiter):
    for i in range(10):
        assert _allowed(limiter, f"user{i}@example.com", "203.0.113.7")
    assert not _allowed(limiter, "fresh@example.com", "203.0.113.7")
    assert _allowed(limiter, "fresh@example.com", "203.0.113.8")


def test_reset_after_window(limiter, clock):
    for _ in range(3):
        assert _allowed(limiter, "a@example.com", "198.51.100.1")
    assert not _allowed(limiter, "a@example.com", "198.51.100.1")
    clock.t += 15 * 60 + 1
    assert _allowed(limiter, "a@example.com", "198.51.100.1")


def test_denied_request_is_not_counted(limiter):
    for _ in range(3):
        assert _allowed(limiter, "a@example.com", "198.51.100.2")
    for _ in range(20):  # blocked retries must not eat the IP budget
        assert not _allowed(limiter, "a@example.com", "198.51.100.2")
    for i in range(7):
        assert _allowed(limiter, f"b{i}@example.com", "198.51.100.2")
    assert not _allowed(limiter, "c@example.com", "198.51.100.2")


def test_fail_closed_on_store_error(limiter, monkeypatch, capsys):
    def boom(*_a, **_k):
        raise RuntimeError("store down")
    monkeypatch.setattr(limiter, "check_and_record_detail", boom)
    denied = rl.check_magic_link_allowed("a@example.com", "1.2.3.4", limiter=limiter)
    assert denied == {"success": False, "error": rl.LIMIT_MESSAGE}


def test_logs_do_not_contain_email(limiter, capsys):
    for _ in range(4):
        rl.check_magic_link_allowed("secret.person@example.com", None, limiter=limiter)
    out = capsys.readouterr().out
    assert "rate limit hit" in out
    assert "secret.person" not in out and "example.com" not in out


def test_client_ip_header_order():
    assert rl.client_ip({"true-client-ip": "1.1.1.1", "x-forwarded-for": "2.2.2.2"}) == "1.1.1.1"
    assert rl.client_ip({"x-forwarded-for": "3.3.3.3, 10.0.0.1"}) == "3.3.3.3"
    assert rl.client_ip({}) is None


def test_request_magic_link_blocks_before_sending(monkeypatch):
    sent = []
    fake = SimpleNamespace(auth=SimpleNamespace(sign_in_with_otp=lambda p: sent.append(p)))
    monkeypatch.setenv("MCP_TRANSPORT", "http")
    monkeypatch.setattr(ml, "_anon_client", lambda: fake)
    monkeypatch.setattr(ml, "_request_headers",
                        lambda: {"authorization": "Bearer " + "z" * 64,
                                 "x-forwarded-for": "192.0.2.50"})
    monkeypatch.setattr(ml, "check_magic_link_allowed",
                        lambda e, ip, **kw: rl.check_magic_link_allowed(e, ip, limiter=lim, **kw))
    lim = rl.MagicLinkLimiter()
    for _ in range(3):
        assert ml.request_magic_link("flood@example.com")["success"] is True
    res = ml.request_magic_link("flood@example.com")
    assert res == {"success": False, "error": rl.LIMIT_MESSAGE}
    assert len(sent) == 3


def test_request_magic_link_fails_closed(monkeypatch):
    sent = []
    fake = SimpleNamespace(auth=SimpleNamespace(sign_in_with_otp=lambda p: sent.append(p)))
    monkeypatch.setenv("MCP_TRANSPORT", "http")
    monkeypatch.setattr(ml, "_anon_client", lambda: fake)
    monkeypatch.setattr(ml, "_request_headers",
                        lambda: {"authorization": "Bearer " + "y" * 64})
    broken = rl.MagicLinkLimiter()
    broken._lock = None  # "with None" raises inside check_and_record
    monkeypatch.setattr(ml, "check_magic_link_allowed",
                        lambda e, ip, **kw: rl.check_magic_link_allowed(e, ip, limiter=broken, **kw))
    res = ml.request_magic_link("x@example.com")
    assert res["success"] is False and "Try again later" in res["error"]
    assert sent == []


def test_deny_log_line_has_limit_source_and_no_raw_pii(limiter, capsys):
    for _ in range(3):
        assert _allowed(limiter, "v@example.com", "203.0.113.7")
    rl.check_magic_link_allowed("v@example.com", "203.0.113.7", limiter=limiter,
                                ip_source="true-client-ip")
    out = capsys.readouterr().out
    assert "INFO magic-link rate limit hit: by=email limit=3/15m" in out
    assert "ip_source=true-client-ip" in out
    assert "v@example.com" not in out and "203.0.113.7" not in out


def test_allow_logs_only_with_debug_flag(limiter, capsys, monkeypatch):
    monkeypatch.delenv("MAGIC_LINK_DEBUG", raising=False)
    assert _allowed(limiter, "a@example.com", "198.51.100.1")
    assert capsys.readouterr().out == ""
    monkeypatch.setenv("MAGIC_LINK_DEBUG", "1")
    assert _allowed(limiter, "a@example.com", "198.51.100.1")
    assert "DEBUG magic-link allowed:" in capsys.readouterr().out


def test_client_ip_source():
    assert rl.client_ip_with_source({"true-client-ip": "1.2.3.4"}) == ("1.2.3.4", "true-client-ip")
    assert rl.client_ip_with_source({"x-forwarded-for": "5.6.7.8, 9.9.9.9"}) == ("5.6.7.8", "x-forwarded-for")
    assert rl.client_ip_with_source({}) == (None, "none")
