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
    """
    Client IP as seen behind Render (Cloudflare in front).

    1. true-client-ip: set by Cloudflare in front of Render, not settable by
       the client [VERIFY: community sources, no official Render doc found].
    2. first X-Forwarded-For entry: Render puts the client first but APPENDS
       to a client-sent header, so this one is spoofable; the per-e-mail limit
       still holds when it is.
    """
    tci = (headers.get("true-client-ip") or "").strip()
    if tci:
        return tci
    xff = headers.get("x-forwarded-for") or ""
    first = xff.split(",")[0].strip()
    return first or None


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

    def _over(self, key: str, limits, now: float) -> bool:
        q = self._hits.get(key)
        if not q:
            return False
        horizon = now - max(w for _, w in limits)
        while q and q[0] <= horizon:
            q.popleft()
        for max_count, window in limits:
            cutoff = now - window
            if sum(1 for t in q if t > cutoff) >= max_count:
                return True
        return False

    def check_and_record(self, email: str, ip: Optional[str]) -> Tuple[bool, Optional[str]]:
        """(allowed, reason). Records the request only when allowed."""
        now = self._clock()
        keys = [("email:" + normalize_email(email), EMAIL_LIMITS)]
        if ip:
            keys.append(("ip:" + ip, IP_LIMITS))
        with self._lock:
            if len(self._hits) > MAX_KEYS_BEFORE_SWEEP:
                self._sweep(now)
            for key, limits in keys:
                if self._over(key, limits, now):
                    kind = key.split(":", 1)[0]
                    return False, kind
            for key, _ in keys:
                self._hits.setdefault(key, deque()).append(now)
        return True, None


_limiter = MagicLinkLimiter()


def check_magic_link_allowed(email: str, ip: Optional[str],
                             limiter: Optional[MagicLinkLimiter] = None) -> Optional[dict]:
    """
    None = go ahead and send. A dict = the error response for the tool
    (same shape as other auth errors). Fail-closed on any exception.
    """
    try:
        allowed, kind = (limiter or _limiter).check_and_record(email, ip)
    except Exception as e:
        print(f"magic-link limiter error, denying: {type(e).__name__}")
        return {"success": False, "error": LIMIT_MESSAGE}
    if allowed:
        return None
    who = _short_hash(normalize_email(email)) if kind == "email" else _short_hash(ip or "")
    print(f"magic-link rate limit hit: {kind}={who}")
    return {"success": False, "error": LIMIT_MESSAGE}
