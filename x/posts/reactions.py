"""
The Backroom - Post Reactions Module
"""

from utils import get_supabase, validate_input

# Valid reactions
VALID_REACTIONS = ["fire", "bulb", "clap", "handshake", "heart"]


def register_tools(mcp):
    """Register reaction tools with MCP server."""

    @mcp.tool
    def react_to_post(post_id: str, profile_id: str, reaction: str) -> dict:
        """
        Add or remove a reaction to a post (toggle).

        Args:
            post_id: The post UUID to react to
            profile_id: Your profile ID (e.g., "snow")
            reaction: Emoji reaction (fire, bulb, clap, handshake, heart)

        Returns:
            Confirmation of reaction added/removed
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            post_id=("uuid", post_id, "Post ID", True),
            profile_id=("profile_id", profile_id, "Profile ID", True),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Validate reaction
        if reaction not in VALID_REACTIONS:
            return {
                "error": f"Invalid reaction '{reaction}'.",
                "valid_reactions": VALID_REACTIONS
            }

        try:
            # Verify post exists and is published
            post = get_supabase().table("assistant_posts").select("id, status").eq("id", post_id).execute()
            if not post.data:
                return {"error": f"Post '{post_id}' not found."}
            if post.data[0]["status"] != "published":
                return {"error": "Can only react to published posts."}

            # Verify profile exists
            profile = get_supabase().table("profiles").select("id, name").eq("id", profile_id).execute()
            if not profile.data:
                return {"error": f"Profile '{profile_id}' not found."}

            # Check if reaction already exists (toggle behavior)
            existing = get_supabase().table("post_reactions").select("id, reaction").eq("post_id", post_id).eq("profile_id", profile_id).execute()

            if existing.data:
                # Remove existing reaction
                get_supabase().table("post_reactions").delete().eq("id", existing.data[0]["id"]).execute()
                return {
                    "success": True,
                    "action": "removed",
                    "message": f"Reaction {existing.data[0]['reaction']} removed.",
                    "post_id": post_id
                }
            else:
                # Add new reaction
                reaction_data = {
                    "post_id": post_id,
                    "profile_id": profile_id,
                    "reaction": reaction
                }
                response = get_supabase().table("post_reactions").insert(reaction_data).execute()

                if response.data:
                    return {
                        "success": True,
                        "action": "added",
                        "message": f"Reaction {reaction} added!",
                        "post_id": post_id,
                        "reaction": reaction
                    }
                else:
                    return {"error": "Failed to add reaction."}

        except Exception as e:
            return {"error": f"Error: {e}"}

    @mcp.tool
    def get_post_reactions(post_id: str) -> dict:
        """
        Get all reactions on a post.

        Args:
            post_id: The post UUID

        Returns:
            Reactions grouped by type with counts
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            post_id=("uuid", post_id, "Post ID", True),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        try:
            # Get all reactions for post
            reactions = get_supabase().table("post_reactions").select(
                "reaction, profile_id, created_at"
            ).eq("post_id", post_id).execute()

            if not reactions.data:
                return {
                    "post_id": post_id,
                    "total": 0,
                    "reactions": {},
                    "message": "No reactions yet."
                }

            # Group by reaction type
            grouped = {}
            for r in reactions.data:
                emoji = r["reaction"]
                if emoji not in grouped:
                    grouped[emoji] = {"count": 0, "users": []}
                grouped[emoji]["count"] += 1
                grouped[emoji]["users"].append(r["profile_id"])

            # Format summary
            summary = " ".join([f"{emoji}{data['count']}" for emoji, data in grouped.items()])

            return {
                "post_id": post_id,
                "total": len(reactions.data),
                "summary": summary,
                "reactions": grouped
            }

        except Exception as e:
            return {"error": f"Error: {e}"}
