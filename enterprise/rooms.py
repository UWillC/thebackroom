"""
The Backroom - Rooms Module
"""

from utils import (
    get_supabase, get_supabase_with_auth, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register rooms tools with MCP server."""
    
    @mcp.tool
    def create_room(
        name: str,
        room_type: str = "enterprise",
        description: str = "",
        owner_id: str = ""
    ) -> dict:
        """
        Create a new private room.

        Args:
            name: Room name (e.g., "Acme Corp", "My Personal Sync")
            room_type: "enterprise" (for companies) or "personal" (for assistant sync)
            description: Optional room description
            owner_id: Profile ID of the owner (required)

        Returns:
            Room details including ID and slug
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            name=("name", name, "Room name", True),
            owner_id=("profile_id", owner_id, "Owner ID", True),
            description=("description", description, "Description"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Sanitize inputs
        name = sanitize_text(name)
        description = sanitize_text(description) if description else ""

        if room_type not in ["enterprise", "personal"]:
            return {"error": "room_type must be 'enterprise' or 'personal'"}

        try:
            client = get_supabase_with_auth()

            # Generate slug
            slug_response = client.rpc("generate_room_slug", {"room_name": name}).execute()
            slug = slug_response.data if slug_response.data else name.lower().replace(" ", "-")

            # Create room
            room_data = {
                "name": name,
                "slug": slug,
                "description": description,
                "room_type": room_type,
                "owner_id": owner_id,
                "settings": {
                    "require_approval": True,
                    "allow_member_invite": False,
                    "max_members": 50 if room_type == "enterprise" else 10,
                    "visible_in_directory": False
                }
            }

            response = client.table("rooms").insert(room_data).execute()

            if response.data:
                room = response.data[0]

                # Add owner as member with 'owner' role
                from datetime import datetime, timezone
                member_data = {
                    "room_id": room["id"],
                    "profile_id": owner_id,
                    "role": "owner",
                    "status": "approved",
                    "joined_at": datetime.now(timezone.utc).isoformat()
                }
                client.table("room_members").insert(member_data).execute()

                # For personal rooms: auto-add owner's assistants as members
                assistants_added = 0
                if room_type == "personal":
                    try:
                        assistants = client.table("assistant_profiles").select("id").eq(
                            "human_profile_id", owner_id
                        ).eq("is_active", True).execute()

                        for a in (assistants.data or []):
                            client.table("room_members").insert({
                                "room_id": room["id"],
                                "profile_id": owner_id,
                                "assistant_profile_id": a["id"],
                                "role": "member",
                                "status": "approved",
                                "joined_at": datetime.now(timezone.utc).isoformat()
                            }).execute()
                            assistants_added += 1
                    except Exception:
                        pass  # Non-critical

                # Log action
                client.rpc("log_room_action", {
                    "p_room_id": room["id"],
                    "p_actor_id": owner_id,
                    "p_action": "room_created",
                    "p_details": {"room_type": room_type, "assistants_added": assistants_added}
                }).execute()

                return {
                    "success": True,
                    "room": {
                        "id": room["id"],
                        "name": room["name"],
                        "slug": room["slug"],
                        "room_type": room["room_type"],
                        "owner_id": owner_id
                    },
                    "assistants_added": assistants_added,
                    "message": f"Room '{name}' created! Next: create_room_invite to invite members.",
                    "next_step": "Use create_room_invite(room_id) to create invitation tokens."
                }

            return {"error": "Failed to create room"}

        except Exception as e:
            return {"error": f"Error creating room: {e}"}




    @mcp.tool
    def get_my_rooms(profile_id: str) -> dict:
        """
        Get all rooms where you are a member or owner.

        Args:
            profile_id: Your profile ID

        Returns:
            List of rooms with your role in each
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Use the my_rooms view
            response = client.table("room_members").select(
                "*, rooms(*)"
            ).eq("profile_id", profile_id).in_("status", ["approved", "pending"]).execute()

            if not response.data:
                return {
                    "rooms_count": 0,
                    "rooms": [],
                    "message": "You're not a member of any rooms yet."
                }

            rooms = []
            for rm in response.data:
                room = rm.get("rooms", {})
                rooms.append({
                    "id": room.get("id"),
                    "name": room.get("name"),
                    "slug": room.get("slug"),
                    "room_type": room.get("room_type"),
                    "my_role": rm.get("role"),
                    "my_status": rm.get("status"),
                    "joined_at": rm.get("joined_at")
                })

            return {
                "rooms_count": len(rooms),
                "rooms": rooms
            }

        except Exception as e:
            return {"error": f"Error fetching rooms: {e}"}




    @mcp.tool
    def get_room_details(room_id: str, profile_id: str) -> dict:
        """
        Get detailed information about a room.

        Args:
            room_id: Room UUID or slug
            profile_id: Your profile ID (for access check)

        Returns:
            Room details including member count
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Get room by ID or slug
            room_query = client.table("rooms").select("*")
            if len(room_id) == 36 and "-" in room_id:
                room_query = room_query.eq("id", room_id)
            else:
                room_query = room_query.eq("slug", room_id)

            room_response = room_query.execute()

            if not room_response.data:
                return {"error": f"Room '{room_id}' not found."}

            room = room_response.data[0]

            # Check if user is a member
            member_check = client.table("room_members").select("role, status").eq(
                "room_id", room["id"]
            ).eq("profile_id", profile_id).execute()

            if not member_check.data or member_check.data[0].get("status") not in ["approved", "pending"]:
                return {"error": "You don't have access to this room."}

            user_role = member_check.data[0].get("role")

            # Get member counts
            members_response = client.table("room_members").select("status").eq("room_id", room["id"]).execute()
            members = members_response.data or []

            approved_count = len([m for m in members if m.get("status") == "approved"])
            pending_count = len([m for m in members if m.get("status") == "pending"])

            return {
                "room": {
                    "id": room["id"],
                    "name": room["name"],
                    "slug": room["slug"],
                    "description": room.get("description"),
                    "room_type": room["room_type"],
                    "owner_id": room["owner_id"],
                    "settings": room.get("settings", {}),
                    "created_at": room["created_at"]
                },
                "your_role": user_role,
                "members_count": approved_count,
                "pending_count": pending_count
            }

        except Exception as e:
            return {"error": f"Error fetching room: {e}"}




    @mcp.tool
    def get_room_audit_log(room_id: str, admin_id: str, limit: int = 20) -> dict:
        """
        Get audit log of room actions (admin only).

        Args:
            room_id: Room UUID
            admin_id: Your profile ID (must be admin/owner)
            limit: Max entries to return (default: 20)

        Returns:
            List of audit log entries
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Check if user is admin
            is_admin = client.rpc("is_room_admin", {
                "p_room_id": room_id,
                "p_profile_id": admin_id
            }).execute()

            if not is_admin.data:
                return {"error": "Only room admins can view audit logs."}

            # Get audit log
            response = client.table("room_audit_log").select(
                "*, profiles!room_audit_log_actor_id_fkey(name)"
            ).eq("room_id", room_id).order("created_at", desc=True).limit(limit).execute()

            if not response.data:
                return {
                    "entries_count": 0,
                    "entries": [],
                    "message": "No audit log entries."
                }

            return {
                "entries_count": len(response.data),
                "entries": [
                    {
                        "action": e["action"],
                        "actor": e.get("profiles", {}).get("name", e["actor_id"]),
                        "target": e.get("target_id"),
                        "details": e.get("details", {}),
                        "timestamp": e["created_at"]
                    }
                    for e in response.data
                ]
            }

        except Exception as e:
            return {"error": f"Error fetching audit log: {e}"}


    # ============== PROMPTS: ENTERPRISE ROOMS ==============



