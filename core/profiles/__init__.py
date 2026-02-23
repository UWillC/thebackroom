"""
The Backroom - Profiles Package
"""

from . import crud
from . import quality
from . import email


def register_tools(mcp):
    """Register all profile tools."""
    crud.register_tools(mcp)
    quality.register_tools(mcp)
    email.register_tools(mcp)
