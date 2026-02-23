"""
The Backroom - Rate Limiting
"""

from .supabase import get_supabase

# Limits
RATE_LIMITS = {
    "connection_request": {"max": 10, "window_hours": 24},
    "post": {"max": 5, "window_hours": 24},
    "search": {"max": 50, "window_hours": 1}
}


def check_rate_limit(user_id: str, action_type: str) -> dict:
    """
    Check and log rate limit for an action.

    Returns:
        {"allowed": True/False, "current": N, "max": M, "remaining": R}
    """
    client = get_supabase()
    if not client:
        return {"allowed": True, "error": "DB not connected, rate limit skipped"}

    limits = RATE_LIMITS.get(action_type)
    if not limits:
        return {"allowed": True, "error": f"Unknown action type: {action_type}"}

    try:
        response = client.rpc("check_and_log_rate_limit", {
            "p_user_id": user_id,
            "p_action_type": action_type,
            "p_max_count": limits["max"],
            "p_window_hours": limits["window_hours"]
        }).execute()

        if response.data:
            result = response.data
            return {
                "allowed": result.get("allowed", True),
                "current": result.get("current_count", 0),
                "max": result.get("max_count", limits["max"]),
                "remaining": result.get("remaining", limits["max"]),
                "window_hours": result.get("window_hours", limits["window_hours"])
            }
        else:
            return {"allowed": True, "error": "No response from rate limit check"}

    except Exception as e:
        print(f"Rate limit check error: {e}")
        return {"allowed": True, "error": str(e)}


def get_rate_limit_status(user_id: str) -> dict:
    """Get current rate limit status for all actions."""
    client = get_supabase()
    if not client:
        return {"error": "Database not connected"}

    try:
        response = client.rpc("get_user_rate_limit_status", {
            "p_user_id": user_id
        }).execute()

        return response.data if response.data else {"error": "No data returned"}
    except Exception as e:
        return {"error": str(e)}
