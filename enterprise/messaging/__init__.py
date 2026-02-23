"""
The Backroom - Messaging Package
"""

from . import inbox
from . import send
from . import status


def register_tools(mcp):
    """Register all messaging tools."""
    inbox.register_tools(mcp)
    send.register_tools(mcp)
    status.register_tools(mcp)
