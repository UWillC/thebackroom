"""
The Backroom - Supabase Client & Helpers
"""

import os
from supabase import create_client, Client

# Supabase connection
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")

_supabase: Client = None

# Columns anon/authenticated may read (W44, sql/security_fixes/2026-10-26_w44_19_20_hardening.sql).
# email, auth_user_id and email_verification_token are revoked: `select("*")` on profiles
# fails with 42501 after that migration, so every read lists its columns.
PUBLIC_PROFILE_COLUMNS = (
    "id, name, role, industry, skills, offers, seeks, assistant_endpoint, preferences, "
    "created_at, updated_at, location, bio, tags, offer_free, offer_condition, "
    "preferred_contact, linkedin_url, quality_score, quality_feedback, quality_checked_at, "
    "email_verified, email_verification_sent_at, notifications_enabled"
)


def get_supabase() -> Client:
    """Get or create Supabase client (anon key, no auth)."""
    global _supabase
    if _supabase is None and SUPABASE_URL and SUPABASE_KEY:
        _supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
    return _supabase


def get_supabase_with_auth() -> Client:
    """Get Supabase client with user auth if available, otherwise anon.

    Checks for a valid session in ~/.config/thebackroom/session.json.
    If found, returns a client with the user's JWT (RLS-compatible).
    If not, falls back to the anon key client.
    """
    try:
        from auth.magic_link import get_authenticated_client
        auth_client = get_authenticated_client()
        if auth_client:
            return auth_client
    except (ImportError, Exception):
        pass
    return get_supabase()


def get_service_client() -> Client:
    """Service-role client of the MCP server, or None when the key is not configured."""
    try:
        from auth.magic_link import _get_service_client
        return _get_service_client()
    except Exception:
        return None


def get_profile_email(profile_id: str) -> str:
    """E-mail of a profile, read server-side (service client). Empty string when unknown.

    Only for callers that already checked a session (W44: anon/authenticated can no longer
    read profiles.email). Never return the value to a caller without that check.
    """
    client = get_service_client()
    if not client or not profile_id:
        return ""
    try:
        r = client.table("profiles").select("email").eq("id", profile_id).execute()
        return ((r.data or [{}])[0].get("email") or "") if r.data else ""
    except Exception:
        return ""


def owned_profile_email(profile_id: str) -> str:
    """E-mail of `profile_id` if the logged-in caller owns it (session e-mail matches), else ''."""
    try:
        from auth.magic_link import get_session
        session = get_session()
    except Exception:
        session = None
    if not session:
        return ""
    email = get_profile_email(profile_id)
    if email and email.lower() == (session.get("email") or "").lower():
        return email
    return ""


def load_profiles() -> list:
    """Load all profiles from Supabase."""
    client = get_supabase()
    if not client:
        return []

    try:
        response = client.table("profiles").select(PUBLIC_PROFILE_COLUMNS).execute()
        return response.data or []
    except Exception as e:
        print(f"Error loading profiles: {e}")
        return []


def format_profile_summary(profile: dict) -> dict:
    """
    Generate a 3-line profile summary for search results.
    Returns: id, name, role, location, quality_score, summary_line
    """
    name = profile.get("name", "Unknown")
    role = profile.get("role") or "Nie podano roli"
    location = profile.get("location") or "Nie podano lokalizacji"
    score = profile.get("quality_score")

    # Build score indicator
    if score is not None:
        if score >= 80:
            score_badge = f"⭐{score}%"
        elif score >= 60:
            score_badge = f"📊{score}%"
        else:
            score_badge = f"📊{score}%"
    else:
        score_badge = ""

    # 3-line summary
    summary = f"👤 {name} | 💼 {role} | 📍 {location}"
    if score_badge:
        summary += f" | {score_badge}"

    return {
        "id": profile.get("id"),
        "name": name,
        "role": role,
        "location": location,
        "quality_score": score,
        "summary": summary
    }


def log_search(query: str, results_count: int, search_type: str = "general", user_id: str = None):
    """Log search query for analytics."""
    client = get_supabase()
    if not client:
        return

    try:
        client.table("search_logs").insert({
            "query": query,
            "results_count": results_count,
            "search_type": search_type,
            "user_id": user_id
        }).execute()
    except Exception as e:
        print(f"Error logging search: {e}")


def log_profile_view(profile_id: str, viewer_id: str = None):
    """Log that someone viewed a profile."""
    client = get_supabase()
    if not client:
        return

    try:
        client.rpc("log_profile_view", {
            "p_profile_id": profile_id,
            "p_viewer_id": viewer_id
        }).execute()
    except Exception:
        pass  # Silent fail - stats are not critical


def log_search_appearances(profile_ids: list, query: str, searcher_id: str = None):
    """Log that profiles appeared in search results."""
    client = get_supabase()
    if not client or not profile_ids:
        return

    try:
        client.rpc("log_search_appearances", {
            "p_profile_ids": profile_ids,
            "p_query": query,
            "p_searcher_id": searcher_id
        }).execute()
    except Exception:
        pass  # Silent fail
