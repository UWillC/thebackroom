"""
The Backroom - Utils Module
"""

from .validation import (
    LIMITS,
    MAX_TAGS,
    MAX_SKILLS,
    MAX_OFFERS,
    detect_prompt_injection,
    sanitize_for_injection,
    check_injection_and_sanitize,
    validate_length,
    validate_email,
    validate_url,
    validate_slug,
    validate_uuid,
    sanitize_text,
    sanitize_list,
    validate_profile_id,
    validate_required,
    validate_input,
)

from .supabase import (
    SUPABASE_URL,
    SUPABASE_KEY,
    get_supabase,
    get_supabase_with_auth,
    load_profiles,
    format_profile_summary,
    log_search,
    log_profile_view,
    log_search_appearances,
)

from .rate_limiting import (
    RATE_LIMITS,
    check_rate_limit,
    get_rate_limit_status,
)
