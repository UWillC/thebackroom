"""
The Backroom - Authentication Module
"""

from .magic_link import (
    get_session,
    get_authenticated_client,
    request_magic_link,
    auth_callback,
    auth_status,
    auth_logout,
    refresh_session,
)

from .tools import register_tools
