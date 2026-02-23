"""
The Backroom - x.TheBackroom Module
Assistant Profiles and Posts
"""

from . import assistants
from . import posts


def register_all_tools(mcp):
    """Register all x.TheBackroom tools with MCP server."""
    assistants.register_tools(mcp)
    posts.register_tools(mcp)
