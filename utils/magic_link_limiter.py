"""
The Backroom - Rate limit for auth_request_magic_link (fix 2026-09-29, @ciso H8 S2)

Every allowed call sends an e-mail through Supabase Auth, so an unlimited tool
lets anyone flood a victim's inbox (or burn the project's mail quota).

Mechanism: in-process sliding windows (dict of deques, one lock). The existing
utils/rate_limiting.py counts per logged-in user in Supabase via an RPC keyed
by user_id; a magic-link request is anonymous by definition, so that table
does not fit and would add a DB round-trip to the one tool that must not fail
open. Trade-off: counters live in one process (reset on restart/deploy, not
shared between instances) - acceptable while Render runs a single instance.

FAIL-CLOSED: any exception while checking = deny ("try again later").
Anti-enumeration: one generic message for every kind of limit.
Logs never contain the address, only a short SHA-256 prefix.
"""

import hashlib
import os
import threading
import time
from collections import deque
from typing import Callable, Dict, Optional, Tuple

# (max requests, window seconds) - per normalised e-mail address
EMAIL_LIMITS = (
    (3, 15 * 60),       # 3 links / 15 min: enough for a typo + retry
    (10, 24 * 60 * 60),  # 10 links / 24 h: caps slow inbox flooding
)
# per client IP (true-client-ip / X-Forwarded-For, see client_ip())
IP_LIMITS = (
    (10, 15 * 60),      # 10 links / 15 min from one IP, any addresses
)
# Sweep expired keys when the table grows past this (bounds memory)
MAX_KEYS_BEFORE_SWEEP = 10_000

LIMIT_MESSAGE = "Too many login link requests. Try again later."


def _short_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:12]


def normalize_email(email: str) -> str:
    return (email or "").strip().lower()


def client_ip(headers: Dict[str, str]) -> Optional[str]:
    return client_ip_with_source(headers)[0]


def client_ip_with_source(headers: Dict[str, str]) -> Tuple[Optional[str], str]:
    """
    Client IP as seen behind Render (Cloudflare in front).

    1. true-client-ip: set by Cloudflare in front of Render, not settable by
       the client [VERIFY: community sources, no official Render doc found].
    2. first X-Forwarded-For entry: Render puts the client first but APPENDS
       to a client-sent header, so this one is spoofable; the per-e-mail limit
       still holds when it is.

    Returns (ip, source); source = "true-client-ip" / "x-forwarded-for" / "none"
    so the log shows which header Render actually delivers (closes the VERIFY).
    """
    tci = (headers.get("true-client-ip") or "").strip()
    if tci:
        return tci, "true-client-ip"
    xff = headers.get("x-forwarded-for") or ""
    first = xff.split(",")[0].strip()
    if first:
        return first, "x-forwarded-for"
    return None, "none"


class MagicLinkLimiter:
    def __init__(self, clock: Callable[[], float] = time.monotonic):
        self._clock = clock
        self._hits: Dict[str, deque] = {}
        self._lock = threading.Lock()

    def _longest_window(self, key: str) -> int:
        limits = EMAIL_LIMITS if key.startswith("email:") else IP_LIMITS
        return max(w for _, w in limits)

    def _sweep(self, now: float) -> None:
        for key in list(self._hits):
            q = self._hits[key]
            horizon = now - self._longest_window(key)
            while q and q[0] <= horizon:
                q.popleft()
            if not q:
                del self._hits[key]

    def _over(self, key: str, limits, now: float) -> Optional[Tuple[int, int]]:
        q = self._hits.get(key)
        if not q:
            return None
        horizon = now - max(w for _, w in limits)
        while q and q[0] <= horizon:
            q.popleft()
        for max_count, window in limits:
            cutoff = now - window
            if sum(1 for t in q if t > cutoff) >= max_count:
                return max_count, window
        return None

    def check_and_record(self, email: str, ip: Optional[str]) -> Tuple[bool, Optional[str]]:
        """(allowed, reason). Records the request only when allowed."""
        allowed, kind, _ = self.check_and_record_detail(email, ip)
        return allowed, kind

    def check_and_record_detail(self, email: str, ip: Optional[str]):
        """(allowed, kind, (max_count, window_s) of the limit hit or None)."""
        now = self._clock()
        keys = [("email:" + normalize_email(email), EMAIL_LIMITS)]
        if ip:
            keys.append(("ip:" + ip, IP_LIMITS))
        with self._lock:
            if len(self._hits) > MAX_KEYS_BEFORE_SWEEP:
                self._sweep(now)
            for key, limits in keys:
                hit = self._over(key, limits, now)
                if hit:
                    kind = key.split(":", 1)[0]
                    return False, kind, hit
            for key, _ in keys:
                self._hits.setdefault(key, deque()).append(now)
        return True, None, None


_limiter = MagicLinkLimiter()


def _window_label(window: int) -> str:
    return f"{window // 3600}h" if window % 3600 == 0 else f"{window // 60}m"


def check_magic_link_allowed(email: str, ip: Optional[str],
                             limiter: Optional[MagicLinkLimiter] = None,
                             ip_source: str = "n/a") -> Optional[dict]:
    """
    None = go ahead and send. A dict = the error response for the tool
    (same shape as other auth errors). Fail-closed on any exception.
    """
    try:
        allowed, kind, hit = (limiter or _limiter).check_and_record_detail(email, ip)
    except Exception as e:
        print(f"magic-link limiter error, denying: {type(e).__name__}")
        return {"success": False, "error": LIMIT_MESSAGE}
    # Log line: e-mail and IP only as SHA-256 prefixes, plus which header gave
    # the IP (true-client-ip vs x-forwarded-for) and which limit fired.
    ctx = (f"email={_short_hash(normalize_email(email))} "
           f"ip={_short_hash(ip) if ip else 'none'} ip_source={ip_source}")
    if allowed:
        if os.environ.get("MAGIC_LINK_DEBUG"):
            print(f"DEBUG magic-link allowed: {ctx}")
        return None
    limit = f"{hit[0]}/{_window_label(hit[1])}" if hit else "?"
    print(f"INFO magic-link rate limit hit: by={kind} limit={limit} {ctx}")
    return {"success": False, "error": LIMIT_MESSAGE}
