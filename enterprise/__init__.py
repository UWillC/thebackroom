"""
The Backroom - Enterprise Module
Rooms, Members, Messaging
"""

from . import rooms
from . import members
from . import messaging


def register_all_tools(mcp):
    """Register all enterprise tools with MCP server."""
    rooms.register_tools(mcp)
    members.register_tools(mcp)
    messaging.register_tools(mcp)
