"""
The Backroom - Connections Module
"""

from utils import (
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register connections tools with MCP server."""
    
    @mcp.tool
    def get_connection_funnel(days: int = 30) -> dict:
        """
        Get connection funnel analytics.

        Tracks: SENT → VIEWED → ACCEPTED → CONTACTED

        Shows conversion rates at each stage to identify drop-off points.

        Args:
            days: Number of days to analyze (default: 30)
        """
        client = get_supabase()
        if not client:
            return {"error": "Database not connected."}

        try:
            # Call the SQL function
            response = client.rpc("get_connection_funnel_stats", {
                "p_days": days
            }).execute()

            if response.data:
                data = response.data
                funnel = data.get("funnel", {})
                rates = data.get("conversion_rates", {})

                # Build visual funnel
                funnel_visual = f"""
    ╔══════════════════════════════════════════════╗
    ║           CONNECTION FUNNEL ({days} days)
    ╠══════════════════════════════════════════════╣
    ║ 📤 SENT:      {funnel.get('sent', 0):>5}  (100%)
    ║      ↓ {rates.get('sent_to_viewed', 0)}%
    ║ 👀 VIEWED:    {funnel.get('viewed', 0):>5}
    ║      ↓ {rates.get('viewed_to_accepted', 0)}%
    ║ ✅ ACCEPTED:  {funnel.get('accepted', 0):>5}
    ║      ↓ {rates.get('accepted_to_contacted', 0)}%
    ║ 🤝 CONTACTED: {funnel.get('contacted', 0):>5}
    ╠══════════════════════════════════════════════╣
    ║ 🎯 OVERALL SUCCESS: {rates.get('overall_success', 0)}%
    ╚══════════════════════════════════════════════╝"""

                return {
                    "period_days": days,
                    "funnel": funnel,
                    "conversion_rates": rates,
                    "funnel_visual": funnel_visual,
                    "insights": {
                        "sent_to_viewed": "If low: people don't see requests (check notifications)",
                        "viewed_to_accepted": "If low: requests not compelling (improve messages)",
                        "accepted_to_contacted": "If low: people don't follow up (improve 'Co teraz?' UX)"
                    }
                }
            else:
                return {
                    "message": "No funnel data yet. Start sending connection requests!",
                    "funnel": {"sent": 0, "viewed": 0, "accepted": 0, "contacted": 0}
                }

        except Exception as e:
            # If table doesn't exist yet, return helpful message
            if "does not exist" in str(e) or "function" in str(e).lower():
                return {
                    "error": "Funnel metrics not set up yet.",
                    "setup": "Run connection_funnel_metrics.sql in Supabase to enable."
                }
            return {"error": f"Failed to get funnel stats: {str(e)}"}




    @mcp.tool
    def mark_connection_contacted(request_id: str, contact_method: str = "") -> dict:
        """
        Mark a connection as 'contacted' for funnel tracking.

        Call this after you've actually reached out to someone you connected with.

        Args:
            request_id: The connection request UUID
            contact_method: How you contacted them (e.g., "LinkedIn", "Email", "Call")
        """
        client = get_supabase()
        if not client:
            return {"error": "Database not connected."}

        try:
            response = client.rpc("log_connection_contacted", {
                "p_request_id": request_id,
                "p_contact_method": contact_method
            }).execute()

            if response.data:
                return {
                    "success": True,
                    "message": "Marked as contacted! Great job following up.",
                    "request_id": request_id,
                    "contact_method": contact_method or "not specified"
                }
            return {"error": "Failed to log contact"}

        except Exception as e:
            return {"error": f"Error: {str(e)}"}




    @mcp.tool
    def send_connection_request(from_user_id: str, to_user_id: str, message: str, reason: str = "") -> dict:
        """
        Send a connection request to another user in The Backroom.

        Args:
            from_user_id: Your profile ID (e.g., "snow")
            to_user_id: ID of the user to connect with (e.g., "magda")
            message: Personal message to include with the request
            reason: Why you want to connect (optional)

        Returns:
            Confirmation that request was sent
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            from_user_id=("profile_id", from_user_id, "Your profile ID", True),
            to_user_id=("profile_id", to_user_id, "Target profile ID", True),
            message=("message", message, "Message", True),
            reason=("message", reason, "Reason"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Check for prompt injection in message content
        is_safe, error_msg, _ = check_injection_and_sanitize(message, "message")
        if not is_safe:
            return {"error": error_msg}

        if reason:
            is_safe, error_msg, _ = check_injection_and_sanitize(reason, "reason")
            if not is_safe:
                return {"error": error_msg}

        # Sanitize inputs
        message = sanitize_text(message, check_injection=True)
        reason = sanitize_text(reason, check_injection=True) if reason else ""

        # Check rate limit
        rate_check = check_rate_limit(from_user_id, "connection_request")
        if not rate_check.get("allowed", True):
            return {
                "error": "Rate limit exceeded.",
                "message": f"You've sent {rate_check['current']} connection requests in the last {rate_check['window_hours']} hours. Max: {rate_check['max']}/day.",
                "remaining": 0,
                "retry_after": "Try again tomorrow."
            }

        try:
            # Verify both users exist
            from_user = get_supabase().table("profiles").select("id, name").eq("id", from_user_id).execute()
            if not from_user.data:
                return {"error": f"Your profile '{from_user_id}' not found. Register first with register_profile."}

            to_user = get_supabase().table("profiles").select("id, name, role").eq("id", to_user_id).execute()
            if not to_user.data:
                return {"error": f"User '{to_user_id}' not found."}

            # Check if request already exists
            existing = get_supabase().table("connection_requests").select("id, status").eq("from_user", from_user_id).eq("to_user", to_user_id).eq("status", "pending").execute()
            if existing.data:
                return {"error": "You already have a pending request to this user. Wait for their response."}

            # Create connection request
            request_data = {
                "from_user": from_user_id,
                "to_user": to_user_id,
                "message": message,
                "reason": reason,
                "status": "pending"
            }

            result = get_supabase().table("connection_requests").insert(request_data).execute()

            if result.data:
                return {
                    "success": True,
                    "message": f"Connection request sent to {to_user.data[0]['name']}!",
                    "request_id": result.data[0]["id"],
                    "to_user": {
                        "id": to_user.data[0]["id"],
                        "name": to_user.data[0]["name"],
                        "role": to_user.data[0].get("role")
                    },
                    "status": "pending",
                    "next_step": f"Wait for {to_user.data[0]['name']} to accept or decline your request."
                }
            else:
                return {"error": "Failed to send request."}

        except Exception as e:
            return {"error": str(e)}




    @mcp.tool
    def check_incoming_requests(user_id: str) -> dict:
        """
        Check for incoming connection requests (people who want to connect with you).

        Args:
            user_id: Your profile ID (e.g., "snow")

        Returns:
            List of pending connection requests
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Get pending requests
            requests = get_supabase().table("connection_requests").select(
                "id, from_user, message, reason, created_at"
            ).eq("to_user", user_id).eq("status", "pending").execute()

            if not requests.data:
                return {
                    "pending_requests": 0,
                    "message": "No pending connection requests."
                }

            # Get from_user details
            enriched_requests = []
            for req in requests.data:
                from_profile = get_supabase().table("profiles").select(
                    "name, role, offers, seeks"
                ).eq("id", req["from_user"]).execute()

                if from_profile.data:
                    enriched_requests.append({
                        "request_id": req["id"],
                        "from_user": {
                            "id": req["from_user"],
                            "name": from_profile.data[0].get("name"),
                            "role": from_profile.data[0].get("role"),
                            "offers": from_profile.data[0].get("offers"),
                            "seeks": from_profile.data[0].get("seeks")
                        },
                        "message": req["message"],
                        "reason": req["reason"],
                        "created_at": req["created_at"]
                    })

            return {
                "pending_requests": len(enriched_requests),
                "requests": enriched_requests,
                "action_needed": "Use respond_to_request to accept or decline each request."
            }

        except Exception as e:
            return {"error": str(e)}




    @mcp.tool
    def respond_to_request(request_id: str, accept: bool, response_message: str = "", share_email: bool = False) -> dict:
        """
        Respond to a connection request (accept or decline).

        Args:
            request_id: The ID of the connection request
            accept: True to accept, False to decline
            response_message: Optional message to send back
            share_email: If accepting, whether to share your email

        Returns:
            Confirmation of response
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Get the request
            request = get_supabase().table("connection_requests").select("*").eq("id", request_id).execute()
            if not request.data:
                return {"error": f"Request '{request_id}' not found."}

            req = request.data[0]
            if req["status"] != "pending":
                return {"error": f"Request already {req['status']}."}

            # Get your profile for contact info
            my_profile = get_supabase().table("profiles").select("*").eq("id", req["to_user"]).execute()
            contact_shared = {}

            if accept and my_profile.data:
                profile = my_profile.data[0]
                if share_email and profile.get("email"):
                    contact_shared["email"] = profile["email"]

            # Update the request
            update_data = {
                "status": "accepted" if accept else "declined",
                "response_message": response_message,
                "contact_shared": contact_shared,
                "responded_at": "now()"
            }

            result = get_supabase().table("connection_requests").update(update_data).eq("id", request_id).execute()

            if result.data:
                # Get from_user name
                from_profile = get_supabase().table("profiles").select("name").eq("id", req["from_user"]).execute()
                from_name = from_profile.data[0]["name"] if from_profile.data else req["from_user"]

                if accept:
                    return {
                        "success": True,
                        "message": f"You accepted the connection request from {from_name}!",
                        "contact_shared": contact_shared if contact_shared else "No contact info shared",
                        "next_step": f"{from_name} will be notified and can now see your shared contact info."
                    }
                else:
                    return {
                        "success": True,
                        "message": f"You declined the connection request from {from_name}.",
                        "next_step": "They will be notified of your decision."
                    }
            else:
                return {"error": "Failed to update request."}

        except Exception as e:
            return {"error": str(e)}




    @mcp.tool
    def check_my_sent_requests(user_id: str) -> dict:
        """
        Check the status of connection requests you've sent.

        Args:
            user_id: Your profile ID (e.g., "snow")

        Returns:
            List of your sent requests and their status
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            requests = get_supabase().table("connection_requests").select(
                "id, to_user, status, message, response_message, contact_shared, created_at, responded_at"
            ).eq("from_user", user_id).execute()

            if not requests.data:
                return {
                    "sent_requests": 0,
                    "message": "You haven't sent any connection requests yet."
                }

            # Enrich with to_user details
            enriched = []
            for req in requests.data:
                to_profile = get_supabase().table("profiles").select("name, role").eq("id", req["to_user"]).execute()

                entry = {
                    "request_id": req["id"],
                    "to_user": {
                        "id": req["to_user"],
                        "name": to_profile.data[0]["name"] if to_profile.data else req["to_user"],
                        "role": to_profile.data[0].get("role") if to_profile.data else None
                    },
                    "status": req["status"],
                    "your_message": req["message"],
                    "created_at": req["created_at"]
                }

                if req["status"] == "accepted":
                    entry["response_message"] = req.get("response_message")
                    entry["contact_shared"] = req.get("contact_shared", {})
                elif req["status"] == "declined":
                    entry["response_message"] = req.get("response_message")
                    entry["responded_at"] = req.get("responded_at")

                enriched.append(entry)

            # Count by status
            pending = sum(1 for r in enriched if r["status"] == "pending")
            accepted = sum(1 for r in enriched if r["status"] == "accepted")
            declined = sum(1 for r in enriched if r["status"] == "declined")

            return {
                "sent_requests": len(enriched),
                "summary": {
                    "pending": pending,
                    "accepted": accepted,
                    "declined": declined
                },
                "requests": enriched
            }

        except Exception as e:
            return {"error": str(e)}




