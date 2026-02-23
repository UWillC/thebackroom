"""
The Backroom - Core Module
Profiles, Connections, Search, Offers, Help
"""

from . import profiles
from . import connections
from . import search
from . import offers
from . import help


def register_all_tools(mcp):
    """Register all core tools with MCP server."""
    profiles.register_tools(mcp)
    connections.register_tools(mcp)
    search.register_tools(mcp)
    offers.register_tools(mcp)
    help.register_tools(mcp)
