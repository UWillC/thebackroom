"""
The Backroom - Authentication Module
Magic Link auth using Supabase Auth

Sessions are PER CLIENT (security fix 2026-09-21):

- Remote transports (http / sse): the server is public and shared, so a
  session belongs to exactly one MCP client. The client is identified by a
  secret only it holds: the `Authorization: Bearer <secret>` header from its
  MCP config (persistent across reconnects), or, without one, its
  `Mcp-Session-Id` (lives as long as the connection). Only a SHA-256 of that
  secret is stored, next to the Supabase session, in the service-role-only
  table `mcp_client_sessions`. A request without such a secret is anonymous.
- stdio transport (local, single user): session file in
  ~/.config/thebackroom/session.json, as before.

Logging in always needs proof of mailbox possession: the one-time token from
the emailed magic link (auth_complete_link) or the tokens from the redirect
URL (auth_callback). Knowing an email address is never enough.

Usage:
    from auth import get_authenticated_client, request_magic_link, auth_status
"""

import os
import json
import hashlib
import threading
from pathlib import Path
from datetime import datetime, timezone, timedelta
from typing import Optional, Tuple
from urllib.parse import urlparse, parse_qs
from supabase import create_client, Client
from supabase.lib.client_options import SyncClientOptions

# Local (stdio) session file
CONFIG_DIR = Path.home() / ".config" / "thebackroom"
SESSION_FILE = CONFIG_DIR / "session.json"

# Remote (http / sse) per-client sessions: service-role only table
CLIENT_SESSION_TABLE = "mcp_client_sessions"
REFRESH_BUFFER_SECONDS = 120
MIN_CLIENT_SECRET_LENGTH = 32
SID_SESSION_MAX_AGE_HOURS = 24

# One refresh at a time per client: Supabase rotates refresh tokens, a second
# parallel refresh with the same token fails with "Already Used".
_refresh_locks: dict = {}
_refresh_locks_guard = threading.Lock()


# ============== CLIENT IDENTITY ==============

def _is_remote() -> bool:
    """True when the server runs on a shared network transport."""
    return os.environ.get("MCP_TRANSPORT", "").lower() in ("http", "sse")


def _request_headers() -> dict:
    """Headers of the current MCP HTTP request ({} outside a request)."""
    try:
        from fastmcp.server.dependencies import get_http_headers
        return {k.lower(): v for k, v in get_http_headers(include_all=True).items()}
    except Exception:
        return {}


def _client_key() -> Tuple[Optional[str], Optional[str]]:
    """
    Identify the calling client by a secret only it holds.

    Returns (key_hash, kind): kind is "bearer" or "sid". (None, None) means
    the caller is anonymous.
    """
    headers = _request_headers()
    authorization = headers.get("authorization", "")
    if authorization.lower().startswith("bearer "):
        secret = authorization[7:].strip()
        if len(secret) >= MIN_CLIENT_SECRET_LENGTH:
            digest = hashlib.sha256(("bearer:" + secret).encode()).hexdigest()
            return digest, "bearer"
    session_id = headers.get("mcp-session-id", "").strip()
    if len(session_id) >= 16:
        digest = hashlib.sha256(("sid:" + session_id).encode()).hexdigest()
        return digest, "sid"
    return None, None


def _lock_for(key: str) -> threading.Lock:
    with _refresh_locks_guard:
        if key not in _refresh_locks:
            _refresh_locks[key] = threading.Lock()
        return _refresh_locks[key]


# ============== STORAGE ==============

def _ensure_config_dir():
    """Create config directory if it doesn't exist."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def _get_service_client() -> Optional[Client]:
    """Service-role client for the session table (bypasses RLS)."""
    supabase_url = os.environ.get("SUPABASE_URL", "")
    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not supabase_url or not service_role_key:
        return None
    try:
        return create_client(supabase_url, service_role_key)
    except Exception:
        return None


def _anon_client() -> Optional[Client]:
    """Fresh anon client for auth calls. Implicit flow: the emailed token can
    be verified server-side; no auto-refresh thread, no shared state."""
    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = os.environ.get("SUPABASE_KEY", "")
    if not supabase_url or not supabase_key:
        return None
    return create_client(
        supabase_url,
        supabase_key,
        options=SyncClientOptions(
            flow_type="implicit",
            auto_refresh_token=False,
            persist_session=False,
        ),
    )


def _load_session() -> Optional[dict]:
    """Session of the calling client, or None."""
    if not _is_remote():
        if SESSION_FILE.exists():
            try:
                with open(SESSION_FILE, "r") as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                return None
        return None

    key, _kind = _client_key()
    if not key:
        return None
    client = _get_service_client()
    if not client:
        return None
    try:
        result = client.table(CLIENT_SESSION_TABLE).select("session").eq(
            "client_key_hash", key
        ).limit(1).execute()
        if result.data:
            return result.data[0]["session"]
    except Exception as e:
        print(f"Client session load failed: {type(e).__name__}")
    return None


def _save_session(session: dict) -> bool:
    """Store the session for the calling client only. False = not stored."""
    if not _is_remote():
        _ensure_config_dir()
        with open(SESSION_FILE, "w") as f:
            json.dump(session, f, indent=2)
        os.chmod(SESSION_FILE, 0o600)
        return True

    key, kind = _client_key()
    client = _get_service_client()
    if not key or not client:
        return False
    try:
        now = datetime.now(timezone.utc).isoformat()
        client.table(CLIENT_SESSION_TABLE).upsert({
            "client_key_hash": key,
            "kind": kind,
            "email": session.get("email"),
            "user_id": session.get("user_id"),
            "session": session,
            "updated_at": now,
        }).execute()
        return True
    except Exception as e:
        print(f"Client session save failed: {type(e).__name__}")
        return False


def _clear_session():
    """Remove the calling client's session. Never touches other clients."""
    if not _is_remote():
        if SESSION_FILE.exists():
            SESSION_FILE.unlink()
        return
    key, _kind = _client_key()
    client = _get_service_client()
    if not key or not client:
        return
    try:
        client.table(CLIENT_SESSION_TABLE).delete().eq(
            "client_key_hash", key
        ).execute()
    except Exception as e:
        print(f"Client session clear failed: {type(e).__name__}")


def _purge_stale_sid_sessions():
    """Connection-bound sessions die with the connection; sweep leftovers."""
    client = _get_service_client()
    if not client:
        return
    try:
        cutoff = (
            datetime.now(timezone.utc) - timedelta(hours=SID_SESSION_MAX_AGE_HOURS)
        ).isoformat()
        client.table(CLIENT_SESSION_TABLE).delete().eq("kind", "sid").lt(
            "updated_at", cutoff
        ).execute()
    except Exception:
        pass


# ============== SESSION LIFECYCLE ==============

def _session_expires_ts(session: dict) -> Optional[float]:
    """Expiry as unix timestamp, or None if absent/unparseable."""
    expires_at = session.get("expires_at")
    if expires_at is None:
        return None
    try:
        if isinstance(expires_at, (int, float)):
            return float(expires_at)
        if isinstance(expires_at, str):
            return datetime.fromisoformat(
                expires_at.replace("Z", "+00:00")
            ).timestamp()
    except (ValueError, TypeError):
        return None
    return None


def _needs_refresh(session: dict) -> bool:
    exp = _session_expires_ts(session)
    return exp is not None and (
        datetime.now(timezone.utc).timestamp() > exp - REFRESH_BUFFER_SECONDS
    )


def _session_from_response(response, previous: Optional[dict] = None) -> Optional[dict]:
    if not response or not getattr(response, "session", None):
        return None
    previous = previous or {}
    user = getattr(response, "user", None)
    return {
        "access_token": response.session.access_token,
        "refresh_token": response.session.refresh_token,
        "user_id": user.id if user else previous.get("user_id"),
        "email": user.email if user else previous.get("email"),
        "expires_at": response.session.expires_at,
        "authenticated_at": previous.get("authenticated_at")
        or datetime.now(timezone.utc).isoformat(),
    }


def _try_refresh(session: dict) -> Optional[dict]:
    """Refresh an expiring session using its refresh token."""
    refresh_token = session.get("refresh_token")
    client = _anon_client()
    if not refresh_token or not client:
        return None
    try:
        response = client.auth.refresh_session(refresh_token)
        session_data = _session_from_response(response, previous=session)
        if session_data:
            session_data["refreshed_at"] = datetime.now(timezone.utc).isoformat()
            _save_session(session_data)
            return session_data
    except Exception as e:
        print(f"Session auto-refresh failed: {e}")
    return None


def get_session() -> Optional[dict]:
    """
    Session of the calling client if valid, else None.

    An expired (or nearly expired) access token is refreshed via the refresh
    token, one refresh at a time per client. The session is cleared only when
    the refresh fails too.
    """
    session = _load_session()
    if not session:
        return None
    if not _needs_refresh(session):
        return session

    key, _kind = _client_key()
    with _lock_for(key or "local"):
        # Another request of the same client may have refreshed meanwhile.
        session = _load_session()
        if not session:
            return None
        if not _needs_refresh(session):
            return session
        refreshed = _try_refresh(session)
        if refreshed:
            return refreshed
        _clear_session()
        return None


def get_authenticated_client() -> Optional[Client]:
    """
    Supabase client acting as the calling client's user (RLS applies).
    Returns None if the caller is not authenticated.

    The user's JWT goes on the data API only. The auth state of the client is
    left alone on purpose: set_session() may rotate the refresh token behind
    our back, and the next refresh then fails with "Already Used".
    """
    session = get_session()
    if not session or not session.get("access_token"):
        return None
    client = _anon_client()
    if not client:
        return None
    try:
        client.postgrest.auth(session["access_token"])
        return client
    except Exception as e:
        print(f"Error creating authenticated client: {type(e).__name__}")
        return None


# ============== LOGIN ==============

def _login_instructions() -> str:
    return (
        "Check your email. Do NOT click the link: copy the link address from "
        "the email and give it to your assistant, which calls "
        "auth_complete_link(link). The link carries a one-time token that "
        "proves the mailbox is yours. If you already clicked it, request a "
        "new link."
    )


def request_magic_link(email: str) -> dict:
    """
    Request magic link to be sent to email.

    Args:
        email: User's email address

    Returns:
        dict with status and message
    """
    client = _anon_client()
    if not client:
        return {
            "success": False,
            "error": "SUPABASE_URL and SUPABASE_KEY not configured"
        }
    if _is_remote() and not _client_key()[0]:
        return {
            "success": False,
            "error": "This client cannot hold a session. Add an Authorization: "
                     "Bearer <your own random secret, 32+ chars> header to the "
                     "MCP server config and reconnect."
        }

    try:
        client.auth.sign_in_with_otp({
            "email": email,
            "options": {
                "should_create_user": True  # Auto-create user if doesn't exist
            }
        })
        return {
            "success": True,
            "message": f"Magic link sent to {email}",
            "next_step": _login_instructions(),
        }
    except Exception as e:
        return {
            "success": False,
            "error": f"Failed to send magic link: {e}"
        }


def _finish_login(session_data: Optional[dict]) -> dict:
    if not session_data:
        return {"success": False, "error": "Invalid or already used token"}
    if not _save_session(session_data):
        return {
            "success": False,
            "error": "Verified, but this client cannot hold a session. Add an "
                     "Authorization: Bearer <secret> header to the MCP server "
                     "config, reconnect and request a new link."
        }
    if _is_remote():
        _purge_stale_sid_sessions()
    _key, kind = _client_key()
    result = {
        "success": True,
        "authenticated": True,
        "message": "Authentication successful!",
        "user": {
            "id": session_data.get("user_id"),
            "email": session_data.get("email"),
        },
    }
    if _is_remote() and kind == "sid":
        result["note"] = (
            "This session lives only as long as the current connection. For a "
            "session that survives reconnects, add an Authorization: Bearer "
            "<your own random secret, 32+ chars> header to the MCP server "
            "config and log in once more."
        )
    return result


def auth_complete_link(link: str) -> dict:
    """
    Complete authentication with the magic link from the email (not clicked).

    Args:
        link: The full link address copied from the email, or its token.

    Returns:
        dict with session info
    """
    client = _anon_client()
    if not client:
        return {
            "success": False,
            "error": "SUPABASE_URL and SUPABASE_KEY not configured"
        }

    link = (link or "").strip()
    token_hash = link
    otp_type = "magiclink"
    if "://" in link:
        try:
            query = parse_qs(urlparse(link).query)
        except ValueError:
            return {"success": False, "error": "Could not read the link"}
        token_hash = (query.get("token") or query.get("token_hash") or [""])[0]
        otp_type = (query.get("type") or ["magiclink"])[0]
    if otp_type not in ("magiclink", "signup", "email"):
        otp_type = "magiclink"
    if not token_hash or len(token_hash) < 20 or len(token_hash) > 512:
        return {
            "success": False,
            "error": "No login token found. Copy the full link address from "
                     "the email (right click, copy link)."
        }

    try:
        response = client.auth.verify_otp({
            "token_hash": token_hash,
            "type": otp_type,
        })
    except Exception:
        return {
            "success": False,
            "error": "Link invalid, expired or already used. Request a new "
                     "one and do not click it before copying."
        }
    return _finish_login(_session_from_response(response))


def auth_callback(access_token: str, refresh_token: str) -> dict:
    """
    Complete authentication with the tokens from the redirect URL.

    Args:
        access_token: The access token from redirect URL
        refresh_token: The refresh token from redirect URL

    Returns:
        dict with session info
    """
    client = _anon_client()
    if not client:
        return {
            "success": False,
            "error": "SUPABASE_URL and SUPABASE_KEY not configured"
        }

    try:
        response = client.auth.set_session(access_token, refresh_token)
    except Exception:
        return {"success": False, "error": "Authentication failed: invalid tokens"}
    # set_session may have rotated the tokens: store what the server returned.
    return _finish_login(_session_from_response(response))


def verify_auth_by_email(email: str) -> dict:
    """
    Report whether the CALLING client is logged in as this email.

    Never creates a session. (Until 2026-09-21 this minted a full session for
    any registered address with the service-role key: account takeover by
    knowing an email.)

    Args:
        email: User's email address

    Returns:
        dict with authentication status
    """
    session = get_session()
    if session and (session.get("email") or "").lower() == (email or "").strip().lower():
        return {
            "authenticated": True,
            "message": "You are authenticated!",
            "email": session.get("email"),
            "session_created": True,
        }
    return {
        "authenticated": False,
        "session_created": False,
        "message": "Not authenticated on this client. Call "
                   "auth_request_magic_link(email), then "
                   "auth_complete_link(link). " + _login_instructions(),
    }


def auth_status() -> dict:
    """
    Check current authentication status.

    Returns:
        dict with authentication info
    """
    session = get_session()
    _key, kind = _client_key()
    if not session:
        return {
            "authenticated": False,
            "message": "Not authenticated. Use auth_request_magic_link(email) to start.",
            "client_identity": kind or ("local" if not _is_remote() else "none"),
        }

    return {
        "authenticated": True,
        "user_id": session.get("user_id"),
        "email": session.get("email"),
        "authenticated_at": session.get("authenticated_at"),
        "expires_at": session.get("expires_at"),
        "client_identity": kind or "local",
    }


def auth_logout() -> dict:
    """
    Log out the calling client and clear its session.

    Returns:
        dict with status
    """
    _clear_session()
    return {
        "success": True,
        "message": "Logged out successfully"
    }


def refresh_session() -> dict:
    """
    Refresh the calling client's session using its refresh token.

    Returns:
        dict with new session info
    """
    session = _load_session()
    if not session:
        return {
            "success": False,
            "error": "No session to refresh"
        }

    key, _kind = _client_key()
    with _lock_for(key or "local"):
        session = _load_session() or session
        refreshed = _try_refresh(session)
    if refreshed:
        return {
            "success": True,
            "message": "Session refreshed",
            "expires_at": refreshed.get("expires_at")
        }

    return {
        "success": False,
        "error": "Failed to refresh session"
    }
