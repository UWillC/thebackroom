#!/usr/bin/env python3
"""
The Backroom - MCP Server
"Where AI assistants connect their humans"

Usage:
    pip install fastmcp anthropic
    python server.py

For Claude Desktop, add to config:
    {
        "mcpServers": {
            "backroom": {
                "command": "python",
                "args": ["/path/to/server.py"]
            }
        }
    }
"""

from fastmcp import FastMCP
import json
import glob
from pathlib import Path

# Initialize MCP server
mcp = FastMCP("The Backroom")

# Load profiles from JSON files
def load_profiles() -> list:
    """Load all profile JSON files from the current directory."""
    profiles = []
    script_dir = Path(__file__).parent

    for file_path in glob.glob(str(script_dir / "demo-*.json")):
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                profile = json.load(f)
                profiles.append(profile)
        except (json.JSONDecodeError, IOError):
            continue

    return profiles


@mcp.tool
def list_profiles() -> dict:
    """List all profiles in The Backroom network."""
    profiles = load_profiles()
    return {
        "count": len(profiles),
        "profiles": [
            {
                "id": p.get("id"),
                "name": p.get("name"),
                "role": p.get("role"),
                "industry": p.get("industry", [])
            }
            for p in profiles
        ]
    }


@mcp.tool
def get_profile(profile_id: str) -> dict:
    """Get detailed profile by ID."""
    profiles = load_profiles()

    for profile in profiles:
        if profile.get("id") == profile_id:
            return {"found": True, "profile": profile}

    return {"found": False, "error": f"Profile '{profile_id}' not found"}


@mcp.tool
def find_collaborators(query: str, max_results: int = 5) -> dict:
    """
    Search for collaborators matching the query.

    Examples:
    - "looking for someone who knows Python"
    - "need marketing advice"
    - "seeking co-founder with tech skills"
    """
    profiles = load_profiles()
    query_lower = query.lower()

    matches = []

    for profile in profiles:
        score = 0
        reasons = []

        # Check offers
        for offer in profile.get("offers", []):
            if query_lower in offer.lower():
                score += 3
                reasons.append(f"Offers: {offer}")

        # Check seeks (reciprocal matching)
        for seek in profile.get("seeks", []):
            if query_lower in seek.lower():
                score += 2
                reasons.append(f"Seeks: {seek}")

        # Check skills
        skills = profile.get("capital", {}).get("skills", [])
        for skill in skills:
            if query_lower in skill.lower():
                score += 2
                reasons.append(f"Skill: {skill}")

        # Check industry
        for industry in profile.get("industry", []):
            if query_lower in industry.lower():
                score += 1
                reasons.append(f"Industry: {industry}")

        # Check role
        if query_lower in profile.get("role", "").lower():
            score += 1
            reasons.append(f"Role match")

        if score > 0:
            matches.append({
                "id": profile.get("id"),
                "name": profile.get("name"),
                "role": profile.get("role"),
                "score": score,
                "reasons": reasons,
                "linkedin": profile.get("links", {}).get("linkedin")
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
    profiles = load_profiles()
    value_lower = value.lower()
    matches = []

    for profile in profiles:
        matched = False

        if category == "industry":
            if any(value_lower in i.lower() for i in profile.get("industry", [])):
                matched = True

        elif category == "skills":
            skills = profile.get("capital", {}).get("skills", [])
            if any(value_lower in s.lower() for s in skills):
                matched = True

        elif category == "seeking":
            if any(value_lower in s.lower() for s in profile.get("seeks", [])):
                matched = True

        elif category == "offering":
            if any(value_lower in o.lower() for o in profile.get("offers", [])):
                matched = True

        if matched:
            matches.append({
                "id": profile.get("id"),
                "name": profile.get("name"),
                "role": profile.get("role"),
                "linkedin": profile.get("links", {}).get("linkedin")
            })

    return {
        "category": category,
        "value": value,
        "matches_found": len(matches),
        "results": matches
    }


if __name__ == "__main__":
    mcp.run()
