"""
The Backroom - Member Approvals Module
"""

from utils import get_supabase, get_supabase_with_auth


def register_tools(mcp):
    """Register approval tools with MCP server."""

    @mcp.tool
    def get_pending_approvals(room_id: str, admin_id: str) -> dict:
        """
        Get list of members waiting for approval (admin only).

        Args:
            room_id: Room UUID
            admin_id: Your profile ID (must be admin/owner)

        Returns:
            List of pending members
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
                return {"error": "Only room admins can view pending approvals."}

            # Get pending members using the view
            response = client.table("room_pending_approvals").select("*").eq("room_id", room_id).execute()

            if not response.data:
                return {
                    "pending_count": 0,
                    "pending": [],
                    "message": "No pending approvals."
                }

            return {
                "pending_count": len(response.data),
                "pending": [
                    {
                        "profile_id": p["profile_id"],
                        "name": p["member_name"],
                        "title": p["member_title"],
                        "email": p["member_email"],
                        "bio": p.get("member_bio", "")[:100],
                        "invited_by": p.get("invited_by_name"),
                        "requested_at": p["requested_at"]
                    }
                    for p in response.data
                ],
                "next_step": "Use approve_member(room_id, profile_id) or reject_member(room_id, profile_id)"
            }

        except Exception as e:
            return {"error": f"Error fetching pending: {e}"}

    @mcp.tool
    def approve_member(
        room_id: str,
        profile_id: str,
        admin_id: str,
        role: str = "member"
    ) -> dict:
        """
        Approve a pending member (admin only).

        Args:
            room_id: Room UUID
            profile_id: Profile ID of the person to approve
            admin_id: Your profile ID (must be admin/owner)
            role: Role to assign - "member" or "admin" (default: member)

        Returns:
            Confirmation
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
                return {"error": "Only room admins can approve members."}

            # Update member status
            response = client.table("room_members").update({
                "status": "approved",
                "role": role,
                "joined_at": "now()"
            }).eq("room_id", room_id).eq("profile_id", profile_id).eq("status", "pending").execute()

            if response.data:
                # Get member name for message
                profile_response = client.table("profiles").select("name").eq("id", profile_id).execute()
                member_name = profile_response.data[0]["name"] if profile_response.data else profile_id

                # Log action
                client.rpc("log_room_action", {
                    "p_room_id": room_id,
                    "p_actor_id": admin_id,
                    "p_action": "member_approved",
                    "p_target_id": profile_id,
                    "p_details": {"role": role}
                }).execute()

                return {
                    "success": True,
                    "message": f"{member_name} approved as {role}!",
                    "member": {
                        "profile_id": profile_id,
                        "name": member_name,
                        "role": role
                    }
                }

            return {"error": f"No pending request found for '{profile_id}'"}

        except Exception as e:
            return {"error": f"Error approving member: {e}"}

    @mcp.tool
    def offboard_member(
        room_id: str,
        profile_id: str,
        admin_id: str,
        reason: str = "Left company"
    ) -> dict:
        """
        Remove a member from the room (soft delete with audit log).

        Args:
            room_id: Room UUID
            profile_id: Profile ID of the person to remove
            admin_id: Your profile ID (must be admin/owner)
            reason: Reason for removal (e.g., "Left company", "Role change")

        Returns:
            Confirmation
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
                return {"error": "Only room admins can remove members."}

            # Update member status
            response = client.table("room_members").update({
                "status": "offboarded",
                "offboarded_at": "now()",
                "offboarded_by": admin_id,
                "offboard_reason": reason
            }).eq("room_id", room_id).eq("profile_id", profile_id).eq("status", "approved").execute()

            if response.data:
                # Get member name
                profile_response = client.table("profiles").select("name").eq("id", profile_id).execute()
                member_name = profile_response.data[0]["name"] if profile_response.data else profile_id

                # Log action
                client.rpc("log_room_action", {
                    "p_room_id": room_id,
                    "p_actor_id": admin_id,
                    "p_action": "member_offboarded",
                    "p_target_id": profile_id,
                    "p_details": {"reason": reason}
                }).execute()

                return {
                    "success": True,
                    "message": f"{member_name} removed from room.",
                    "reason": reason,
                    "note": "This action is logged in the audit log."
                }

            return {"error": f"Member '{profile_id}' not found or not active."}

        except Exception as e:
            return {"error": f"Error removing member: {e}"}
