"""
The Backroom - Supabase Client & Helpers
"""

import os
from supabase import create_client, Client

# Supabase connection
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")

_supabase: Client = None


def get_supabase() -> Client:
    """Get or create Supabase client."""
    global _supabase
    if _supabase is None and SUPABASE_URL and SUPABASE_KEY:
        _supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
    return _supabase


def load_profiles() -> list:
    """Load all profiles from Supabase."""
    client = get_supabase()
    if not client:
        return []

    try:
        response = client.table("profiles").select("*").execute()
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
