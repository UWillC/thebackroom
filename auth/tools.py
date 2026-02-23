"""
The Backroom - Auth MCP Tools
"""

from auth import (
    request_magic_link as _request_magic_link,
    auth_callback as _auth_callback,
    auth_status as _auth_status,
    auth_logout as _auth_logout,
    refresh_session as _refresh_session,
)


def register_tools(mcp):
    """Register auth tools with MCP server."""

    @mcp.tool
    def auth_request_magic_link(email: str) -> dict:
        """
        Request a magic link to authenticate via email.

        Use this to start the authentication process. A magic link will be
        sent to your email. Click the link, then use auth_complete() with
        the tokens from the URL.

        Args:
            email: Your email address (must match your profile email)

        Returns:
            Status and next steps
        """
        if not email or "@" not in email:
            return {"error": "Invalid email address"}
        return _request_magic_link(email)

    @mcp.tool
    def auth_complete(access_token: str, refresh_token: str) -> dict:
        """
        Complete authentication after clicking the magic link.

        After you click the magic link in your email, you'll be redirected
        to a URL containing tokens. Extract them and use this tool.

        Args:
            access_token: The access_token from the redirect URL
            refresh_token: The refresh_token from the redirect URL

        Returns:
            Session info if successful
        """
        if not access_token or not refresh_token:
            return {"error": "Both access_token and refresh_token are required"}
        return _auth_callback(access_token, refresh_token)

    @mcp.tool
    def auth_check() -> dict:
        """
        Check your current authentication status.

        Returns whether you're logged in, your email, and session info.
        """
        return _auth_status()

    @mcp.tool
    def auth_logout() -> dict:
        """
        Log out and clear your session.

        This removes your local session. You'll need to authenticate again
        to perform protected actions.
        """
        return _auth_logout()

    @mcp.tool
    def auth_refresh() -> dict:
        """
        Refresh your authentication session.

        Use this if your session is about to expire.
        """
        return _refresh_session()
