"""
The Backroom - Member Search Module
"""

from utils import get_supabase, validate_input, sanitize_text


def register_tools(mcp):
    """Register member search tools with MCP server."""

    @mcp.tool
    def search_in_room(
        room_id: str,
        query: str,
        profile_id: str,
        max_results: int = 5
    ) -> dict:
        """
        Search for members within a specific room.

        Args:
            room_id: Room UUID
            query: Search query (skills, role, name)
            profile_id: Your profile ID (for access check)
            max_results: Max results to return (default: 5)

        Returns:
            Matching room members
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            room_id=("uuid", room_id, "Room ID", True),
            query=("query", query, "Search query", True),
            profile_id=("profile_id", profile_id, "Profile ID", True),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Validate max_results
        if max_results < 1 or max_results > 50:
            return {"error": "max_results must be between 1 and 50."}

        # Sanitize query
        query = sanitize_text(query)

        try:
            client = get_supabase()

            # Check if user is a member
            is_member = client.rpc("is_room_member", {
                "p_room_id": room_id,
                "p_profile_id": profile_id
            }).execute()

            if not is_member.data:
                return {"error": "You must be a room member to search."}

            # Get room info
            room_response = client.table("rooms").select("name, room_type").eq("id", room_id).execute()
            room_name = room_response.data[0]["name"] if room_response.data else "Unknown"

            # Get active members
            members_response = client.table("room_active_members").select("*").eq("room_id", room_id).execute()

            if not members_response.data:
                return {
                    "query": query,
                    "room": room_name,
                    "matches_found": 0,
                    "results": []
                }

            # Search logic
            query_lower = query.lower()
            matches = []

            for m in members_response.data:
                score = 0
                reasons = []

                # Check name
                if query_lower in (m.get("member_name") or "").lower():
                    score += 2
                    reasons.append("Name match")

                # Check title/role
                if query_lower in (m.get("member_title") or "").lower():
                    score += 2
                    reasons.append("Role match")

                # Check skills
                for skill in (m.get("member_skills") or []):
                    if query_lower in skill.lower():
                        score += 3
                        reasons.append(f"Skill: {skill}")

                # Check bio
                if query_lower in (m.get("member_bio") or "").lower():
                    score += 1
                    reasons.append("Bio match")

                # Check tags
                for tag in (m.get("member_tags") or []):
                    if query_lower in tag.lower():
                        score += 1
                        reasons.append(f"Tag: {tag}")

                if score > 0:
                    matches.append({
                        "profile_id": m["profile_id"],
                        "name": m["member_name"],
                        "title": m.get("member_title"),
                        "role_in_room": m["role"],
                        "score": score,
                        "reasons": reasons
                    })

            # Sort by score
            matches.sort(key=lambda x: x["score"], reverse=True)

            return {
                "query": query,
                "room": room_name,
                "matches_found": len(matches),
                "results": matches[:max_results]
            }

        except Exception as e:
            return {"error": f"Error searching: {e}"}

    @mcp.tool
    def list_room_members(room_id: str, profile_id: str) -> dict:
        """
        List all active members of a room.

        Args:
            room_id: Room UUID
            profile_id: Your profile ID (for access check)

        Returns:
            List of room members
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase()

            # Check if user is a member
            is_member = client.rpc("is_room_member", {
                "p_room_id": room_id,
                "p_profile_id": profile_id
            }).execute()

            if not is_member.data:
                return {"error": "You must be a room member to view members."}

            # Get active members
            response = client.table("room_active_members").select("*").eq("room_id", room_id).execute()

            if not response.data:
                return {
                    "members_count": 0,
                    "members": [],
                    "room": "Unknown"
                }

            room_name = response.data[0].get("room_name", "Unknown")

            return {
                "room": room_name,
                "members_count": len(response.data),
                "members": [
                    {
                        "profile_id": m["profile_id"],
                        "name": m["member_name"],
                        "title": m.get("member_title"),
                        "role": m["role"],
                        "joined_at": m.get("joined_at"),
                        # For Personal rooms, show assistant info
                        "assistant_name": m.get("assistant_name")
                    }
                    for m in response.data
                ]
            }

        except Exception as e:
            return {"error": f"Error listing members: {e}"}
