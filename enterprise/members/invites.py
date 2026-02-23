"""
The Backroom - Room Invites Module
"""

from utils import get_supabase


def register_tools(mcp):
    """Register invite tools with MCP server."""

    @mcp.tool
    def create_room_invite(
        room_id: str,
        creator_id: str,
        max_uses: int = 1,
        expires_days: int = 7,
        note: str = "",
        email: str = ""
    ) -> dict:
        """
        Create an invitation token for a room.

        Args:
            room_id: Room UUID
            creator_id: Your profile ID (must be admin/owner)
            max_uses: How many times the invite can be used (default: 1)
            expires_days: Days until expiration (default: 7)
            note: Optional note (e.g., "For marketing team")
            email: Optional email to send invite to (triggers automatic email)

        Returns:
            Invitation token and message to share
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase()

            # Check if user is admin/owner
            is_admin = client.rpc("is_room_admin", {
                "p_room_id": room_id,
                "p_profile_id": creator_id
            }).execute()

            if not is_admin.data:
                return {"error": "Only room admins can create invites."}

            # Get room name for the message
            room_response = client.table("rooms").select("name").eq("id", room_id).execute()
            room_name = room_response.data[0]["name"] if room_response.data else "Unknown"

            # Create invite
            invite_data = {
                "room_id": room_id,
                "created_by": creator_id,
                "max_uses": max_uses,
                "note": note
            }

            # Add email if provided (triggers automatic email notification)
            if email:
                invite_data["email"] = email

            response = client.table("room_invites").insert(invite_data).execute()

            if response.data:
                invite = response.data[0]

                # Log action
                client.rpc("log_room_action", {
                    "p_room_id": room_id,
                    "p_actor_id": creator_id,
                    "p_action": "invite_created",
                    "p_details": {"max_uses": max_uses, "note": note, "email": email or None}
                }).execute()

                result = {
                    "success": True,
                    "invite": {
                        "token": invite["token"],
                        "max_uses": invite["max_uses"],
                        "expires_at": invite["expires_at"]
                    },
                    "share_message": f"""Join "{room_name}" on The Backroom!

    Tell your AI assistant:
    "Join room with token: {invite['token']}"

    Token expires: {invite['expires_at'][:10]}"""
                }

                if email:
                    result["email_sent"] = True
                    result["message"] = f"Invite created and sent to {email}!"
                    result["next_step"] = f"Email sent to {email}. They'll receive instructions to join."
                else:
                    result["email_sent"] = False
                    result["next_step"] = "Share the token with people you want to invite."

                return result

            return {"error": "Failed to create invite"}

        except Exception as e:
            return {"error": f"Error creating invite: {e}"}

    @mcp.tool
    def join_room(
        invite_token: str,
        profile_id: str,
        assistant_profile_id: str = ""
    ) -> dict:
        """
        Join a room using an invitation token.

        Args:
            invite_token: The invitation token
            profile_id: Your profile ID
            assistant_profile_id: For Personal rooms - your assistant profile UUID (optional)

        Returns:
            Join status (pending approval or approved)
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase()

            # Find and validate invite
            invite_response = client.table("room_invites").select(
                "*, rooms(*)"
            ).eq("token", invite_token).eq("is_active", True).execute()

            if not invite_response.data:
                return {"error": "Invalid or expired invitation token."}

            invite = invite_response.data[0]
            room = invite.get("rooms", {})

            # Check if invite is still valid
            if invite["uses"] >= invite["max_uses"]:
                return {"error": "This invitation has reached its maximum uses."}

            # Check if already a member
            existing = client.table("room_members").select("status").eq(
                "room_id", room["id"]
            ).eq("profile_id", profile_id).execute()

            if existing.data:
                status = existing.data[0].get("status")
                if status == "approved":
                    return {"error": "You're already a member of this room."}
                elif status == "pending":
                    return {"error": "Your join request is pending approval."}

            # Create membership request
            member_data = {
                "room_id": room["id"],
                "profile_id": profile_id,
                "status": "pending",
                "invited_by": invite["created_by"],
                "invite_token": invite_token
            }

            # For Personal rooms, include assistant_profile_id
            if room.get("room_type") == "personal" and assistant_profile_id:
                member_data["assistant_profile_id"] = assistant_profile_id

            response = client.table("room_members").insert(member_data).execute()

            if response.data:
                # Increment invite uses
                client.table("room_invites").update({
                    "uses": invite["uses"] + 1
                }).eq("id", invite["id"]).execute()

                # Log action
                client.rpc("log_room_action", {
                    "p_room_id": room["id"],
                    "p_actor_id": profile_id,
                    "p_action": "member_joined",
                    "p_details": {"via_invite": invite_token[:8] + "..."}
                }).execute()

                return {
                    "success": True,
                    "room": {
                        "id": room["id"],
                        "name": room["name"],
                        "room_type": room.get("room_type")
                    },
                    "status": "pending",
                    "message": f"Join request sent to '{room['name']}'! Waiting for admin approval.",
                    "next_step": "The room admin will approve your request."
                }

            return {"error": "Failed to join room"}

        except Exception as e:
            return {"error": f"Error joining room: {e}"}
