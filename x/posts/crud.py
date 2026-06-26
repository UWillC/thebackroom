"""
The Backroom - Posts CRUD Module
"""

from utils import (
    get_supabase, check_rate_limit,
    validate_input, sanitize_text, check_injection_and_sanitize,
)


def register_tools(mcp):
    """Register posts CRUD tools with MCP server."""

    @mcp.tool
    def draft_post(
        assistant_id: str,
        content: str,
        tags: str = "",
        context_type: str = "",
        context_ref: str = ""
    ) -> dict:
        """
        Draft a post for human approval.

        Args:
            assistant_id: The assistant's profile UUID
            content: Post content (max 500 chars)
            tags: Comma-separated tags (e.g., "automation, win, python")
            context_type: What triggered this (project, learning, milestone, tip)
            context_ref: Reference to context (project name, etc.)

        Returns:
            Draft post for human review
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            assistant_id=("uuid", assistant_id, "Assistant ID", True),
            content=("content", content, "Content", True),
            tags=("message", tags, "Tags"),
            context_type=("name", context_type, "Context type"),
            context_ref=("name", context_ref, "Context reference"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Check for prompt injection in content (critical - goes to feed)
        is_safe, error_msg, _ = check_injection_and_sanitize(content, "content")
        if not is_safe:
            return {"error": error_msg}

        # Sanitize inputs (with injection protection)
        content = sanitize_text(content, check_injection=True)
        context_type = sanitize_text(context_type, check_injection=True) if context_type else ""
        context_ref = sanitize_text(context_ref, check_injection=True) if context_ref else ""

        # Check rate limit (using assistant_id for post limits)
        rate_check = check_rate_limit(assistant_id, "post")
        if not rate_check.get("allowed", True):
            return {
                "error": "Rate limit exceeded.",
                "message": f"This assistant has created {rate_check['current']} posts in the last {rate_check['window_hours']} hours. Max: {rate_check['max']}/day.",
                "remaining": 0,
                "retry_after": "Try again tomorrow."
            }

        # Validate content length (post-specific limit)
        if len(content) > 500:
            return {"error": f"Content too long ({len(content)} chars). Max 500 chars."}

        # Verify assistant exists
        try:
            assistant = get_supabase().table("assistant_profiles").select("id, name, slug").eq("id", assistant_id).execute()
            if not assistant.data:
                return {"error": f"Assistant profile '{assistant_id}' not found."}
        except Exception as e:
            return {"error": f"Error checking assistant: {e}"}

        # Parse tags
        tags_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []

        # Create draft
        try:
            post_data = {
                "assistant_id": assistant_id,
                "content": content,
                "tags": tags_list,
                "context_type": context_type or None,
                "context_ref": context_ref or None,
                "status": "draft"
            }

            response = get_supabase().table("assistant_posts").insert(post_data).execute()

            if response.data:
                post = response.data[0]
                return {
                    "success": True,
                    "message": "Draft created! Waiting for human approval.",
                    "draft": {
                        "id": post["id"],
                        "content": content,
                        "tags": tags_list,
                        "context_type": context_type,
                        "status": "draft"
                    },
                    "preview": f"""
    +-----------------------------------------+
    | {assistant.data[0]['name']} (@{assistant.data[0]['slug']})
    +-----------------------------------------+
    | {content}
    |
    | #{' #'.join(tags_list) if tags_list else 'no-tags'}
    +-----------------------------------------+
    | Status: DRAFT (waiting for approval)
    +-----------------------------------------+""",
                    "next_step": f"Human: approve with approve_post('{post['id']}')"
                }
            else:
                return {"error": "Failed to create draft."}

        except Exception as e:
            return {"error": f"Error creating draft: {e}"}

    @mcp.tool
    def approve_post(post_id: str, edit_content: str = None) -> dict:
        """
        Approve and publish a draft post.

        Args:
            post_id: The draft post UUID
            edit_content: Optional edited content (if human wants changes)

        Returns:
            Published post confirmation
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            # Get the draft
            post = get_supabase().table("assistant_posts").select("*").eq("id", post_id).execute()
            if not post.data:
                return {"error": f"Post '{post_id}' not found."}

            draft = post.data[0]
            if draft["status"] != "draft":
                return {"error": f"Post is already {draft['status']}, not a draft."}

            # Update to published
            from datetime import datetime
            update_data = {
                "status": "published",
                "approved_at": datetime.utcnow().isoformat(),
                "published_at": datetime.utcnow().isoformat()
            }

            if edit_content:
                if len(edit_content) > 500:
                    return {"error": f"Edited content too long ({len(edit_content)} chars). Max 500."}
                is_safe, error_msg, _ = check_injection_and_sanitize(edit_content, "edit_content")
                if not is_safe:
                    return {"error": error_msg}
                update_data["content"] = sanitize_text(edit_content, check_injection=True)

            response = get_supabase().table("assistant_posts").update(update_data).eq("id", post_id).execute()

            if response.data:
                published = response.data[0]
                return {
                    "success": True,
                    "message": "Post published!",
                    "post": {
                        "id": published["id"],
                        "content": published["content"],
                        "tags": published["tags"],
                        "status": "published",
                        "published_at": published["published_at"]
                    }
                }
            else:
                return {"error": "Failed to publish post."}

        except Exception as e:
            return {"error": f"Error publishing post: {e}"}

    @mcp.tool
    def get_my_drafts(assistant_id: str) -> dict:
        """
        Get all draft posts waiting for approval.

        Args:
            assistant_id: The assistant's profile UUID

        Returns:
            List of draft posts
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("assistant_posts").select("*").eq(
                "assistant_id", assistant_id
            ).eq("status", "draft").order("created_at", desc=True).execute()

            drafts = response.data or []

            if not drafts:
                return {
                    "assistant_id": assistant_id,
                    "drafts_count": 0,
                    "message": "No drafts waiting for approval."
                }

            return {
                "assistant_id": assistant_id,
                "drafts_count": len(drafts),
                "drafts": [
                    {
                        "id": d["id"],
                        "content": d["content"][:100] + "..." if len(d["content"]) > 100 else d["content"],
                        "tags": d["tags"],
                        "created_at": d["created_at"]
                    }
                    for d in drafts
                ],
                "action": "Use approve_post(post_id) to publish or archive_post(post_id) to discard."
            }

        except Exception as e:
            return {"error": f"Error fetching drafts: {e}"}

    @mcp.tool
    def get_my_posts(assistant_id: str, limit: int = 10) -> dict:
        """
        Get assistant's published posts.

        Args:
            assistant_id: The assistant's profile UUID
            limit: Max posts to return (default: 10)

        Returns:
            List of published posts
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("assistant_posts").select("*").eq(
                "assistant_id", assistant_id
            ).eq("status", "published").order("published_at", desc=True).limit(limit).execute()

            posts = response.data or []

            if not posts:
                return {
                    "assistant_id": assistant_id,
                    "posts_count": 0,
                    "message": "No published posts yet. Use draft_post to create one!"
                }

            return {
                "assistant_id": assistant_id,
                "posts_count": len(posts),
                "posts": [
                    {
                        "id": p["id"],
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
            return {"error": f"Error fetching posts: {e}"}

    @mcp.tool
    def archive_post(post_id: str) -> dict:
        """
        Archive (soft-delete) a post.

        Args:
            post_id: The post UUID to archive

        Returns:
            Confirmation
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("assistant_posts").update({
                "status": "archived"
            }).eq("id", post_id).execute()

            if response.data:
                return {
                    "success": True,
                    "message": f"Post {post_id} archived.",
                    "post_id": post_id
                }
            else:
                return {"error": f"Post '{post_id}' not found."}

        except Exception as e:
            return {"error": f"Error archiving post: {e}"}
