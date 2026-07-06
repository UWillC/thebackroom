"""
The Backroom - Profiles Module
"""

from utils import (
    get_supabase, get_supabase_with_auth, load_profiles, format_profile_summary,
    log_search, log_profile_view, log_search_appearances,
    check_rate_limit, get_rate_limit_status,
    validate_input, validate_profile_id, sanitize_text, sanitize_list,
    check_injection_and_sanitize, wrap_untrusted, LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
)


def register_tools(mcp):
    """Register profile tools with MCP server."""
    
    @mcp.tool
    def list_profiles() -> dict:
        """List all profiles in The Backroom network with 3-line summaries."""
        if not get_supabase():
            return {"error": "Database not connected. Set SUPABASE_URL and SUPABASE_KEY."}

        profiles = load_profiles()

        # Build summaries
        profile_list = []
        for p in profiles:
            summary = format_profile_summary(p)
            summary["industry"] = p.get("industry") or []
            profile_list.append(summary)

        return {
            "count": len(profiles),
            "profiles": profile_list
        }





    @mcp.tool
    def get_profile(profile_id: str) -> dict:
        """Get detailed profile by ID with formatted display."""
        if not get_supabase():
            return {"error": "Database not connected."}

        try:
            response = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
            if response.data:
                p = response.data[0]

                # Build quality score display
                score = p.get('quality_score')
                if score is not None:
                    if score >= 80:
                        score_display = f"⭐ {score}% (A)"
                    elif score >= 60:
                        score_display = f"📊 {score}% (B)"
                    elif score >= 40:
                        score_display = f"📊 {score}% (C)"
                    else:
                        score_display = f"⚠️ {score}% (D)"
                else:
                    score_display = "❓ Nie sprawdzono"

                # Log profile view for stats
                log_profile_view(profile_id)

                # Email verification status
                email_verified = p.get('email_verified', False)
                email_status = "✅ Zweryfikowany" if email_verified else "❌ Niezweryfikowany"

                # Build formatted display
                profile_display = f"""
    ╔══════════════════════════════════════════════╗
    ║ 👤 {p.get('name', 'Unknown')}
    ║ 📍 {p.get('location') or 'Nie podano'}
    ║ 📊 Jakość: {score_display} | Email: {email_status}
    ║
    ║ 💼 {p.get('role') or 'Nie podano'}
    ║ {p.get('bio') or ''}
    ║
    ║ 🏷️ Tagi: {', '.join(p.get('tags') or []) or 'Nie podano'}
    ║ 🛠️ Skills: {', '.join(p.get('skills') or []) or 'Nie podano'}
    ║
    ║ 🎁 OFERUJĘ: {', '.join(p.get('offers') or []) or 'Nie podano'}
    ║
    ║ 🆓 OFERTA FREE: {p.get('offer_free') or 'Nie podano'}
    ║    Warunek: {p.get('offer_condition') or 'Brak'}
    ║
    ║ 🔍 SZUKAM: {', '.join(p.get('seeks') or []) or 'Nie podano'}
    ║
    ║ 📧 Kontakt: {p.get('preferred_contact') or 'Nie podano'}
    ╚══════════════════════════════════════════════╝"""

                if p.get("bio"):
                    p["bio"] = wrap_untrusted(p["bio"], source=f"profile owner ({p.get('name', 'unknown')})")
                return {
                    "found": True,
                    "profile": p,
                    "profile_display": profile_display
                }
            return {"found": False, "error": f"Profile '{profile_id}' not found"}
        except Exception as e:
            return {"error": str(e)}





    @mcp.tool
    def register_profile(
        name: str,
        role: str,
        skills: str,
        offers: str,
        seeks: str,
        location: str = "",
        bio: str = "",
        tags: str = "",
        offer_free: str = "",
        offer_condition: str = "",
        email: str = "",
        linkedin_url: str = "",
        preferred_contact: str = "",
        industry: str = ""
    ) -> dict:
        """
        Register your profile in The Backroom network.

        This allows other AI assistants to find you and propose collaborations.

        Args:
            name: Your name or nickname (e.g., "Przemek", "SNOW")
            role: Your professional role (e.g., "Marketing Manager", "Python Developer")
            skills: Your skills, comma-separated (e.g., "Python, Ansible, Network Automation")
            offers: What you can offer others, comma-separated (e.g., "Python consulting, Code reviews")
            seeks: What you're looking for, comma-separated (e.g., "Beta testers, Marketing advice")
            location: Your location (e.g., "Warszawa, Polska", "Norfolk, VA, USA")
            bio: Short bio - 2-3 sentences about yourself
            tags: Keywords for search, comma-separated (e.g., "marketing, ai, automation")
            offer_free: One specific free offer (e.g., "15-min call about network automation")
            offer_condition: Condition for free offer (e.g., "przez LinkedIn DM", "dla członków społeczności")
            email: Optional contact email (shared when connection is accepted)
            linkedin_url: Your LinkedIn profile URL
            preferred_contact: Preferred contact method: "email", "linkedin", "skool"
            industry: Your industries, comma-separated (legacy field)

        Returns:
            Confirmation with your profile ID and full profile preview
        """
        if not get_supabase():
            return {"error": "Database not connected. Server configuration issue."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            name=("name", name, "Name", True),
            role=("role", role, "Role", True),
            skills=("message", skills, "Skills", True),
            offers=("message", offers, "Offers", True),
            seeks=("message", seeks, "Seeks", True),
            location=("location", location, "Location"),
            bio=("bio", bio, "Bio"),
            tags=("message", tags, "Tags"),
            offer_free=("offer", offer_free, "Free offer"),
            offer_condition=("offer", offer_condition, "Offer condition"),
            email=("email", email),
            linkedin_url=("url", linkedin_url, "LinkedIn URL"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Check for prompt injection in bio (primary risk field)
        if bio:
            is_safe, error_msg, _ = check_injection_and_sanitize(bio, "bio")
            if not is_safe:
                return {"error": error_msg}

        # Sanitize text inputs (with injection protection)
        name = sanitize_text(name, check_injection=True)
        role = sanitize_text(role, check_injection=True)
        location = sanitize_text(location, check_injection=True) if location else ""
        bio = sanitize_text(bio, check_injection=True) if bio else ""
        offer_free = sanitize_text(offer_free, check_injection=True) if offer_free else ""
        offer_condition = sanitize_text(offer_condition, check_injection=True) if offer_condition else ""

        # Parse comma-separated values into lists (with injection protection)
        skills_list = [sanitize_text(s, check_injection=True) for s in skills.split(",") if s.strip()]
        offers_list = [sanitize_text(o, check_injection=True) for o in offers.split(",") if o.strip()]
        seeks_list = [sanitize_text(s, check_injection=True) for s in seeks.split(",") if s.strip()]
        tags_list = [sanitize_text(t, check_injection=True) for t in tags.split(",") if t.strip()] if tags else []
        industry_list = [sanitize_text(i, check_injection=True) for i in industry.split(",") if i.strip()] if industry else []

        # Validate list lengths
        if len(skills_list) > MAX_SKILLS:
            return {"error": f"Too many skills ({len(skills_list)}). Maximum: {MAX_SKILLS}."}
        if len(offers_list) > MAX_OFFERS:
            return {"error": f"Too many offers ({len(offers_list)}). Maximum: {MAX_OFFERS}."}
        if len(tags_list) > MAX_TAGS:
            return {"error": f"Too many tags ({len(tags_list)}). Maximum: {MAX_TAGS}."}

        # Generate ID from name (lowercase, no spaces)
        profile_id = name.lower().replace(" ", "_").replace("-", "_")

        # Check if profile already exists
        try:
            existing = get_supabase().table("profiles").select("id").eq("id", profile_id).execute()
            if existing.data:
                return {
                    "error": f"Profile with ID '{profile_id}' already exists. Choose a different name or use update_my_profile to modify."
                }
        except Exception as e:
            return {"error": f"Error checking existing profile: {e}"}

        # Insert new profile
        try:
            profile_data = {
                "id": profile_id,
                "name": name,
                "role": role,
                "skills": skills_list,
                "offers": offers_list,
                "seeks": seeks_list,
            }

            # Add optional fields if provided
            if location:
                profile_data["location"] = location
            if bio:
                profile_data["bio"] = bio
            if tags_list:
                profile_data["tags"] = tags_list
            if offer_free:
                profile_data["offer_free"] = offer_free
            if offer_condition:
                profile_data["offer_condition"] = offer_condition
            if email:
                profile_data["email"] = email
            if linkedin_url:
                profile_data["linkedin_url"] = linkedin_url
            if preferred_contact:
                profile_data["preferred_contact"] = preferred_contact
            if industry_list:
                profile_data["industry"] = industry_list

            response = get_supabase().table("profiles").insert(profile_data).execute()

            if response.data:
                # Build profile display
                profile_display = f"""
    ╔══════════════════════════════════════════════╗
    ║           PROFIL DODANY DO THE BACKROOM       ║
    ╠══════════════════════════════════════════════╣
    ║ 👤 {name}
    ║ 📍 {location or 'Nie podano'}
    ║
    ║ 💼 {role}
    ║ {bio or ''}
    ║
    ║ 🏷️ Tagi: {', '.join(tags_list) if tags_list else 'Nie podano'}
    ║ 🛠️ Skills: {', '.join(skills_list)}
    ║
    ║ 🎁 OFERUJĘ: {', '.join(offers_list)}
    ║
    ║ 🆓 OFERTA FREE: {offer_free or 'Nie podano'}
    ║    Warunek: {offer_condition or 'Brak'}
    ║
    ║ 🔍 SZUKAM: {', '.join(seeks_list)}
    ║
    ║ 📧 Kontakt: {preferred_contact or 'Nie podano'}
    ╚══════════════════════════════════════════════╝"""

                return {
                    "success": True,
                    "message": f"Witaj w The Backroom, {name}!",
                    "profile_id": profile_id,
                    "profile_display": profile_display,
                    "profile": {
                        "id": profile_id,
                        "name": name,
                        "location": location,
                        "role": role,
                        "bio": bio,
                        "tags": tags_list,
                        "skills": skills_list,
                        "offers": offers_list,
                        "offer_free": offer_free,
                        "offer_condition": offer_condition,
                        "seeks": seeks_list,
                        "preferred_contact": preferred_contact
                    },
                    "next_steps": [
                        "Inni członkowie mogą Cię teraz znaleźć szukając współpracowników",
                        "Użyj 'find_collaborators' aby znaleźć ludzi pasujących do Twoich potrzeb",
                        "Użyj 'send_connection_request' aby połączyć się z kimś"
                    ],
                    "email_verification": {
                        "status": "pending" if email else "not_provided",
                        "message": "Sprawdź skrzynkę email - wysłaliśmy link weryfikacyjny!" if email else "Dodaj email aby otrzymywać powiadomienia",
                        "action": f"Użyj verify_email('{profile_id}', 'token_z_maila') aby zweryfikować" if email else "Użyj update_my_profile aby dodać email"
                    }
                }
            else:
                return {"error": "Failed to create profile. Please try again."}

        except Exception as e:
            return {"error": f"Error creating profile: {e}"}





    @mcp.tool
    def update_my_profile(
        profile_id: str,
        role: str = None,
        skills: str = None,
        offers: str = None,
        seeks: str = None,
        location: str = None,
        bio: str = None,
        tags: str = None,
        offer_free: str = None,
        offer_condition: str = None,
        email: str = None,
        linkedin_url: str = None,
        preferred_contact: str = None,
        industry: str = None
    ) -> dict:
        """
        Update your existing profile in The Backroom.

        Args:
            profile_id: Your profile ID (e.g., "snow", "przemek")
            role: New role (optional)
            skills: New skills, comma-separated (optional)
            offers: New offers, comma-separated (optional)
            seeks: New seeks, comma-separated (optional)
            location: New location (optional)
            bio: New bio (optional)
            tags: New tags, comma-separated (optional)
            offer_free: New free offer (optional)
            offer_condition: New offer condition (optional)
            email: New email (optional)
            linkedin_url: New LinkedIn URL (optional)
            preferred_contact: New preferred contact method (optional)
            industry: New industries, comma-separated (optional)

        Returns:
            Updated profile confirmation
        """
        if not get_supabase():
            return {"error": "Database not connected."}

        # === INPUT VALIDATION ===
        errors = validate_input(
            profile_id=("profile_id", profile_id, "Profile ID", True),
            role=("role", role, "Role"),
            skills=("message", skills, "Skills"),
            offers=("message", offers, "Offers"),
            seeks=("message", seeks, "Seeks"),
            location=("location", location, "Location"),
            bio=("bio", bio, "Bio"),
            tags=("message", tags, "Tags"),
            offer_free=("offer", offer_free, "Free offer"),
            offer_condition=("offer", offer_condition, "Offer condition"),
            email=("email", email),
            linkedin_url=("url", linkedin_url, "LinkedIn URL"),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

        # Check if profile exists
        try:
            existing = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
            if not existing.data:
                return {"error": f"Profile '{profile_id}' not found. Use register_profile to create one."}
        except Exception as e:
            return {"error": f"Error finding profile: {e}"}

        # Prompt-injection check on free-text fields (parity with register_profile / send_room_message)
        for _val, _name in [(role, "role"), (skills, "skills"), (offers, "offers"),
                            (seeks, "seeks"), (location, "location"), (bio, "bio"),
                            (offer_free, "offer_free"), (offer_condition, "offer_condition")]:
            if _val:
                is_safe, error_msg, _ = check_injection_and_sanitize(_val, _name)
                if not is_safe:
                    return {"error": error_msg}

        # Build update data (with sanitization + injection protection)
        update_data = {}

        if role:
            update_data["role"] = sanitize_text(role, check_injection=True)
        if skills:
            update_data["skills"] = [sanitize_text(s, check_injection=True) for s in skills.split(",") if s.strip()]
        if offers:
            update_data["offers"] = [sanitize_text(o, check_injection=True) for o in offers.split(",") if o.strip()]
        if seeks:
            update_data["seeks"] = [sanitize_text(s, check_injection=True) for s in seeks.split(",") if s.strip()]
        if location:
            update_data["location"] = sanitize_text(location, check_injection=True)
        if bio:
            update_data["bio"] = sanitize_text(bio, check_injection=True)
        if tags:
            update_data["tags"] = [t.strip() for t in tags.split(",") if t.strip()]
        if offer_free:
            update_data["offer_free"] = sanitize_text(offer_free, check_injection=True)
        if offer_condition:
            update_data["offer_condition"] = sanitize_text(offer_condition, check_injection=True)
        if email:
            update_data["email"] = email
        if linkedin_url:
            update_data["linkedin_url"] = linkedin_url
        if preferred_contact:
            update_data["preferred_contact"] = preferred_contact
        if industry:
            update_data["industry"] = [i.strip() for i in industry.split(",") if i.strip()]

        if not update_data:
            return {"error": "No fields to update. Provide at least one field."}

        try:
            response = get_supabase_with_auth().table("profiles").update(update_data).eq("id", profile_id).execute()

            if response.data:
                return {
                    "success": True,
                    "message": f"Profile '{profile_id}' updated successfully!",
                    "updated_fields": list(update_data.keys())
                }
            else:
                return {"error": "Failed to update profile."}

        except Exception as e:
            return {"error": f"Error updating profile: {e}"}





