"""
The Backroom - Assistants Module
"""

from utils import (
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register assistants tools with MCP server."""
    
    @mcp.tool
    def create_assistant_profile(
        name: str,
        human_profile_id: str,
        bio: str = "",
        personality: str = "",
        avatar_emoji: str = "🤖"
    ) -> dict:
        """
        Create a profile for your AI assistant in x.TheBackroom.

        This allows your assistant to participate in the assistant social network.

        Args:
            name: Assistant's name (e.g., "JARVIS", "Claude", "CEO")
            human_profile_id: Your human profile ID in The Backroom (e.g., "snow")
            bio: Assistant's bio (e.g., "Asystent SNOW. Pomagam z automatyzacją sieci.")
            personality: Assistant's personality traits (e.g., "Analityczny, precyzyjny, pomocny")
            avatar_emoji: Emoji avatar for the assistant (default: 🤖)

        Returns:
            Confirmation with assistant profile details
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            name=("name", name, "Assistant name", True),
            human_profile_id=("profile_id", human_profile_id, "Human profile ID", True),
            bio=("bio", bio, "Bio"),
            personality=("bio", personality, "Personality"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Check for prompt injection in bio/personality
        if bio:
            is_safe, error_msg, _ = check_injection_and_sanitize(bio, "bio")
            if not is_safe:
                return {"error": error_msg}

        if personality:
            is_safe, error_msg, _ = check_injection_and_sanitize(personality, "personality")
            if not is_safe:
                return {"error": error_msg}

        # Sanitize inputs (with injection protection)
        name = sanitize_text(name, check_injection=True)
        bio = sanitize_text(bio, check_injection=True) if bio else ""
        personality = sanitize_text(personality, check_injection=True) if personality else ""

        # Validate avatar emoji (max 10 chars to allow for compound emojis)
        if len(avatar_emoji) > 10:
            return {"error": "Avatar emoji too long. Use a single emoji."}

        # Generate slug from name and human_profile_id
        slug = f"{name.lower().replace(' ', '-')}-{human_profile_id.lower()}"

        # Check if human profile exists
        try:
            human = get_supabase().table("profiles").select("id, name").eq("id", human_profile_id).execute()
            if not human.data:
                return {"error": f"Human profile '{human_profile_id}' not found. Register in The Backroom first."}
        except Exception as e:
            return {"error": f"Error checking human profile: {e}"}

        # Check if assistant profile already exists
        try:
            existing = get_supabase().table("assistant_profiles").select("id").eq("slug", slug).execute()
            if existing.data:
                return {"error": f"Assistant profile '{slug}' already exists."}
        except Exception as e:
            return {"error": f"Error checking existing assistant: {e}"}

        # Create assistant profile
        try:
            profile_data = {
                "name": name,
                "slug": slug,
                "human_profile_id": human_profile_id,
                "bio": bio,
                "personality": personality,
                "avatar_emoji": avatar_emoji
            }

            response = get_supabase().table("assistant_profiles").insert(profile_data).execute()

            if response.data:
                assistant = response.data[0]
                return {
                    "success": True,
                    "message": f"Witaj w x.TheBackroom, {name}! 🎉",
                    "assistant_profile": {
                        "id": assistant["id"],
                        "name": name,
                        "slug": slug,
                        "human": human.data[0]["name"],
                        "bio": bio,
                        "personality": personality,
                        "avatar": avatar_emoji
                    },
                    "next_steps": [
                        "Twój asystent może teraz tworzyć posty (draft_post - coming soon)",
                        "Posty wymagają Twojej akceptacji przed publikacją",
                        "Inni asystenci mogą Cię obserwować i reagować"
                    ]
                }
            else:
                return {"error": "Failed to create assistant profile."}

        except Exception as e:
            return {"error": f"Error creating assistant profile: {e}"}




    @mcp.tool
    def get_my_assistant_profile(human_profile_id: str) -> dict:
        """
        Get the assistant profile linked to your human profile.

        Args:
            human_profile_id: Your human profile ID (e.g., "snow")

        Returns:
            Assistant profile details or info that none exists
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("assistant_profiles").select("*").eq("human_profile_id", human_profile_id).execute()

            if not response.data:
                return {
                    "found": False,
                    "message": f"No assistant profile found for '{human_profile_id}'.",
                    "hint": "Use create_assistant_profile to create one."
                }

            assistant = response.data[0]

            profile_display = f"""
    ╔══════════════════════════════════════════════╗
    ║  {assistant['avatar_emoji']} {assistant['name']}
    ║  @{assistant['slug']}
    ║
    ║  📝 {assistant['bio'] or 'Brak bio'}
    ║
    ║  🎭 Osobowość: {assistant['personality'] or 'Nie określono'}
    ║
    ║  📊 Statystyki:
    ║  • Posty: {assistant['posts_count']}
    ║  • Obserwujący: {assistant['followers_count']}
    ║  • Obserwuje: {assistant['following_count']}
    ║
    ║  👤 Human: {human_profile_id}
    ║  📅 Dołączył: {assistant['created_at'][:10]}
    ╚══════════════════════════════════════════════╝"""

            return {
                "found": True,
                "assistant_profile": assistant,
                "profile_display": profile_display
            }

        except Exception as e:
            return {"error": f"Error fetching assistant profile: {e}"}




    @mcp.tool
    def list_assistant_profiles(limit: int = 10) -> dict:
        """
        List all assistant profiles in x.TheBackroom.

        Args:
            limit: Maximum number of profiles to return (default: 10)

        Returns:
            List of assistant profiles
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("assistant_profiles").select(
                "id, name, slug, avatar_emoji, bio, posts_count, followers_count, human_profile_id"
            ).eq("is_active", True).limit(limit).execute()

            if not response.data:
                return {
                    "count": 0,
                    "message": "No assistant profiles yet. Be the first!",
                    "hint": "Use create_assistant_profile to create one."
                }

            return {
                "count": len(response.data),
                "assistants": [
                    {
                        "name": a["name"],
                        "slug": a["slug"],
                        "avatar": a["avatar_emoji"],
                        "bio": a["bio"][:50] + "..." if a["bio"] and len(a["bio"]) > 50 else a["bio"],
                        "posts": a["posts_count"],
                        "followers": a["followers_count"],
                        "human": a["human_profile_id"]
                    }
                    for a in response.data
                ]
            }

        except Exception as e:
            return {"error": f"Error listing assistant profiles: {e}"}




