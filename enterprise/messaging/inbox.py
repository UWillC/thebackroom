"""
The Backroom - Message Inbox Module
"""

from utils import get_supabase, get_supabase_with_auth, wrap_untrusted


def register_tools(mcp):
    """Register inbox tools with MCP server."""

    @mcp.tool
    def check_room_inbox(
        profile_id: str,
        assistant_id: str = "",
        room_id: str = ""
    ) -> dict:
        """
        Check for unread messages in your room inbox.

        Args:
            profile_id: Your profile ID
            assistant_id: For Personal rooms - your assistant UUID (optional)
            room_id: Filter to specific room (optional)

        Returns:
            List of unread messages
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Use the SQL function
            params = {"p_profile_id": profile_id}
            if assistant_id:
                params["p_assistant_id"] = assistant_id
            if room_id:
                params["p_room_id"] = room_id

            response = client.rpc("check_inbox", params).execute()

            if not response.data:
                return {
                    "unread_count": 0,
                    "messages": [],
                    "message": "No unread messages."
                }

            messages = response.data

            # Format for display
            formatted = []
            for m in messages:
                priority_icon = {
                    "urgent": "[!]",
                    "high": "[H]",
                    "normal": "[ ]",
                    "low": "[-]"
                }.get(m.get("priority"), "[ ]")

                formatted.append({
                    "id": m["message_id"],
                    "priority": f"{priority_icon} {m.get('priority', 'normal').upper()}",
                    "from": m.get("sender_name"),
                    "from_assistant": m.get("sender_assistant"),
                    "room": m.get("room_name"),
                    "subject": m.get("subject"),
                    "type": m.get("message_type"),
                    "deadline": m.get("deadline"),
                    "sent_at": m.get("sent_at")
                })

            return {
                "unread_count": len(formatted),
                "messages": formatted,
                "next_step": "Use read_room_message(message_id) to open a message."
            }

        except Exception as e:
            return {"error": f"Error checking inbox: {e}"}

    @mcp.tool
    def read_room_message(message_id: str, profile_id: str) -> dict:
        """
        Read a message and mark it as read.

        Args:
            message_id: Message UUID
            profile_id: Your profile ID

        Returns:
            Full message content
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            client = get_supabase_with_auth()

            # Get message
            response = client.table("room_messages").select(
                "*, rooms(name, room_type)"
            ).eq("id", message_id).execute()

            if not response.data:
                return {"error": "Message not found."}

            msg = response.data[0]
            room = msg.get("rooms", {})

            # Get sender info
            sender_response = client.table("profiles").select("name").eq("id", msg["from_profile_id"]).execute()
            sender_name = sender_response.data[0]["name"] if sender_response.data else "Unknown"

            # Mark as read
            client.rpc("mark_message_read", {
                "p_message_id": message_id,
                "p_profile_id": profile_id
            }).execute()

            # Determine available actions
            actions = ["acknowledge"]
            if msg["message_type"] in ["request", "reminder"]:
                actions = ["respond", "acknowledge", "remind_later"]

            return {
                "message": {
                    "id": msg["id"],
                    "room": room.get("name"),
                    "from": sender_name,
                    "from_assistant": msg.get("from_assistant_name"),
                    "type": msg["message_type"],
                    "subject": msg["subject"],
                    "body": wrap_untrusted(msg["body"], source=f"message sender ({sender_name})"),
                    "priority": msg.get("priority", "normal"),
                    "deadline": msg.get("deadline"),
                    "template": msg.get("template"),
                    "sent_at": msg["created_at"]
                },
                "status": "read",
                "actions": actions,
                "next_step": "Use respond_to_room_message(message_id, response) to reply." if "respond" in actions else None
            }

        except Exception as e:
            return {"error": f"Error reading message: {e}"}
