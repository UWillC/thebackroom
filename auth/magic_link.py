"""
The Backroom - Authentication Module
Magic Link auth using Supabase Auth

Session stored in ~/.config/thebackroom/session.json

Usage:
    from auth import get_authenticated_client, request_magic_link, auth_status
"""

import os
import json
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional
from supabase import create_client, Client

# Session file location (like AIBL Network)
CONFIG_DIR = Path.home() / ".config" / "thebackroom"
SESSION_FILE = CONFIG_DIR / "session.json"

# BUG-002 fix: sessions also mirrored to Supabase (service-role only table)
# so they survive Render redeploys; expired sessions are auto-refreshed via
# refresh_token instead of being deleted.
SESSION_TABLE = "mcp_sessions"
REFRESH_BUFFER_SECONDS = 120


def _ensure_config_dir():
    """Create config directory if it doesn't exist."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def _get_service_client() -> Optional[Client]:
    """Service-role client for the session mirror table (bypasses RLS)."""
    supabase_url = os.environ.get("SUPABASE_URL", "")
    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not supabase_url or not service_role_key:
        return None
    try:
        return create_client(supabase_url, service_role_key)
    except Exception:
        return None


def _db_save_session(session: dict):
    """Best-effort mirror to DB. Failure is non-fatal (file still works)."""
    client = _get_service_client()
    if not client or not session.get("email"):
        return
    try:
        client.table(SESSION_TABLE).upsert({
            "email": session["email"],
            "session": session,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }).execute()
    except Exception as e:
        print(f"Session DB mirror save failed (non-fatal): {e}")


def _db_load_session() -> Optional[dict]:
    """Restore most recent session from DB (after redeploy wiped the disk)."""
    client = _get_service_client()
    if not client:
        return None
    try:
        result = client.table(SESSION_TABLE).select("session").order(
            "updated_at", desc=True
        ).limit(1).execute()
        if result.data:
            return result.data[0]["session"]
    except Exception as e:
        print(f"Session DB restore failed (non-fatal): {e}")
    return None


def _db_clear_sessions():
    """Best-effort wipe of the DB mirror (logout)."""
    client = _get_service_client()
    if not client:
        return
    try:
        client.table(SESSION_TABLE).delete().neq("email", "").execute()
    except Exception as e:
        print(f"Session DB clear failed (non-fatal): {e}")


def _load_session() -> Optional[dict]:
    """Load session from file; fall back to DB mirror after a redeploy."""
    if SESSION_FILE.exists():
        try:
            with open(SESSION_FILE, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    # Disk is ephemeral on Render — after a deploy the file is gone,
    # but the DB mirror survives. Restore and re-cache to file.
    session = _db_load_session()
    if session:
        _save_session_file_only(session)
    return session


def _save_session_file_only(session: dict):
    """Write session to local file cache."""
    _ensure_config_dir()
    with open(SESSION_FILE, "w") as f:
        json.dump(session, f, indent=2)


def _save_session(session: dict):
    """Save session to file + DB mirror."""
    _save_session_file_only(session)
    _db_save_session(session)


def _clear_session():
    """Remove session file + DB mirror."""
    if SESSION_FILE.exists():
        SESSION_FILE.unlink()
    _db_clear_sessions()


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


def _try_refresh(session: dict) -> Optional[dict]:
    """Refresh an expiring session using its refresh token."""
    refresh_token = session.get("refresh_token")
    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = os.environ.get("SUPABASE_KEY", "")
    if not refresh_token or not supabase_url or not supabase_key:
        return None
    try:
        client = create_client(supabase_url, supabase_key)
        response = client.auth.refresh_session(refresh_token)
        if response and response.session:
            session_data = {
                "access_token": response.session.access_token,
                "refresh_token": response.session.refresh_token,
                "user_id": response.user.id if response.user else session.get("user_id"),
                "email": response.user.email if response.user else session.get("email"),
                "expires_at": response.session.expires_at,
                "authenticated_at": session.get("authenticated_at"),
                "refreshed_at": datetime.now(timezone.utc).isoformat(),
            }
            _save_session(session_data)
            return session_data
    except Exception as e:
        print(f"Session auto-refresh failed: {e}")
    return None


def get_session() -> Optional[dict]:
    """
    Get current session if valid.

    An expired (or nearly expired) access token is auto-refreshed via the
    refresh token. The session is cleared only when refresh fails too.
    """
    session = _load_session()
    if not session:
        return None

    exp = _session_expires_ts(session)
    if exp is not None and datetime.now(timezone.utc).timestamp() > exp - REFRESH_BUFFER_SECONDS:
        refreshed = _try_refresh(session)
        if refreshed:
            return refreshed
        _clear_session()
        return None

    return session


def get_authenticated_client() -> Optional[Client]:
    """
    Get Supabase client with user authentication.
    Returns None if not authenticated.
    """
    session = get_session()
    if not session:
        return None

    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = os.environ.get("SUPABASE_KEY", "")

    if not supabase_url or not supabase_key:
        return None

    try:
        client = create_client(supabase_url, supabase_key)
        # Set session on client
        client.auth.set_session(
            access_token=session.get("access_token"),
            refresh_token=session.get("refresh_token")
        )
        return client
    except Exception as e:
        print(f"Error creating authenticated client: {e}")
        return None


def request_magic_link(email: str) -> dict:
    """
    Request magic link to be sent to email.

    Args:
        email: User's email address

    Returns:
        dict with status and message
    """
    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = os.environ.get("SUPABASE_KEY", "")

    if not supabase_url or not supabase_key:
        return {
            "success": False,
            "error": "SUPABASE_URL and SUPABASE_KEY not configured"
        }

    try:
        client = create_client(supabase_url, supabase_key)

        # Request magic link (OTP via email)
        response = client.auth.sign_in_with_otp({
            "email": email,
            "options": {
                "should_create_user": True  # Auto-create user if doesn't exist
            }
        })

        return {
            "success": True,
            "message": f"Magic link sent to {email}",
            "next_step": "Check your email, click the link, and return here. Say 'I clicked the link' and I'll verify your authentication.",
            "note": "No need to copy anything - just click and come back!"
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Failed to send magic link: {e}"
        }


def auth_callback(access_token: str, refresh_token: str) -> dict:
    """
    Complete authentication after clicking magic link.

    After user clicks magic link, they get redirected with tokens.
    Extract access_token and refresh_token from URL and call this.

    Args:
        access_token: The access token from redirect URL
        refresh_token: The refresh token from redirect URL

    Returns:
        dict with session info
    """
    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = os.environ.get("SUPABASE_KEY", "")

    if not supabase_url or not supabase_key:
        return {
            "success": False,
            "error": "SUPABASE_URL and SUPABASE_KEY not configured"
        }

    try:
        client = create_client(supabase_url, supabase_key)

        # Set the session
        response = client.auth.set_session(access_token, refresh_token)

        if response and response.user:
            # Save session locally
            session_data = {
                "access_token": access_token,
                "refresh_token": refresh_token,
                "user_id": response.user.id,
                "email": response.user.email,
                "expires_at": response.session.expires_at if response.session else None,
                "authenticated_at": datetime.now().isoformat()
            }
            _save_session(session_data)

            return {
                "success": True,
                "message": "Authentication successful!",
                "user": {
                    "id": response.user.id,
                    "email": response.user.email
                },
                "session_file": str(SESSION_FILE)
            }
        else:
            return {
                "success": False,
                "error": "Invalid tokens"
            }

    except Exception as e:
        return {
            "success": False,
            "error": f"Authentication failed: {e}"
        }


def verify_auth_by_email(email: str) -> dict:
    """
    Verify if a user is authenticated and create a server-side session.

    After user clicks magic link, this:
    1. Checks if profile has auth_user_id (magic link was clicked)
    2. Uses admin API to generate tokens server-side
    3. Saves session to session.json for RLS-protected operations

    Args:
        email: User's email address

    Returns:
        dict with authentication status
    """
    supabase_url = os.environ.get("SUPABASE_URL", "")
    supabase_key = os.environ.get("SUPABASE_KEY", "")
    service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")

    if not supabase_url or not supabase_key:
        return {
            "authenticated": False,
            "error": "Database not configured"
        }

    try:
        client = create_client(supabase_url, supabase_key)

        # Check if profile exists and has auth_user_id
        result = client.table("profiles").select(
            "id, name, email, auth_user_id"
        ).eq("email", email).execute()

        if not result.data:
            return {
                "authenticated": False,
                "error": "No profile found with this email. Register first with register_profile()."
            }

        profile = result.data[0]

        if not profile.get("auth_user_id"):
            return {
                "authenticated": False,
                "message": "Profile exists but not yet authenticated. Click the magic link in your email.",
                "profile_id": profile.get("id")
            }

        # Profile is linked to auth — now generate a server-side session
        if not service_role_key:
            # Fallback: return authenticated but warn about missing session
            return {
                "authenticated": True,
                "message": "You are authenticated! (Note: SUPABASE_SERVICE_ROLE_KEY not set — RLS operations may fail)",
                "profile_id": profile.get("id"),
                "name": profile.get("name"),
                "email": profile.get("email"),
                "session_created": False
            }

        # Use admin API to generate magic link and exchange for session
        admin_client = create_client(supabase_url, service_role_key)

        # Generate a server-side magic link (not sent to user)
        link_response = admin_client.auth.admin.generate_link({
            "type": "magiclink",
            "email": email
        })

        if link_response and hasattr(link_response, 'properties') and link_response.properties:
            token_hash = link_response.properties.hashed_token

            # Verify the OTP to get access/refresh tokens
            session_response = client.auth.verify_otp({
                "token_hash": token_hash,
                "type": "magiclink"
            })

            if session_response and session_response.session:
                # Save session locally
                session_data = {
                    "access_token": session_response.session.access_token,
                    "refresh_token": session_response.session.refresh_token,
                    "user_id": session_response.user.id,
                    "email": session_response.user.email,
                    "expires_at": session_response.session.expires_at,
                    "authenticated_at": datetime.now().isoformat()
                }
                _save_session(session_data)

                return {
                    "authenticated": True,
                    "message": "You are authenticated!",
                    "profile_id": profile.get("id"),
                    "name": profile.get("name"),
                    "email": profile.get("email"),
                    "session_created": True
                }

        # Fallback if admin token generation failed
        return {
            "authenticated": True,
            "message": "You are authenticated! (Session generation failed — try auth_request_magic_link again)",
            "profile_id": profile.get("id"),
            "name": profile.get("name"),
            "email": profile.get("email"),
            "session_created": False
        }

    except Exception as e:
        return {
            "authenticated": False,
            "error": f"Verification failed: {e}"
        }


def auth_status() -> dict:
    """
    Check current authentication status.

    Returns:
        dict with authentication info
    """
    session = get_session()

    if not session:
        return {
            "authenticated": False,
            "message": "Not authenticated. Use auth_request_magic_link(email) to start.",
            "session_file": str(SESSION_FILE)
        }

    return {
        "authenticated": True,
        "user_id": session.get("user_id"),
        "email": session.get("email"),
        "authenticated_at": session.get("authenticated_at"),
        "expires_at": session.get("expires_at"),
        "session_file": str(SESSION_FILE)
    }


def auth_logout() -> dict:
    """
    Log out and clear session.

    Returns:
        dict with status
    """
    session = get_session()

    if session:
        # Try to sign out from Supabase
        try:
            client = get_authenticated_client()
            if client:
                client.auth.sign_out()
        except Exception:
            pass  # Continue with local logout even if remote fails

    _clear_session()

    return {
        "success": True,
        "message": "Logged out successfully",
        "session_file": str(SESSION_FILE)
    }


def refresh_session() -> dict:
    """
    Refresh the current session using refresh token.

    Returns:
        dict with new session info
    """
    session = _load_session()

    if not session:
        return {
            "success": False,
            "error": "No session to refresh"
        }

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
