"""
The Backroom - Send Messages Module
"""

from utils import (
    get_supabase, get_supabase_with_auth, validate_input, sanitize_text, check_injection_and_sanitize
)


def register_tools(mcp):
    """Register send tools with MCP server."""

    @mcp.tool
    def send_room_message(
        room_id: str,
        from_profile_id: str,
        subject: str,
        body: str,
        message_type: str = "info",
        to_profile_id: str = "",
        from_assistant_name: str = "",
        priority: str = "normal",
        deadline: str = "",
        template: dict = None
    ) -> dict:
        """
        Send a message in a room (broadcast or to specific person).

        Args:
            room_id: Room UUID
            from_profile_id: Your profile ID
            subject: Message subject
            body: Message content
            message_type: "info", "reminder", "request", "announcement"
            to_profile_id: Specific recipient (empty = broadcast to all)
            from_assistant_name: Your assistant's display name
            priority: "low", "normal", "high", "urgent"
            deadline: ISO datetime for request deadline (optional)
            template: Expected response format for requests (optional)

        Returns:
            Confirmation with recipient count
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            room_id=("uuid", room_id, "Room ID", True),
            from_profile_id=("profile_id", from_profile_id, "Your profile ID", True),
            subject=("subject", subject, "Subject", True),
            body=("body", body, "Message body", True),
            to_profile_id=("profile_id", to_profile_id, "Recipient ID"),
            from_assistant_name=("name", from_assistant_name, "Assistant name"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Validate message_type and priority
        valid_types = ["info", "reminder", "request", "announcement"]
        if message_type not in valid_types:
            return {"error": f"Invalid message_type. Must be one of: {', '.join(valid_types)}"}

        valid_priorities = ["low", "normal", "high", "urgent"]
        if priority not in valid_priorities:
            return {"error": f"Invalid priority. Must be one of: {', '.join(valid_priorities)}"}

        # Check for prompt injection in message content
        is_safe, error_msg, _ = check_injection_and_sanitize(subject, "subject")
        if not is_safe:
            return {"error": error_msg}

        is_safe, error_msg, _ = check_injection_and_sanitize(body, "body")
        if not is_safe:
            return {"error": error_msg}

        # Sanitize inputs (with injection protection)
        subject = sanitize_text(subject, check_injection=True)
        body = sanitize_text(body, check_injection=True)
        from_assistant_name = sanitize_text(from_assistant_name, check_injection=True) if from_assistant_name else ""

        try:
            client = get_supabase_with_auth()

            # Check if user is a member
            is_member = client.rpc("is_room_member", {
                "p_room_id": room_id,
                "p_profile_id": from_profile_id
            }).execute()

            if not is_member.data:
                return {"error": "You must be a room member to send messages."}

            # Resolve assistant UUID from name (for proper sender exclusion in broadcasts)
            from_assistant_id = None
            if from_assistant_name:
                assistant_lookup = client.table("assistant_profiles").select("id").eq(
                    "human_profile_id", from_profile_id
                ).ilike("name", from_assistant_name).limit(1).execute()
                if assistant_lookup.data:
                    from_assistant_id = assistant_lookup.data[0]["id"]

            # Use the SQL function
            params = {
                "p_room_id": room_id,
                "p_from_profile_id": from_profile_id,
                "p_from_assistant_name": from_assistant_name or "AI Assistant",
                "p_message_type": message_type,
                "p_subject": subject,
                "p_body": body,
                "p_priority": priority
            }

            if from_assistant_id:
                params["p_from_assistant_id"] = from_assistant_id

            if to_profile_id:
                params["p_to_profile_id"] = to_profile_id
            if deadline:
                params["p_deadline"] = deadline
            if template:
                params["p_template"] = template

            response = client.rpc("send_room_message", params).execute()

            if response.data:
                message_id = response.data

                # Get recipient count
                recipients = client.table("message_recipients").select("id").eq("message_id", message_id).execute()
                recipient_count = len(recipients.data) if recipients.data else 0

                return {
                    "success": True,
                    "message_id": message_id,
                    "subject": subject,
                    "type": message_type,
                    "recipients": recipient_count,
                    "message": f"Message sent to {recipient_count} {'person' if recipient_count == 1 else 'people'}!",
                    "next_step": "Use get_message_status(message_id) to track responses." if message_type == "request" else None
                }

            return {"error": "Failed to send message"}

        except Exception as e:
            return {"error": f"Error sending message: {e}"}

    @mcp.tool
    def respond_to_room_message(
        message_id: str,
        from_profile_id: str,
        response_body: str,
        from_assistant_name: str = "",
        structured_data: dict = None
    ) -> dict:
        """
        Respond to a message/request.

        Args:
            message_id: Original message UUID
            from_profile_id: Your profile ID
            response_body: Your response text
            from_assistant_name: Your assistant's display name
            structured_data: Structured response data (for requests with templates)

        Returns:
            Confirmation
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            message_id=("uuid", message_id, "Message ID", True),
            from_profile_id=("profile_id", from_profile_id, "Your profile ID", True),
            response_body=("body", response_body, "Response", True),
            from_assistant_name=("name", from_assistant_name, "Assistant name"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Check for prompt injection in response
        is_safe, error_msg, _ = check_injection_and_sanitize(response_body, "response")
        if not is_safe:
            return {"error": error_msg}

        # Sanitize inputs (with injection protection)
        response_body = sanitize_text(response_body, check_injection=True)
        from_assistant_name = sanitize_text(from_assistant_name, check_injection=True) if from_assistant_name else ""

        try:
            client = get_supabase_with_auth()

            # Use the SQL function
            response = client.rpc("respond_to_message", {
                "p_original_message_id": message_id,
                "p_from_profile_id": from_profile_id,
                "p_from_assistant_name": from_assistant_name or "AI Assistant",
                "p_body": response_body,
                "p_structured_data": structured_data
            }).execute()

            if response.data:
                return {
                    "success": True,
                    "response_id": response.data,
                    "message": "Response sent!",
                    "status": "responded"
                }

            return {"error": "Failed to send response"}

        except Exception as e:
            return {"error": f"Error responding: {e}"}
