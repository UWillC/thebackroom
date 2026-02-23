"""
The Backroom - Profiles Module
"""

from utils import (
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register profile tools with MCP server."""
    
    @mcp.tool
    def check_profile_quality(profile_id: str, save_to_profile: bool = False) -> dict:
        """
        AI-style evaluation of profile quality (0-100%).

        Inspired by AIBL Network - distinguishes "real value" from "generic fluff".

        Evaluates:
        - bio: Is it specific? Does it have examples/numbers?
        - skills: Are they specific or just buzzwords?
        - offer_free: Is it clear and valuable?
        - tags: Specific or generic?
        - seeks: Clear and realistic?

        Args:
            profile_id: Profile ID to evaluate (e.g., "snow")
            save_to_profile: If True, save score to profile (default: False)

        Returns:
            Quality score (0-100), grade (A-F), per-element feedback, suggestions
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # Get profile
        try:
            response = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
            if not response.data:
                return {"error": f"Profile '{profile_id}' not found."}
            profile = response.data[0]
        except Exception as e:
            return {"error": f"Error fetching profile: {e}"}

        # Evaluation criteria
        feedback = {}
        scores = {}

        # --- BIO (30% weight) ---
        bio = profile.get("bio") or ""
        bio_score = 0
        bio_suggestions = []

        if len(bio) >= 100:
            bio_score += 40  # Good length
        elif len(bio) >= 50:
            bio_score += 20
        else:
            bio_suggestions.append("Rozbuduj bio do min. 100 znaków")

        # Check for specifics (numbers, examples)
        import re
        if re.search(r'\d+', bio):  # Contains numbers
            bio_score += 30
        else:
            bio_suggestions.append("Dodaj konkretne liczby (np. '10 lat doświadczenia', '50+ projektów')")

        # Check for concrete words (not just buzzwords)
        concrete_indicators = ['zbudowałem', 'stworzyłem', 'zarządzam', 'prowadzę', 'pracuję', 'built', 'created', 'manage', 'lead', 'work']
        if any(word in bio.lower() for word in concrete_indicators):
            bio_score += 30
        else:
            bio_suggestions.append("Opisz konkretnie co robisz (np. 'Zbudowałem X', 'Prowadzę Y')")

        scores["bio"] = min(bio_score, 100)
        feedback["bio"] = {
            "score": scores["bio"],
            "suggestions": bio_suggestions if bio_suggestions else None
        }

        # --- SKILLS (20% weight) ---
        skills = profile.get("skills") or []
        skills_score = 0
        skills_suggestions = []

        if len(skills) >= 3:
            skills_score += 40
        elif len(skills) >= 1:
            skills_score += 20
        else:
            skills_suggestions.append("Dodaj min. 3 umiejętności")

        # Check for specificity (not just "Python" but "Python automation")
        generic_skills = ['python', 'javascript', 'marketing', 'sales', 'management', 'ai', 'automation']
        specific_count = sum(1 for s in skills if len(s.split()) > 1 or s.lower() not in generic_skills)

        if specific_count >= 2:
            skills_score += 60
        elif specific_count >= 1:
            skills_score += 30
        else:
            skills_suggestions.append("Sprecyzuj umiejętności (np. 'Network automation with Ansible' zamiast 'automation')")

        scores["skills"] = min(skills_score, 100)
        feedback["skills"] = {
            "score": scores["skills"],
            "suggestions": skills_suggestions if skills_suggestions else None
        }

        # --- OFFER_FREE (25% weight) ---
        offer_free = profile.get("offer_free") or ""
        offer_score = 0
        offer_suggestions = []

        if len(offer_free) >= 20:
            offer_score += 30
        elif len(offer_free) > 0:
            offer_score += 15
        else:
            offer_suggestions.append("Dodaj ofertę FREE (np. '15-min call o automatyzacji')")

        # Check for specificity
        if any(word in offer_free.lower() for word in ['min', 'call', 'review', 'audit', 'feedback', 'konsultacja', 'przegląd']):
            offer_score += 40
        else:
            offer_suggestions.append("Określ format oferty (np. 'call', 'review', 'audit')")

        # Check for condition
        offer_condition = profile.get("offer_condition") or ""
        if offer_condition:
            offer_score += 30
        else:
            offer_suggestions.append("Dodaj warunek oferty (np. 'przez LinkedIn DM')")

        scores["offer_free"] = min(offer_score, 100)
        feedback["offer_free"] = {
            "score": scores["offer_free"],
            "suggestions": offer_suggestions if offer_suggestions else None
        }

        # --- TAGS (15% weight) ---
        tags = profile.get("tags") or []
        tags_score = 0
        tags_suggestions = []

        if len(tags) >= 5:
            tags_score += 50
        elif len(tags) >= 3:
            tags_score += 30
        elif len(tags) >= 1:
            tags_score += 15
        else:
            tags_suggestions.append("Dodaj min. 5 tagów dla lepszej znajdywalności")

        # Check for specific tags
        generic_tags = ['ai', 'automation', 'business', 'tech', 'startup', 'marketing', 'sales']
        specific_tag_count = sum(1 for t in tags if t.lower() not in generic_tags)

        if specific_tag_count >= 3:
            tags_score += 50
        elif specific_tag_count >= 1:
            tags_score += 25
        else:
            tags_suggestions.append("Dodaj bardziej specyficzne tagi (np. 'cisco-ios-xe' zamiast tylko 'networking')")

        scores["tags"] = min(tags_score, 100)
        feedback["tags"] = {
            "score": scores["tags"],
            "suggestions": tags_suggestions if tags_suggestions else None
        }

        # --- SEEKS (10% weight) ---
        seeks = profile.get("seeks") or []
        seeks_score = 0
        seeks_suggestions = []

        if len(seeks) >= 2:
            seeks_score += 50
        elif len(seeks) >= 1:
            seeks_score += 25
        else:
            seeks_suggestions.append("Określ czego szukasz (min. 2 rzeczy)")

        # Check for specificity
        specific_seeks = sum(1 for s in seeks if len(s.split()) > 2)
        if specific_seeks >= 1:
            seeks_score += 50
        else:
            seeks_suggestions.append("Sprecyzuj czego szukasz (np. 'Beta testerzy dla narzędzia do automatyzacji' zamiast 'Beta testers')")

        scores["seeks"] = min(seeks_score, 100)
        feedback["seeks"] = {
            "score": scores["seeks"],
            "suggestions": seeks_suggestions if seeks_suggestions else None
        }

        # --- CALCULATE TOTAL SCORE ---
        weights = {"bio": 0.30, "skills": 0.20, "offer_free": 0.25, "tags": 0.15, "seeks": 0.10}
        total_score = int(sum(scores[k] * weights[k] for k in scores))

        # Grade
        if total_score >= 90:
            grade = "A"
            grade_label = "Excellent - serio wartość!"
        elif total_score >= 75:
            grade = "B"
            grade_label = "Good - solidny profil"
        elif total_score >= 60:
            grade = "C"
            grade_label = "Average - można poprawić"
        elif total_score >= 40:
            grade = "D"
            grade_label = "Below average - wymaga pracy"
        else:
            grade = "F"
            grade_label = "Poor - ogólniki, brak wartości"

        # Overall suggestion
        weakest = min(scores, key=scores.get)
        overall_suggestion = f"Zacznij od poprawy: {weakest.upper()}"

        # Collect all suggestions
        all_suggestions = []
        for key, fb in feedback.items():
            if fb["suggestions"]:
                all_suggestions.extend(fb["suggestions"])

        result = {
            "profile_id": profile_id,
            "quality_score": total_score,
            "grade": grade,
            "grade_label": grade_label,
            "feedback": feedback,
            "overall_suggestion": overall_suggestion,
            "top_3_improvements": all_suggestions[:3] if all_suggestions else ["Profil wygląda dobrze!"],
            "interpretation": {
                "90-100": "A - Serio wartość, konkretny, wiarygodny",
                "75-89": "B - Dobry profil, drobne poprawki",
                "60-74": "C - Przeciętny, wymaga dopracowania",
                "40-59": "D - Słaby, dużo ogólników",
                "0-39": "F - Handlowe pierdololo, brak wartości"
            }
        }

        # Save to profile if requested
        if save_to_profile:
            try:
                from datetime import datetime
                update_data = {
                    "quality_score": total_score,
                    "quality_feedback": str(all_suggestions[:3]),
                    "quality_checked_at": datetime.utcnow().isoformat()
                }
                get_supabase().table("profiles").update(update_data).eq("id", profile_id).execute()
                result["saved_to_profile"] = True
            except Exception as e:
                result["saved_to_profile"] = False
                result["save_error"] = str(e)

        return result





    @mcp.tool
    def get_profile_stats(profile_id: str, days: int = 30) -> dict:
        """
        Get engagement stats for a profile.

        Shows:
        - Profile views (how many times someone viewed your profile)
        - Search appearances (how many times you appeared in results)
        - Match appearances (how many times you were a match)
        - Connection stats (sent, received, accepted)
        - Engagement score (weighted total)

        Args:
            profile_id: Profile ID to get stats for
            days: Number of days to analyze (default: 30)
        """
        client = get_supabase()
        if not client:
            return {"error": "Database not connected."}

        try:
            response = client.rpc("get_profile_stats", {
                "p_profile_id": profile_id,
                "p_days": days
            }).execute()

            if response.data:
                data = response.data
                stats = data.get("stats", {})

                # Build visual stats
                stats_visual = f"""
    ╔══════════════════════════════════════════════╗
    ║     📊 PROFILE STATS: {profile_id[:20]}
    ║     (ostatnie {days} dni)
    ╠══════════════════════════════════════════════╣
    ║ 👀 Wyświetlenia profilu:    {stats.get('profile_views', 0):>5}
    ║ 🔍 Pojawienia w wynikach:   {stats.get('search_appearances', 0):>5}
    ║ 🎯 Pojawienia w matchach:   {stats.get('match_appearances', 0):>5}
    ╠══════════════════════════════════════════════╣
    ║ 📤 Wysłane requesty:        {stats.get('connections_sent', 0):>5}
    ║ 📥 Otrzymane requesty:      {stats.get('connections_received', 0):>5}
    ║ ✅ Zaakceptowane:           {stats.get('connections_accepted', 0):>5}
    ╠══════════════════════════════════════════════╣
    ║ ⭐ ENGAGEMENT SCORE:        {data.get('engagement_score', 0):>5}
    ╚══════════════════════════════════════════════╝"""

                return {
                    "profile_id": profile_id,
                    "period_days": days,
                    "stats": stats,
                    "engagement_score": data.get("engagement_score", 0),
                    "recent_viewers": data.get("recent_viewers", []),
                    "stats_visual": stats_visual,
                    "tips": {
                        "low_views": "Uzupełnij profil, dodaj bio i skills",
                        "low_searches": "Dodaj więcej tagów i keywords",
                        "low_connections": "Bądź aktywny - szukaj i wysyłaj requesty"
                    }
                }
            else:
                return {
                    "profile_id": profile_id,
                    "message": "No stats yet. Your profile is new!",
                    "stats": {}
                }

        except Exception as e:
            if "does not exist" in str(e) or "function" in str(e).lower():
                return {
                    "error": "Profile stats not set up yet.",
                    "setup": "Run profile_stats.sql in Supabase to enable."
                }
            return {"error": f"Failed to get stats: {str(e)}"}





    @mcp.tool
    def send_weekly_matches_email(profile_id: str = "") -> dict:
        """
        Send weekly matches email to a user or all eligible users.

        This is normally run automatically every Monday at 9 AM UTC,
        but can be triggered manually for testing.

        Args:
            profile_id: Specific profile to send to, or empty for ALL eligible users

        Example:
            send_weekly_matches_email("snow") → sends to snow only
            send_weekly_matches_email() → sends to ALL eligible users
        """
        client = get_supabase()
        if not client:
            return {"error": "Database not connected."}

        try:
            if profile_id:
                # Send to specific user
                response = client.rpc("send_weekly_matches_email", {
                    "p_profile_id": profile_id
                }).execute()

                if response.data:
                    result = response.data
                    if result.get("success"):
                        return {
                            "success": True,
                            "message": f"Weekly matches email sent to {profile_id}!",
                            "matches_sent": result.get("matches_sent", 0)
                        }
                    else:
                        return {
                            "success": False,
                            "reason": result.get("reason", "unknown"),
                            "message": {
                                "no_email": "Profile has no email address",
                                "email_not_verified": "Email not verified yet",
                                "notifications_disabled": "User disabled notifications",
                                "no_matches": "No matches found for this profile"
                            }.get(result.get("reason"), "Could not send email")
                        }
                return {"error": "No response from function"}
            else:
                # Send to ALL eligible users
                response = client.rpc("send_all_weekly_matches_emails").execute()

                if response.data:
                    result = response.data
                    return {
                        "success": True,
                        "message": f"Weekly emails sent to {result.get('sent', 0)} users",
                        "sent": result.get("sent", 0),
                        "skipped": result.get("skipped", 0),
                        "details": result.get("details", [])
                    }
                return {"error": "No response from function"}

        except Exception as e:
            if "does not exist" in str(e) or "function" in str(e).lower():
                return {
                    "error": "Weekly matches email not set up yet.",
                    "setup": "Run weekly_matches_email.sql in Supabase to enable."
                }
            return {"error": f"Failed to send: {str(e)}"}





