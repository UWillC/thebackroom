"""
The Backroom - Profiles Module
"""

from utils import (
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register profile tools with MCP server."""
    
    @mcp.tool
    def verify_email(profile_id: str, token: str) -> dict:
        """
        Verify your email address with the token received via email.

        Args:
            profile_id: Your profile ID (e.g., "snow")
            token: The verification token from the email

        Returns:
            Confirmation if email was verified successfully
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Call the SQL function
            response = get_supabase().rpc("verify_email_token", {
                "p_profile_id": profile_id,
                "p_token": token
            }).execute()

            if response.data:
                result = response.data
                if result.get("success"):
                    return {
                        "success": True,
                        "message": result.get("message", "Email verified!"),
                        "profile_id": profile_id,
                        "email": result.get("email"),
                        "already_verified": result.get("already_verified", False),
                        "next_steps": [
                            "You will now receive email notifications",
                            "Connection requests will be sent to your verified email"
                        ]
                    }
                else:
                    return {
                        "success": False,
                        "error": result.get("error", "Verification failed")
                    }
            else:
                return {"error": "No response from verification function"}

        except Exception as e:
            return {"error": f"Error verifying email: {e}"}





    @mcp.tool
    def resend_verification_email(profile_id: str) -> dict:
        """
        Resend the email verification link.

        Use this if you didn't receive the verification email or if the token expired.
        Rate limited to 1 request per 5 minutes.

        Args:
            profile_id: Your profile ID (e.g., "snow")

        Returns:
            Confirmation that verification email was sent
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Call the SQL function
            response = get_supabase().rpc("resend_verification_email", {
                "p_profile_id": profile_id
            }).execute()

            if response.data:
                result = response.data
                if result.get("success"):
                    return {
                        "success": True,
                        "message": result.get("message", "Verification email sent!"),
                        "profile_id": profile_id,
                        "hint": "Check your inbox (and spam folder) for the verification email."
                    }
                else:
                    return {
                        "success": False,
                        "error": result.get("error", "Failed to resend verification email")
                    }
            else:
                return {"error": "No response from resend function"}

        except Exception as e:
            return {"error": f"Error resending verification email: {e}"}





    @mcp.tool
    def check_email_verification_status(profile_id: str) -> dict:
        """
        Check if your email is verified and notifications are enabled.

        Args:
            profile_id: Your profile ID (e.g., "snow")

        Returns:
            Email verification status and notification settings
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("profiles").select(
                "id, name, email, email_verified, notifications_enabled, email_verification_sent_at"
            ).eq("id", profile_id).execute()

            if not response.data:
                return {"error": f"Profile '{profile_id}' not found."}

            profile = response.data[0]

            # Build status display
            email = profile.get("email")
            verified = profile.get("email_verified", False)
            notifications = profile.get("notifications_enabled", True)
            sent_at = profile.get("email_verification_sent_at")

            if not email:
                status = "NO_EMAIL"
                message = "No email address on profile. Add email with update_my_profile."
            elif verified:
                status = "VERIFIED"
                message = "Email is verified. You will receive notifications."
            elif sent_at:
                status = "PENDING"
                message = "Verification email sent. Check your inbox and enter the token."
            else:
                status = "NOT_SENT"
                message = "Email added but verification not sent. Use resend_verification_email."

            return {
                "profile_id": profile_id,
                "name": profile.get("name"),
                "email": email[:3] + "***" + email[email.index("@"):] if email else None,  # Mask email
                "status": status,
                "email_verified": verified,
                "notifications_enabled": notifications,
                "message": message,
                "actions": {
                    "PENDING": "Use verify_email(profile_id, token) with the token from email",
                    "NOT_SENT": "Use resend_verification_email(profile_id) to send verification",
                    "VERIFIED": "All set! Use toggle_notifications(profile_id, false) to disable notifications"
                }.get(status)
            }

        except Exception as e:
            return {"error": f"Error checking verification status: {e}"}





    @mcp.tool
    def toggle_notifications(profile_id: str, enabled: bool) -> dict:
        """
        Enable or disable email notifications for your profile.

        Args:
            profile_id: Your profile ID (e.g., "snow")
            enabled: True to enable notifications, False to disable

        Returns:
            Confirmation of notification settings change
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Call the SQL function
            response = get_supabase().rpc("toggle_notifications", {
                "p_profile_id": profile_id,
                "p_enabled": enabled
            }).execute()

            if response.data:
                result = response.data
                if result.get("success"):
                    return {
                        "success": True,
                        "message": result.get("message"),
                        "profile_id": profile_id,
                        "notifications_enabled": result.get("notifications_enabled"),
                        "hint": "Enabled" if enabled else "You will no longer receive email notifications."
                    }
                else:
                    return {
                        "success": False,
                        "error": result.get("error", "Failed to toggle notifications")
                    }
            else:
                return {"error": "No response from toggle function"}

        except Exception as e:
            return {"error": f"Error toggling notifications: {e}"}






