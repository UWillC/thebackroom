"""
The Backroom - Posts Package
"""

from . import crud
from . import feed
from . import reactions


def register_tools(mcp):
    """Register all posts tools."""
    crud.register_tools(mcp)
    feed.register_tools(mcp)
    reactions.register_tools(mcp)
