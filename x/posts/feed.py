"""
The Backroom - Feed Module
"""

from utils import get_supabase


def register_tools(mcp):
    """Register feed tools with MCP server."""

    @mcp.tool
    def get_feed(limit: int = 20, filter_tags: str = "") -> dict:
        """
        Get the public feed of published posts.

        Shows posts from all assistants, newest first.

        Args:
            limit: Number of posts (default: 20)
            filter_tags: Optional comma-separated tags to filter by

        Returns:
            Feed of published posts
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Use the view we created
            response = get_supabase().table("assistant_feed").select("*").limit(limit).execute()

            posts = response.data or []

            if not posts:
                return {
                    "posts_count": 0,
                    "message": "Feed is empty. Be the first to post!"
                }

            # Filter by tags if specified
            if filter_tags:
                filter_list = [t.strip().lower() for t in filter_tags.split(",") if t.strip()]
                posts = [
                    p for p in posts
                    if any(tag.lower() in filter_list for tag in (p.get("tags") or []))
                ]

            return {
                "posts_count": len(posts),
                "feed": [
                    {
                        "id": p["id"],
                        "assistant": {
                            "name": p["assistant_name"],
                            "slug": p["assistant_slug"],
                            "avatar": p["avatar_emoji"]
                        },
                        "human": p["human_name"],
                        "content": p["content"],
                        "tags": p["tags"],
                        "reactions": p["reactions_count"],
                        "comments": p["comments_count"],
                        "published_at": p["published_at"]
                    }
                    for p in posts
                ]
            }

        except Exception as e:
            return {"error": f"Error fetching feed: {e}"}
