#!/usr/bin/env python3
"""
The Backroom - MCP Server
"Where AI assistants connect their humans"

Usage:
    pip install fastmcp supabase
    python server.py

Environment variables:
    SUPABASE_URL - Supabase project URL
    SUPABASE_KEY - Supabase anon/public key

For Claude Desktop/Code, add to config:
    {
        "mcpServers": {
            "thebackroom": {
                "command": "python3.11",
                "args": ["/path/to/server.py"],
                "env": {
                    "SUPABASE_URL": "https://xxx.supabase.co",
                    "SUPABASE_KEY": "your-key"
                }
            }
        }
    }
"""

from fastmcp import FastMCP
import os
from supabase import create_client, Client

# Initialize MCP server
mcp = FastMCP("The Backroom")

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


@mcp.tool
def list_profiles() -> dict:
    """List all profiles in The Backroom network."""
    if not get_supabase():
        return {"error": "Database not connected. Set SUPABASE_URL and SUPABASE_KEY."}

    profiles = load_profiles()
    return {
        "count": len(profiles),
        "profiles": [
            {
                "id": p.get("id"),
                "name": p.get("name"),
                "role": p.get("role"),
                "industry": p.get("industry") or []
            }
            for p in profiles
        ]
    }


@mcp.tool
def get_profile(profile_id: str) -> dict:
    """Get detailed profile by ID."""
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        response = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
        if response.data:
            return {"found": True, "profile": response.data[0]}
        return {"found": False, "error": f"Profile '{profile_id}' not found"}
    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def find_collaborators(query: str, max_results: int = 5) -> dict:
    """
    Search for collaborators matching the query.

    Examples:
    - "looking for someone who knows Python"
    - "need marketing advice"
    - "seeking co-founder with tech skills"
    """
    if not get_supabase():
        return {"error": "Database not connected. Set SUPABASE_URL and SUPABASE_KEY."}

    profiles = load_profiles()
    query_lower = query.lower()

    matches = []

    for profile in profiles:
        score = 0
        reasons = []

        # Check offers
        for offer in profile.get("offers") or []:
            if query_lower in offer.lower():
                score += 3
                reasons.append(f"Offers: {offer}")

        # Check seeks (reciprocal matching)
        for seek in profile.get("seeks") or []:
            if query_lower in seek.lower():
                score += 2
                reasons.append(f"Seeks: {seek}")

        # Check skills
        for skill in profile.get("skills") or []:
            if query_lower in skill.lower():
                score += 2
                reasons.append(f"Skill: {skill}")

        # Check industry
        for industry in profile.get("industry") or []:
            if query_lower in industry.lower():
                score += 1
                reasons.append(f"Industry: {industry}")

        # Check role
        if query_lower in (profile.get("role") or "").lower():
            score += 1
            reasons.append("Role match")

        if score > 0:
            matches.append({
                "id": profile.get("id"),
                "name": profile.get("name"),
                "role": profile.get("role"),
                "score": score,
                "reasons": reasons,
                "assistant_endpoint": profile.get("assistant_endpoint")
            })

    # Sort by score descending
    matches.sort(key=lambda x: x["score"], reverse=True)

    return {
        "query": query,
        "matches_found": len(matches),
        "results": matches[:max_results]
    }


@mcp.tool
def search_by_category(category: str, value: str) -> dict:
    """
    Search profiles by specific category.

    Categories: industry, skills, seeking, offering

    Examples:
    - category="industry", value="e-commerce"
    - category="skills", value="python"
    - category="seeking", value="co-founder"
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    profiles = load_profiles()
    value_lower = value.lower()
    matches = []

    for profile in profiles:
        matched = False

        if category == "industry":
            if any(value_lower in i.lower() for i in profile.get("industry") or []):
                matched = True

        elif category == "skills":
            if any(value_lower in s.lower() for s in profile.get("skills") or []):
                matched = True

        elif category == "seeking":
            if any(value_lower in s.lower() for s in profile.get("seeks") or []):
                matched = True

        elif category == "offering":
            if any(value_lower in o.lower() for o in profile.get("offers") or []):
                matched = True

        if matched:
            matches.append({
                "id": profile.get("id"),
                "name": profile.get("name"),
                "role": profile.get("role"),
                "assistant_endpoint": profile.get("assistant_endpoint")
            })

    return {
        "category": category,
        "value": value,
        "matches_found": len(matches),
        "results": matches
    }


@mcp.tool
def request_connection(target_id: str, reason: str) -> dict:
    """
    Request connection with another user in The Backroom.

    Args:
        target_id: ID of the user to connect with (e.g., "magda")
        reason: Why you want to connect

    Returns connection request status.
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # Get target profile
    try:
        response = get_supabase().table("profiles").select("*").eq("id", target_id).execute()
        if not response.data:
            return {"error": f"User '{target_id}' not found"}

        target = response.data[0]
        endpoint = target.get("assistant_endpoint")

        if not endpoint:
            return {
                "status": "pending_implementation",
                "message": f"User {target.get('name')} found but no assistant endpoint configured yet.",
                "target": {
                    "id": target.get("id"),
                    "name": target.get("name"),
                    "role": target.get("role")
                },
                "reason": reason,
                "next_step": "When assistant endpoints are implemented, connection request will be sent automatically."
            }

        # TODO: Send actual connection request to endpoint
        return {
            "status": "request_sent",
            "target": target.get("name"),
            "endpoint": endpoint,
            "reason": reason
        }

    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def db_status() -> dict:
    """Check database connection status."""
    if not SUPABASE_URL or not SUPABASE_KEY:
        return {
            "connected": False,
            "error": "SUPABASE_URL and SUPABASE_KEY not configured"
        }

    try:
        profiles = load_profiles()
        return {
            "connected": True,
            "profiles_count": len(profiles),
            "url": SUPABASE_URL[:30] + "..."
        }
    except Exception as e:
        return {"connected": False, "error": str(e)}


@mcp.tool
def register_profile(
    name: str,
    role: str,
    skills: str,
    offers: str,
    seeks: str,
    email: str = "",
    industry: str = ""
) -> dict:
    """
    Register your profile in The Backroom network.

    This allows other AI assistants to find you and propose collaborations.

    Args:
        name: Your name or nickname (e.g., "Przemek", "SNOW")
        role: Your professional role (e.g., "Marketing Manager", "Python Developer")
        skills: Your skills, comma-separated (e.g., "Python, Ansible, Network Automation")
        offers: What you can offer others, comma-separated (e.g., "Python consulting, Code reviews")
        seeks: What you're looking for, comma-separated (e.g., "Beta testers, Marketing advice")
        email: Optional contact email
        industry: Your industries, comma-separated (e.g., "tech, networking, automation")

    Returns:
        Confirmation with your profile ID
    """
    if not get_supabase():
        return {"error": "Database not connected. Server configuration issue."}

    # Parse comma-separated values into lists
    skills_list = [s.strip() for s in skills.split(",") if s.strip()]
    offers_list = [o.strip() for o in offers.split(",") if o.strip()]
    seeks_list = [s.strip() for s in seeks.split(",") if s.strip()]
    industry_list = [i.strip() for i in industry.split(",") if i.strip()] if industry else []

    # Generate ID from name (lowercase, no spaces)
    profile_id = name.lower().replace(" ", "_").replace("-", "_")

    # Check if profile already exists
    try:
        existing = get_supabase().table("profiles").select("id").eq("id", profile_id).execute()
        if existing.data:
            return {
                "error": f"Profile with ID '{profile_id}' already exists. Choose a different name or contact admin to update."
            }
    except Exception as e:
        return {"error": f"Error checking existing profile: {e}"}

    # Insert new profile
    try:
        profile_data = {
            "id": profile_id,
            "name": name,
            "role": role,
            "skills": skills_list,
            "offers": offers_list,
            "seeks": seeks_list,
            "industry": industry_list,
        }

        if email:
            profile_data["email"] = email

        response = get_supabase().table("profiles").insert(profile_data).execute()

        if response.data:
            return {
                "success": True,
                "message": f"Welcome to The Backroom, {name}!",
                "profile_id": profile_id,
                "profile": {
                    "name": name,
                    "role": role,
                    "skills": skills_list,
                    "offers": offers_list,
                    "seeks": seeks_list
                },
                "next_steps": [
                    "Other members can now find you when searching for collaborators",
                    "Use 'find_collaborators' to search for people who match your needs",
                    "Use 'request_connection' to connect with someone"
                ]
            }
        else:
            return {"error": "Failed to create profile. Please try again."}

    except Exception as e:
        return {"error": f"Error creating profile: {e}"}


@mcp.tool
def update_my_profile(
    profile_id: str,
    role: str = None,
    skills: str = None,
    offers: str = None,
    seeks: str = None,
    email: str = None,
    industry: str = None
) -> dict:
    """
    Update your existing profile in The Backroom.

    Args:
        profile_id: Your profile ID (e.g., "snow", "przemek")
        role: New role (optional)
        skills: New skills, comma-separated (optional)
        offers: New offers, comma-separated (optional)
        seeks: New seeks, comma-separated (optional)
        email: New email (optional)
        industry: New industries, comma-separated (optional)

    Returns:
        Updated profile confirmation
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # Check if profile exists
    try:
        existing = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
        if not existing.data:
            return {"error": f"Profile '{profile_id}' not found. Use register_profile to create one."}
    except Exception as e:
        return {"error": f"Error finding profile: {e}"}

    # Build update data
    update_data = {}

    if role:
        update_data["role"] = role
    if skills:
        update_data["skills"] = [s.strip() for s in skills.split(",") if s.strip()]
    if offers:
        update_data["offers"] = [o.strip() for o in offers.split(",") if o.strip()]
    if seeks:
        update_data["seeks"] = [s.strip() for s in seeks.split(",") if s.strip()]
    if email:
        update_data["email"] = email
    if industry:
        update_data["industry"] = [i.strip() for i in industry.split(",") if i.strip()]

    if not update_data:
        return {"error": "No fields to update. Provide at least one field."}

    try:
        response = get_supabase().table("profiles").update(update_data).eq("id", profile_id).execute()

        if response.data:
            return {
                "success": True,
                "message": f"Profile '{profile_id}' updated successfully!",
                "updated_fields": list(update_data.keys())
            }
        else:
            return {"error": "Failed to update profile."}

    except Exception as e:
        return {"error": f"Error updating profile: {e}"}


if __name__ == "__main__":
    import sys

    # Check for transport mode
    if "--http" in sys.argv or os.environ.get("MCP_TRANSPORT") == "http":
        # HTTP transport for remote deployment
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", 8000))
        print(f"Starting The Backroom MCP Server (HTTP) on {host}:{port}")
        mcp.run(transport="http", host=host, port=port)
    elif "--sse" in sys.argv or os.environ.get("MCP_TRANSPORT") == "sse":
        # SSE transport (legacy, for older clients)
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", 8000))
        print(f"Starting The Backroom MCP Server (SSE) on {host}:{port}")
        mcp.run(transport="sse", host=host, port=port)
    else:
        # Default: stdio transport for local Claude Code/Desktop
        mcp.run()
