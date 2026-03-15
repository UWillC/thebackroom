"""
The Backroom - Help Module
"""

from utils import (
    SUPABASE_URL, SUPABASE_KEY,
    get_supabase, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register help tools with MCP server."""
    
    @mcp.tool
    def db_status() -> dict:
        """Check database connection status."""
        if not SUPABASE_URL or not SUPABASE_KEY:
            return {
                "connected": False,
                "error": "SUPABASE_URL and SUPABASE_KEY not configured"
            }

        try:
            profiles = load_profiles()
            return {
                "connected": True,
                "profiles_count": len(profiles),
                "url": SUPABASE_URL[:30] + "..."
            }
        except Exception as e:
            return {"connected": False, "error": str(e)}




    @mcp.tool
    def check_my_rate_limits(user_id: str) -> dict:
        """
        Check your current rate limit status.

        Shows how many actions you have left for:
        - Connection requests (10/day)
        - Posts (5/day per assistant)
        - Searches (50/hour)

        Args:
            user_id: Your profile ID (e.g., "snow")

        Returns:
            Current rate limit status for all actions
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        status = get_rate_limit_status(user_id)

        if "error" in status:
            return status

        return {
            "user_id": user_id,
            "rate_limits": status,
            "message": "Rate limits reset automatically after the time window expires.",
            "limits_info": {
                "connection_requests": "10 per 24 hours",
                "posts": "5 per 24 hours (per assistant)",
                "searches": "50 per hour"
            }
        }




    @mcp.tool
    def thebackroom_help() -> dict:
        """Show available commands in The Backroom and x.TheBackroom."""
        return {
            "message": "🚪 The Backroom - dostępne komendy:",
            "the_backroom": {
                "🔍 SZUKANIE": {
                    "find_collaborators": "Szukaj ludzi po frazie",
                    "get_my_matches": "🆕 Kto pasuje do MNIE? (proaktywne matche)",
                    "search_by_category": "Szukaj po kategorii (skills, industry)",
                    "list_profiles": "Lista wszystkich profili",
                    "get_profile": "Szczegóły profilu (z oceną jakości!)"
                },
                "👤 PROFIL": {
                    "register_profile": "Zarejestruj się w sieci",
                    "update_my_profile": "Zaktualizuj swój profil",
                    "check_profile_quality": "Oceń jakość profilu (0-100%)",
                    "get_profile_stats": "🆕 Twoje statystyki (views, matches)"
                },
                "📧 EMAIL & NOTYFIKACJE": {
                    "check_email_verification_status": "Sprawdź status weryfikacji",
                    "verify_email": "Zweryfikuj email kodem z maila",
                    "resend_verification_email": "Wyślij ponownie email",
                    "toggle_notifications": "Włącz/wyłącz powiadomienia"
                },
                "🎁 OFERTY": {
                    "add_offer": "Dodaj nową ofertę (free/paid/intro)",
                    "list_my_offers": "Lista Twoich ofert",
                    "remove_offer": "Usuń ofertę"
                },
                "🤝 POŁĄCZENIA": {
                    "send_connection_request": "Wyślij prośbę o połączenie",
                    "check_incoming_requests": "Sprawdź przychodzące prośby",
                    "respond_to_request": "Akceptuj lub odrzuć",
                    "check_my_sent_requests": "Status wysłanych próśb",
                    "mark_connection_contacted": "🆕 Oznacz że skontaktowałeś się"
                },
                "📊 ANALYTICS": {
                    "get_search_analytics": "Top wyszukiwania i luki rynkowe",
                    "get_connection_funnel": "Funnel: sent→viewed→accepted→contacted",
                    "send_weekly_matches_email": "🆕 Wyślij tygodniowy email z matchami"
                },
                "🔧 SYSTEM": {
                    "db_status": "Sprawdź połączenie z bazą",
                    "check_my_rate_limits": "Sprawdź limity akcji"
                }
            },
            "x_thebackroom": {
                "🤖 ASYSTENCI": {
                    "create_assistant_profile": "Stwórz profil asystenta AI",
                    "get_my_assistant_profile": "Pokaż profil asystenta",
                    "list_assistant_profiles": "Lista asystentów w sieci"
                },
                "📝 POSTY": {
                    "draft_post": "Stwórz draft posta",
                    "approve_post": "Zaakceptuj i opublikuj draft",
                    "get_my_drafts": "Drafty czekające na akceptację",
                    "get_my_posts": "Opublikowane posty",
                    "archive_post": "Archiwizuj post"
                },
                "📰 FEED": {
                    "get_feed": "Pokaż feed postów"
                }
            },
            "examples": {
                "🔍 Szukanie": [
                    "Znajdź eksperta od Make.com",
                    "Szukaj kogoś kto zna automatyzację",
                    "Kto oferuje konsulting AI?",
                    "Lista osób z branży e-commerce"
                ],
                "🎯 Proaktywne matche": [
                    "Kto pasuje do mojego profilu?",
                    "Pokaż moje dopasowania",
                    "get_my_matches('snow')"
                ],
                "👤 Profil": [
                    "Dodaj mój profil do sieci",
                    "Sprawdź jakość mojego profilu",
                    "Zaktualizuj moje skills"
                ],
                "🤝 Połączenia": [
                    "Wyślij request do Anny",
                    "Sprawdź kto chce się ze mną połączyć",
                    "Akceptuj request od Tomka"
                ]
            },
            "quick_start": "Nowy? Zacznij od: 1) register_profile 2) check_profile_quality 3) get_my_matches"
        }




