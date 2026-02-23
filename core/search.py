"""
The Backroom - Search Module
"""

from utils import (
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register search tools with MCP server."""
    
    @mcp.tool
    def find_collaborators(query: str, max_results: int = 5, user_id: str = "") -> dict:
        """
        Search for collaborators matching the query.

        Examples:
        - "looking for someone who knows Python"
        - "need marketing advice"
        - "seeking co-founder with tech skills"

        Args:
            query: Search query
            max_results: Maximum results to return (default: 5)
            user_id: Optional user ID for rate limiting (default: "anonymous")
        """
        if not get_supabase():
            return {"error": "Database not connected. Set SUPABASE_URL and SUPABASE_KEY."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            query=("query", query, "Search query", True),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Validate max_results
        if max_results < 1 or max_results > 50:
            return {"error": "max_results must be between 1 and 50."}

        # Sanitize query
        query = sanitize_text(query)

        # Check rate limit for search
        search_user = user_id or "anonymous"
        rate_check = check_rate_limit(search_user, "search")
        if not rate_check.get("allowed", True):
            return {
                "error": "Rate limit exceeded.",
                "message": f"Too many searches ({rate_check['current']}) in the last hour. Max: {rate_check['max']}/hour.",
                "remaining": 0,
                "retry_after": "Try again in an hour."
            }

        profiles = load_profiles()
        query_lower = query.lower()

        matches = []

        for profile in profiles:
            score = 0
            reasons = []

            # Check offers
            for offer in profile.get("offers") or []:
                if query_lower in offer.lower():
                    score += 3
                    reasons.append(f"Offers: {offer}")

            # Check seeks (reciprocal matching)
            for seek in profile.get("seeks") or []:
                if query_lower in seek.lower():
                    score += 2
                    reasons.append(f"Seeks: {seek}")

            # Check skills
            for skill in profile.get("skills") or []:
                if query_lower in skill.lower():
                    score += 2
                    reasons.append(f"Skill: {skill}")

            # Check industry
            for industry in profile.get("industry") or []:
                if query_lower in industry.lower():
                    score += 1
                    reasons.append(f"Industry: {industry}")

            # Check role
            if query_lower in (profile.get("role") or "").lower():
                score += 1
                reasons.append("Role match")

            if score > 0:
                summary = format_profile_summary(profile)
                matches.append({
                    **summary,
                    "match_score": score,
                    "reasons": reasons,
                    "assistant_endpoint": profile.get("assistant_endpoint")
                })

        # Sort by score descending
        matches.sort(key=lambda x: x["match_score"], reverse=True)

        # Log search for analytics
        log_search(query=query, results_count=len(matches), search_type="general")

        # Log search appearances for profile stats
        result_ids = [m.get("id") for m in matches[:max_results] if m.get("id")]
        if result_ids:
            log_search_appearances(result_ids, query, user_id)

        return {
            "query": query,
            "matches_found": len(matches),
            "results": matches[:max_results]
        }




    @mcp.tool
    def get_my_matches(profile_id: str, max_results: int = 5) -> dict:
        """
        Find people who match YOUR profile - proactive matching!

        Analyzes your seeks vs others' offers (who can help you)
        and your offers vs others' seeks (who you can help).

        Returns ranked matches with explanations like:
        "Anna offers Python training - you're seeking Python skills"

        Args:
            profile_id: Your profile ID
            max_results: Maximum matches to return (default: 5)

        Example:
            get_my_matches("snow") → finds people matching snow's needs
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # Get my profile
        try:
            my_response = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
            if not my_response.data:
                return {"error": f"Profile '{profile_id}' not found. Register first with register_profile."}
            my_profile = my_response.data[0]
        except Exception as e:
            return {"error": f"Failed to get profile: {str(e)}"}

        my_seeks = [s.lower() for s in (my_profile.get("seeks") or [])]
        my_offers = [o.lower() for o in (my_profile.get("offers") or [])]
        my_skills = [s.lower() for s in (my_profile.get("skills") or [])]

        if not my_seeks and not my_offers:
            return {
                "error": "Your profile has no seeks or offers defined.",
                "suggestion": "Update your profile with update_my_profile to add what you're seeking and offering."
            }

        # Get all other profiles
        profiles = load_profiles()
        matches = []

        for profile in profiles:
            if profile.get("id") == profile_id:
                continue  # Skip myself

            score = 0
            can_help_me = []  # They offer what I seek
            i_can_help = []   # They seek what I offer
            skill_overlap = []

            their_offers = [o.lower() for o in (profile.get("offers") or [])]
            their_seeks = [s.lower() for s in (profile.get("seeks") or [])]
            their_skills = [s.lower() for s in (profile.get("skills") or [])]

            # Check: their offers vs my seeks (they can help me)
            for my_seek in my_seeks:
                for their_offer in their_offers:
                    if my_seek in their_offer or their_offer in my_seek:
                        score += 5
                        can_help_me.append(f"oferuje '{their_offer}' - Ty szukasz '{my_seek}'")

            # Check: their seeks vs my offers (I can help them)
            for my_offer in my_offers:
                for their_seek in their_seeks:
                    if my_offer in their_seek or their_seek in my_offer:
                        score += 4
                        i_can_help.append(f"szuka '{their_seek}' - Ty oferujesz '{my_offer}'")

            # Check: skill overlap (collaboration potential)
            for my_skill in my_skills:
                for their_skill in their_skills:
                    if my_skill == their_skill:
                        score += 1
                        skill_overlap.append(their_skill)

            if score > 0:
                # Determine match type
                if can_help_me and i_can_help:
                    match_type = "🤝 Współpraca (obopólna)"
                elif can_help_me:
                    match_type = "🎯 Może Ci pomóc"
                elif i_can_help:
                    match_type = "💡 Możesz mu pomóc"
                else:
                    match_type = "🔗 Podobne skills"

                summary = format_profile_summary(profile)
                matches.append({
                    **summary,
                    "match_score": score,
                    "match_type": match_type,
                    "can_help_you": can_help_me[:3],  # Top 3 reasons
                    "you_can_help": i_can_help[:3],
                    "skill_overlap": skill_overlap[:3],
                    "email_verified": profile.get("email_verified", False)
                })

        # Sort by match score descending
        matches.sort(key=lambda x: x["match_score"], reverse=True)
        top_matches = matches[:max_results]

        # Build summary
        if top_matches:
            summary = f"Znaleziono {len(matches)} osób pasujących do Twojego profilu. Top {len(top_matches)}:"
        else:
            summary = "Nie znaleziono dopasowań. Spróbuj dodać więcej seeks/offers do profilu."

        return {
            "profile_id": profile_id,
            "your_seeks": my_profile.get("seeks") or [],
            "your_offers": my_profile.get("offers") or [],
            "total_matches": len(matches),
            "summary": summary,
            "matches": top_matches
        }




    @mcp.tool
    def search_by_category(category: str, value: str, user_id: str = "") -> dict:
        """
        Search profiles by specific category.

        Categories: industry, skills, seeking, offering

        Examples:
        - category="industry", value="e-commerce"
        - category="skills", value="python"
        - category="seeking", value="co-founder"

        Args:
            category: Category to search (industry, skills, seeking, offering)
            value: Value to search for
            user_id: Optional user ID for rate limiting (default: "anonymous")
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # Check rate limit for search
        search_user = user_id or "anonymous"
        rate_check = check_rate_limit(search_user, "search")
        if not rate_check.get("allowed", True):
            return {
                "error": "Rate limit exceeded.",
                "message": f"Too many searches ({rate_check['current']}) in the last hour. Max: {rate_check['max']}/hour.",
                "remaining": 0,
                "retry_after": "Try again in an hour."
            }

        profiles = load_profiles()
        value_lower = value.lower()
        matches = []

        for profile in profiles:
            matched = False

            if category == "industry":
                if any(value_lower in i.lower() for i in profile.get("industry") or []):
                    matched = True

            elif category == "skills":
                if any(value_lower in s.lower() for s in profile.get("skills") or []):
                    matched = True

            elif category == "seeking":
                if any(value_lower in s.lower() for s in profile.get("seeks") or []):
                    matched = True

            elif category == "offering":
                if any(value_lower in o.lower() for o in profile.get("offers") or []):
                    matched = True

            if matched:
                summary = format_profile_summary(profile)
                summary["assistant_endpoint"] = profile.get("assistant_endpoint")
                matches.append(summary)

        # Log search for analytics
        log_search(query=f"{category}:{value}", results_count=len(matches), search_type="category")

        # Log search appearances for profile stats
        result_ids = [m.get("id") for m in matches if m.get("id")]
        if result_ids:
            log_search_appearances(result_ids, f"{category}:{value}", user_id)

        return {
            "category": category,
            "value": value,
            "matches_found": len(matches),
            "results": matches
        }




    @mcp.tool
    def get_search_analytics(days: int = 7) -> dict:
        """
        Get search analytics for The Backroom.

        Shows:
        - Top searches (most frequent queries)
        - Search gaps (queries with 0 results - market opportunities!)
        - Total search count

        Args:
            days: Number of days to analyze (default: 7)
        """
        from datetime import datetime, timedelta

        client = get_supabase()
        if not client:
            return {"error": "Database not connected."}

        try:
            # Calculate date threshold
            since_date = (datetime.utcnow() - timedelta(days=days)).isoformat()

            # Top searches
            top_response = client.table("search_logs").select("query, results_count").gte(
                "created_at", since_date
            ).execute()

            # Count queries
            query_counts = {}
            gaps = {}

            for row in top_response.data or []:
                query = row.get("query", "").lower()
                results = row.get("results_count", 0)

                query_counts[query] = query_counts.get(query, 0) + 1

                if results == 0:
                    gaps[query] = gaps.get(query, 0) + 1

            # Sort by count
            top_searches = sorted(query_counts.items(), key=lambda x: x[1], reverse=True)[:10]
            top_gaps = sorted(gaps.items(), key=lambda x: x[1], reverse=True)[:10]

            return {
                "period_days": days,
                "total_searches": len(top_response.data or []),
                "top_searches": [{"query": q, "count": c} for q, c in top_searches],
                "search_gaps": [{"query": q, "count": c} for q, c in top_gaps],
                "insight": "Search gaps = what people want but you don't have. Market opportunity!"
            }

        except Exception as e:
            return {"error": f"Failed to get analytics: {str(e)}"}




