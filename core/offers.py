"""
The Backroom - Offers Module
"""

from utils import (
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register offers tools with MCP server."""
    
    @mcp.tool
    def add_offer(
        profile_id: str,
        title: str,
        offer_type: str = "free",
        description: str = "",
        condition: str = "",
        link: str = ""
    ) -> dict:
        """
        Add a new offer to your profile.

        Allows multiple offers per profile (free consultations, resources, etc.)

        Args:
            profile_id: Your profile ID (e.g., "snow")
            title: Short title (e.g., "15-min call o automatyzacji")
            offer_type: Type of offer: "free", "paid", "intro" (default: "free")
            description: Longer description (optional)
            condition: Condition to claim (e.g., "przez LinkedIn DM")
            link: Optional link (e.g., calendly, gumroad)

        Returns:
            Confirmation with offer ID
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            profile_id=("profile_id", profile_id, "Profile ID", True),
            title=("name", title, "Title", True),
            description=("description", description, "Description"),
            condition=("offer", condition, "Condition"),
            link=("url", link, "Link"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Validate offer_type
        valid_types = ["free", "paid", "intro"]
        if offer_type not in valid_types:
            return {"error": f"Invalid offer_type. Must be one of: {', '.join(valid_types)}"}

        # Prompt-injection check on free-text fields
        for _val, _name in [(title, "title"), (description, "description"), (condition, "condition")]:
            if _val:
                is_safe, error_msg, _ = check_injection_and_sanitize(_val, _name)
                if not is_safe:
                    return {"error": error_msg}

        # Sanitize inputs (with injection protection)
        title = sanitize_text(title, check_injection=True)
        description = sanitize_text(description, check_injection=True) if description else ""
        condition = sanitize_text(condition, check_injection=True) if condition else ""

        # Verify profile exists
        try:
            profile = get_supabase().table("profiles").select("id, name").eq("id", profile_id).execute()
            if not profile.data:
                return {"error": f"Profile '{profile_id}' not found. Register first."}
        except Exception as e:
            return {"error": f"Error checking profile: {e}"}

        # Add offer
        try:
            offer_data = {
                "profile_id": profile_id,
                "title": title,
                "offer_type": offer_type,
                "description": description,
                "condition": condition,
                "link": link,
                "is_active": True
            }

            response = get_supabase().table("profile_offers").insert(offer_data).execute()

            if response.data:
                offer = response.data[0]
                return {
                    "success": True,
                    "message": f"Offer added: {title}",
                    "offer_id": offer["id"],
                    "offer": {
                        "id": offer["id"],
                        "title": title,
                        "type": offer_type,
                        "condition": condition or "Brak"
                    }
                }
            else:
                return {"error": "Failed to add offer."}

        except Exception as e:
            return {"error": f"Error adding offer: {e}"}




    @mcp.tool
    def list_my_offers(profile_id: str) -> dict:
        """
        List all offers for a profile.

        Args:
            profile_id: Profile ID (e.g., "snow")

        Returns:
            List of active offers
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("profile_offers").select("*").eq(
                "profile_id", profile_id
            ).eq("is_active", True).execute()

            offers = response.data or []

            if not offers:
                return {
                    "profile_id": profile_id,
                    "offers_count": 0,
                    "message": "No offers yet. Use add_offer to create one.",
                    "offers": []
                }

            return {
                "profile_id": profile_id,
                "offers_count": len(offers),
                "offers": [
                    {
                        "id": o["id"],
                        "title": o["title"],
                        "type": o["offer_type"],
                        "description": o["description"],
                        "condition": o["condition"],
                        "link": o["link"]
                    }
                    for o in offers
                ]
            }

        except Exception as e:
            return {"error": f"Error listing offers: {e}"}




    @mcp.tool
    def remove_offer(offer_id: str) -> dict:
        """
        Remove (deactivate) an offer.

        Args:
            offer_id: The offer UUID to remove

        Returns:
            Confirmation
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Soft delete - set is_active to false
            response = get_supabase().table("profile_offers").update({
                "is_active": False
            }).eq("id", offer_id).execute()

            if response.data:
                return {
                    "success": True,
                    "message": f"Offer {offer_id} removed.",
                    "offer_id": offer_id
                }
            else:
                return {"error": f"Offer '{offer_id}' not found."}

        except Exception as e:
            return {"error": f"Error removing offer: {e}"}




