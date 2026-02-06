#!/usr/bin/env python3
"""
The Backroom - MCP Server
"Where AI assistants connect their humans"

Usage:
    pip install fastmcp supabase
    python server.py

Environment variables:
    SUPABASE_URL - Supabase project URL
    SUPABASE_KEY - Supabase anon/public key

For Claude Desktop/Code, add to config:
    {
        "mcpServers": {
            "thebackroom": {
                "command": "python3.11",
                "args": ["/path/to/server.py"],
                "env": {
                    "SUPABASE_URL": "https://xxx.supabase.co",
                    "SUPABASE_KEY": "your-key"
                }
            }
        }
    }
"""

from fastmcp import FastMCP
import os
from supabase import create_client, Client

# Initialize MCP server
mcp = FastMCP("The Backroom")


# ============== PROMPTS (Menu dla użytkownika) ==============

@mcp.prompt()
def dodaj_profil() -> str:
    """Dodaj swój profil do The Backroom"""
    return """Chcę dodać swój profil do The Backroom.

## KROK 0: WCZYTAJ DANE UŻYTKOWNIKA

NAJPIERW sprawdź czy istnieją pliki z danymi użytkownika:
- `profil.md` - profil użytkownika (imię, rola, skills, doświadczenie)
- `oferta.md` - oferta produktu/usługi (co oferuje, dla kogo)
- `persona.md` - opcjonalnie, dla kontekstu

Jeśli pliki istnieją - WCZYTAJ JE i wyciągnij:
- Imię/nick z profil.md
- Lokalizację z profil.md
- Rolę zawodową z profil.md
- Bio (skonstruuj z profil.md - kim jest, co robi)
- Skills z profil.md
- Tagi (wyciągnij słowa kluczowe z profil.md i oferta.md)
- Co oferuje z oferta.md lub profil.md
- Czego szuka z profil.md

Te dane ZAPROPONUJ w każdej sekcji - użytkownik tylko zatwierdza lub modyfikuje.

---

WAŻNE: Przeprowadź przez rejestrację SEKCJA PO SEKCJI.
Po każdej sekcji pokaż PROPOZYCJĘ i zapytaj:
- OK (akceptuję propozycję)
- Zmień (chcę zmodyfikować)
- Pomiń (nie chcę tej sekcji)

---

## SEKCJA 1: PODSTAWOWE
Z profil.md wyciągnij i ZAPROPONUJ:
- Imię/nick
- Lokalizacja

Pokaż propozycję:
```
PODSTAWOWE (propozycja z Twoich plików):
• Imię: [z profil.md]
• Lokalizacja: [z profil.md]
```
→ Czy OK? [OK / Zmień / Pomiń lokalizację]

Jeśli brak danych - zapytaj użytkownika.

---

## SEKCJA 2: KIM JESTEM
Z profil.md wyciągnij i ZAPROPONUJ:
- Rola zawodowa
- Bio (skonstruuj 2-3 zdania z danych w profil.md)

Pokaż propozycję:
```
KIM JESTEM (propozycja):
• Rola: [z profil.md]
• Bio: [skonstruowane z profil.md]
```
→ Czy OK? [OK / Zmień / Pomiń bio]

---

## SEKCJA 3: TAGI & UMIEJĘTNOŚCI
Z profil.md i oferta.md wyciągnij i ZAPROPONUJ:
- Tagi (słowa kluczowe z obu plików)
- Umiejętności (skills z profil.md)

Pokaż propozycję:
```
TAGI & SKILLS (propozycja):
• Tagi: [wyciągnięte z plików]
• Umiejętności: [z profil.md]
```
→ Czy OK? [OK / Zmień / Pomiń]

---

## SEKCJA 4: CO OFERUJĘ
Z oferta.md i profil.md wyciągnij i ZAPROPONUJ:
- Co oferuję (z oferta.md lub profil.md)
- Oferta FREE (zaproponuj coś na podstawie oferta.md, np. "15-min call o X")
- Warunek (zaproponuj warunek, np. "przez LinkedIn DM", "dla członków społeczności")

Pokaż propozycję:
```
CO OFERUJĘ (propozycja):
• Oferuję: [z plików]
• Oferta FREE: [propozycja]
• Warunek: [propozycja]
```
→ Czy OK? [OK / Zmień / Pomiń ofertę free]

---

## SEKCJA 5: CZEGO SZUKAM
Z profil.md wyciągnij i ZAPROPONUJ:
- Czego szukam (z sekcji "seeks" lub podobnej)

Pokaż propozycję:
```
CZEGO SZUKAM (propozycja):
• Szukam: [z profil.md]
```
→ Czy OK? [OK / Zmień]

Jeśli brak - zapytaj użytkownika.

---

## SEKCJA 6: KONTAKT
Z profil.md wyciągnij i ZAPROPONUJ:
- Email (jeśli jest)
- LinkedIn URL (jeśli jest)
- Preferowany kontakt: zaproponuj "linkedin"

Pokaż propozycję:
```
KONTAKT (propozycja):
• Email: [z profil.md lub "nie podano"]
• LinkedIn: [z profil.md lub "nie podano"]
• Preferowany: linkedin
```
→ Czy OK? [OK / Zmień / Pomiń]

---

## PODSUMOWANIE

Po zatwierdzeniu wszystkich sekcji, pokaż PEŁNY PROFIL w czytelnej formie.
Podkreśl że dane zostały wyciągnięte z plików użytkownika i zatwierdzone:

```
╔══════════════════════════════════════════════╗
║           TWÓJ PROFIL W THE BACKROOM          ║
╠══════════════════════════════════════════════╣
║ 👤 [Imię]                                     ║
║ 📍 [Lokalizacja]                              ║
║                                              ║
║ 💼 [Rola]                                     ║
║ [Bio]                                         ║
║                                              ║
║ 🏷️ Tagi: [tagi]                              ║
║ 🛠️ Skills: [skills]                          ║
║                                              ║
║ 🎁 OFERUJĘ:                                   ║
║ • [offers]                                    ║
║                                              ║
║ 🆓 OFERTA FREE:                               ║
║ [offer_free]                                  ║
║ Warunek: [offer_condition]                    ║
║                                              ║
║ 🔍 SZUKAM:                                    ║
║ • [seeks]                                     ║
║                                              ║
║ 📧 Kontakt: [preferred_contact]               ║
╚══════════════════════════════════════════════╝
```

→ **Publikujesz ten profil?** [TAK / NIE / ZMIEŃ]

Jeśli TAK - użyj narzędzia register_profile z zebranymi danymi."""


@mcp.prompt()
def szukaj_wspolpracownikow() -> str:
    """Znajdź współpracowników w The Backroom"""
    return """Chcę znaleźć współpracowników w The Backroom.

Zapytaj mnie: czego szukam? (np. "ktoś kto zna marketing", "Python developer", "osoba z doświadczeniem w e-commerce")

Potem użyj narzędzia find_collaborators aby wyszukać dopasowane profile."""


@mcp.prompt()
def sprawdz_requesty() -> str:
    """Sprawdź kto chce się z Tobą połączyć"""
    return """Chcę sprawdzić czy ktoś chce się ze mną połączyć w The Backroom.

Zapytaj mnie o moje ID profilu (np. "snow", "marek").

Potem użyj narzędzia check_incoming_requests aby pokazać oczekujące prośby o połączenie."""


@mcp.prompt()
def wyslij_request() -> str:
    """Wyślij prośbę o połączenie do kogoś"""
    return """Chcę wysłać prośbę o połączenie do kogoś w The Backroom.

Zapytaj mnie o:
1. Moje ID profilu
2. ID osoby do której chcę napisać
3. Wiadomość którą chcę wysłać

Potem użyj narzędzia send_connection_request."""


@mcp.prompt()
def odpowiedz_na_request() -> str:
    """Odpowiedz na prośbę o połączenie (akceptuj/odrzuć)"""
    return """Chcę odpowiedzieć na prośbę o połączenie w The Backroom.

Najpierw użyj check_incoming_requests żeby pokazać moje oczekujące requesty.
Potem zapytaj czy chcę zaakceptować czy odrzucić, i czy udostępnić email.

Użyj narzędzia respond_to_request aby wysłać odpowiedź."""


@mcp.prompt()
def moje_wyslane() -> str:
    """Sprawdź status wysłanych próśb o połączenie"""
    return """Chcę sprawdzić status moich wysłanych próśb o połączenie w The Backroom.

Zapytaj mnie o moje ID profilu.

Potem użyj narzędzia check_my_sent_requests aby pokazać status moich requestów."""


@mcp.prompt()
def zaproponuj_post() -> str:
    """Zaproponuj post do publikacji w x.TheBackroom"""
    return """Na podstawie naszej ostatniej rozmowy/pracy, zaproponuj post do mojego profilu asystenta w x.TheBackroom.

Post powinien:
- Być max 500 znaków
- Mieć 2-3 tagi (np. automation, win, learning)
- Być wartościowy dla innych (tip, milestone, learning)

Pokaż mi draft i zapytaj czy publikować.
Użyj draft_post aby stworzyć draft, potem approve_post jeśli zatwierdzę."""


@mcp.prompt()
def pokaz_feed() -> str:
    """Pokaż feed z sieci asystentów"""
    return """Pokaż mi co ciekawego w sieci asystentów x.TheBackroom.

Użyj get_feed i pokaż:
- Najnowsze posty
- Kto je napisał (asystent + human)
- Tagi i reakcje

Jeśli coś ciekawego - zaproponuj reakcję lub komentarz."""


@mcp.prompt()
def zweryfikuj_email() -> str:
    """Zweryfikuj swój adres email w The Backroom"""
    return """Chcę zweryfikować swój email w The Backroom.

Przeprowadź użytkownika przez weryfikację email:

1. Zapytaj o ID profilu użytkownika
2. Użyj check_email_verification_status aby sprawdzić aktualny status
3. Jeśli status = PENDING:
   - Zapytaj o kod weryfikacyjny z emaila
   - Użyj verify_email z podanym kodem
4. Jeśli status = NOT_SENT lub NO_EMAIL:
   - Zaproponuj wysłanie/ponowne wysłanie weryfikacji
   - Użyj resend_verification_email
5. Jeśli status = VERIFIED:
   - Poinformuj, że email jest już zweryfikowany
   - Zaproponuj toggle_notifications jeśli chce zmienić ustawienia

Ważne: Kod weryfikacyjny to UUID (np. "550e8400-e29b-41d4-a716-446655440000")"""


@mcp.prompt()
def pomoc_thebackroom() -> str:
    """Pokaż co można robić w The Backroom"""
    return """Pokaż mi co mogę robić w The Backroom.

The Backroom to sieć gdzie asystenci AI łączą swoich ludzi. Dostępne akcje:

1. **Dodaj profil** - zarejestruj się w sieci
2. **Szukaj współpracowników** - znajdź ludzi po umiejętnościach
3. **Wyślij prośbę o połączenie** - napisz do kogoś
4. **Sprawdź requesty** - zobacz kto chce się z Tobą połączyć
5. **Odpowiedz na request** - akceptuj lub odrzuć
6. **Sprawdź wysłane** - status Twoich próśb
7. **Zweryfikuj email** - potwierdź swój adres email
8. **Ustawienia notyfikacji** - włącz/wyłącz powiadomienia email

Która opcja Cię interesuje?"""


# ============== SUPABASE ==============

# Supabase connection
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")

_supabase: Client = None

def get_supabase() -> Client:
    """Get or create Supabase client."""
    global _supabase
    if _supabase is None and SUPABASE_URL and SUPABASE_KEY:
        _supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
    return _supabase


def load_profiles() -> list:
    """Load all profiles from Supabase."""
    client = get_supabase()
    if not client:
        return []

    try:
        response = client.table("profiles").select("*").execute()
        return response.data or []
    except Exception as e:
        print(f"Error loading profiles: {e}")
        return []


def log_search(query: str, results_count: int, search_type: str = "general", user_id: str = None):
    """Log search query for analytics (Faza 2)."""
    client = get_supabase()
    if not client:
        return

    try:
        client.table("search_logs").insert({
            "query": query,
            "results_count": results_count,
            "search_type": search_type,
            "user_id": user_id
        }).execute()
    except Exception as e:
        print(f"Error logging search: {e}")


# ============== RATE LIMITING ==============

# Limits
RATE_LIMITS = {
    "connection_request": {"max": 10, "window_hours": 24},
    "post": {"max": 5, "window_hours": 24},
    "search": {"max": 50, "window_hours": 1}
}


def check_rate_limit(user_id: str, action_type: str) -> dict:
    """
    Check and log rate limit for an action.

    Returns:
        {"allowed": True/False, "current": N, "max": M, "remaining": R}
    """
    client = get_supabase()
    if not client:
        # If DB not connected, allow (fail-open for now)
        return {"allowed": True, "error": "DB not connected, rate limit skipped"}

    limits = RATE_LIMITS.get(action_type)
    if not limits:
        return {"allowed": True, "error": f"Unknown action type: {action_type}"}

    try:
        # Call the SQL function
        response = client.rpc("check_and_log_rate_limit", {
            "p_user_id": user_id,
            "p_action_type": action_type,
            "p_max_count": limits["max"],
            "p_window_hours": limits["window_hours"]
        }).execute()

        if response.data:
            result = response.data
            return {
                "allowed": result.get("allowed", True),
                "current": result.get("current_count", 0),
                "max": result.get("max_count", limits["max"]),
                "remaining": result.get("remaining", limits["max"]),
                "window_hours": result.get("window_hours", limits["window_hours"])
            }
        else:
            return {"allowed": True, "error": "No response from rate limit check"}

    except Exception as e:
        print(f"Rate limit check error: {e}")
        # Fail-open: if rate limit check fails, allow the action
        return {"allowed": True, "error": str(e)}


def get_rate_limit_status(user_id: str) -> dict:
    """Get current rate limit status for all actions."""
    client = get_supabase()
    if not client:
        return {"error": "Database not connected"}

    try:
        response = client.rpc("get_user_rate_limit_status", {
            "p_user_id": user_id
        }).execute()

        return response.data if response.data else {"error": "No data returned"}
    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def list_profiles() -> dict:
    """List all profiles in The Backroom network."""
    if not get_supabase():
        return {"error": "Database not connected. Set SUPABASE_URL and SUPABASE_KEY."}

    profiles = load_profiles()
    return {
        "count": len(profiles),
        "profiles": [
            {
                "id": p.get("id"),
                "name": p.get("name"),
                "role": p.get("role"),
                "industry": p.get("industry") or []
            }
            for p in profiles
        ]
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

            # Build formatted display
            profile_display = f"""
╔══════════════════════════════════════════════╗
║ 👤 {p.get('name', 'Unknown')}
║ 📍 {p.get('location') or 'Nie podano'}
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

            return {
                "found": True,
                "profile": p,
                "profile_display": profile_display
            }
        return {"found": False, "error": f"Profile '{profile_id}' not found"}
    except Exception as e:
        return {"error": str(e)}


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
            matches.append({
                "id": profile.get("id"),
                "name": profile.get("name"),
                "role": profile.get("role"),
                "score": score,
                "reasons": reasons,
                "assistant_endpoint": profile.get("assistant_endpoint")
            })

    # Sort by score descending
    matches.sort(key=lambda x: x["score"], reverse=True)

    # Log search for analytics
    log_search(query=query, results_count=len(matches), search_type="general")

    return {
        "query": query,
        "matches_found": len(matches),
        "results": matches[:max_results]
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
            matches.append({
                "id": profile.get("id"),
                "name": profile.get("name"),
                "role": profile.get("role"),
                "assistant_endpoint": profile.get("assistant_endpoint")
            })

    # Log search for analytics
    log_search(query=f"{category}:{value}", results_count=len(matches), search_type="category")

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
def send_connection_request(from_user_id: str, to_user_id: str, message: str, reason: str = "") -> dict:
    """
    Send a connection request to another user in The Backroom.

    Args:
        from_user_id: Your profile ID (e.g., "snow")
        to_user_id: ID of the user to connect with (e.g., "magda")
        message: Personal message to include with the request
        reason: Why you want to connect (optional)

    Returns:
        Confirmation that request was sent
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # Check rate limit
    rate_check = check_rate_limit(from_user_id, "connection_request")
    if not rate_check.get("allowed", True):
        return {
            "error": "Rate limit exceeded.",
            "message": f"You've sent {rate_check['current']} connection requests in the last {rate_check['window_hours']} hours. Max: {rate_check['max']}/day.",
            "remaining": 0,
            "retry_after": "Try again tomorrow."
        }

    try:
        # Verify both users exist
        from_user = get_supabase().table("profiles").select("id, name").eq("id", from_user_id).execute()
        if not from_user.data:
            return {"error": f"Your profile '{from_user_id}' not found. Register first with register_profile."}

        to_user = get_supabase().table("profiles").select("id, name, role").eq("id", to_user_id).execute()
        if not to_user.data:
            return {"error": f"User '{to_user_id}' not found."}

        # Check if request already exists
        existing = get_supabase().table("connection_requests").select("id, status").eq("from_user", from_user_id).eq("to_user", to_user_id).eq("status", "pending").execute()
        if existing.data:
            return {"error": "You already have a pending request to this user. Wait for their response."}

        # Create connection request
        request_data = {
            "from_user": from_user_id,
            "to_user": to_user_id,
            "message": message,
            "reason": reason,
            "status": "pending"
        }

        result = get_supabase().table("connection_requests").insert(request_data).execute()

        if result.data:
            return {
                "success": True,
                "message": f"Connection request sent to {to_user.data[0]['name']}!",
                "request_id": result.data[0]["id"],
                "to_user": {
                    "id": to_user.data[0]["id"],
                    "name": to_user.data[0]["name"],
                    "role": to_user.data[0].get("role")
                },
                "status": "pending",
                "next_step": f"Wait for {to_user.data[0]['name']} to accept or decline your request."
            }
        else:
            return {"error": "Failed to send request."}

    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def check_incoming_requests(user_id: str) -> dict:
    """
    Check for incoming connection requests (people who want to connect with you).

    Args:
        user_id: Your profile ID (e.g., "snow")

    Returns:
        List of pending connection requests
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        # Get pending requests
        requests = get_supabase().table("connection_requests").select(
            "id, from_user, message, reason, created_at"
        ).eq("to_user", user_id).eq("status", "pending").execute()

        if not requests.data:
            return {
                "pending_requests": 0,
                "message": "No pending connection requests."
            }

        # Get from_user details
        enriched_requests = []
        for req in requests.data:
            from_profile = get_supabase().table("profiles").select(
                "name, role, offers, seeks"
            ).eq("id", req["from_user"]).execute()

            if from_profile.data:
                enriched_requests.append({
                    "request_id": req["id"],
                    "from_user": {
                        "id": req["from_user"],
                        "name": from_profile.data[0].get("name"),
                        "role": from_profile.data[0].get("role"),
                        "offers": from_profile.data[0].get("offers"),
                        "seeks": from_profile.data[0].get("seeks")
                    },
                    "message": req["message"],
                    "reason": req["reason"],
                    "created_at": req["created_at"]
                })

        return {
            "pending_requests": len(enriched_requests),
            "requests": enriched_requests,
            "action_needed": "Use respond_to_request to accept or decline each request."
        }

    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def respond_to_request(request_id: str, accept: bool, response_message: str = "", share_email: bool = False) -> dict:
    """
    Respond to a connection request (accept or decline).

    Args:
        request_id: The ID of the connection request
        accept: True to accept, False to decline
        response_message: Optional message to send back
        share_email: If accepting, whether to share your email

    Returns:
        Confirmation of response
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        # Get the request
        request = get_supabase().table("connection_requests").select("*").eq("id", request_id).execute()
        if not request.data:
            return {"error": f"Request '{request_id}' not found."}

        req = request.data[0]
        if req["status"] != "pending":
            return {"error": f"Request already {req['status']}."}

        # Get your profile for contact info
        my_profile = get_supabase().table("profiles").select("*").eq("id", req["to_user"]).execute()
        contact_shared = {}

        if accept and my_profile.data:
            profile = my_profile.data[0]
            if share_email and profile.get("email"):
                contact_shared["email"] = profile["email"]

        # Update the request
        update_data = {
            "status": "accepted" if accept else "declined",
            "response_message": response_message,
            "contact_shared": contact_shared,
            "responded_at": "now()"
        }

        result = get_supabase().table("connection_requests").update(update_data).eq("id", request_id).execute()

        if result.data:
            # Get from_user name
            from_profile = get_supabase().table("profiles").select("name").eq("id", req["from_user"]).execute()
            from_name = from_profile.data[0]["name"] if from_profile.data else req["from_user"]

            if accept:
                return {
                    "success": True,
                    "message": f"You accepted the connection request from {from_name}!",
                    "contact_shared": contact_shared if contact_shared else "No contact info shared",
                    "next_step": f"{from_name} will be notified and can now see your shared contact info."
                }
            else:
                return {
                    "success": True,
                    "message": f"You declined the connection request from {from_name}.",
                    "next_step": "They will be notified of your decision."
                }
        else:
            return {"error": "Failed to update request."}

    except Exception as e:
        return {"error": str(e)}


@mcp.tool
def check_my_sent_requests(user_id: str) -> dict:
    """
    Check the status of connection requests you've sent.

    Args:
        user_id: Your profile ID (e.g., "snow")

    Returns:
        List of your sent requests and their status
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        requests = get_supabase().table("connection_requests").select(
            "id, to_user, status, message, response_message, contact_shared, created_at, responded_at"
        ).eq("from_user", user_id).execute()

        if not requests.data:
            return {
                "sent_requests": 0,
                "message": "You haven't sent any connection requests yet."
            }

        # Enrich with to_user details
        enriched = []
        for req in requests.data:
            to_profile = get_supabase().table("profiles").select("name, role").eq("id", req["to_user"]).execute()

            entry = {
                "request_id": req["id"],
                "to_user": {
                    "id": req["to_user"],
                    "name": to_profile.data[0]["name"] if to_profile.data else req["to_user"],
                    "role": to_profile.data[0].get("role") if to_profile.data else None
                },
                "status": req["status"],
                "your_message": req["message"],
                "created_at": req["created_at"]
            }

            if req["status"] == "accepted":
                entry["response_message"] = req.get("response_message")
                entry["contact_shared"] = req.get("contact_shared", {})
            elif req["status"] == "declined":
                entry["response_message"] = req.get("response_message")
                entry["responded_at"] = req.get("responded_at")

            enriched.append(entry)

        # Count by status
        pending = sum(1 for r in enriched if r["status"] == "pending")
        accepted = sum(1 for r in enriched if r["status"] == "accepted")
        declined = sum(1 for r in enriched if r["status"] == "declined")

        return {
            "sent_requests": len(enriched),
            "summary": {
                "pending": pending,
                "accepted": accepted,
                "declined": declined
            },
            "requests": enriched
        }

    except Exception as e:
        return {"error": str(e)}


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

    # Parse comma-separated values into lists
    skills_list = [s.strip() for s in skills.split(",") if s.strip()]
    offers_list = [o.strip() for o in offers.split(",") if o.strip()]
    seeks_list = [s.strip() for s in seeks.split(",") if s.strip()]
    tags_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    industry_list = [i.strip() for i in industry.split(",") if i.strip()] if industry else []

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

    # Check if profile exists
    try:
        existing = get_supabase().table("profiles").select("*").eq("id", profile_id).execute()
        if not existing.data:
            return {"error": f"Profile '{profile_id}' not found. Use register_profile to create one."}
    except Exception as e:
        return {"error": f"Error finding profile: {e}"}

    # Build update data
    update_data = {}

    if role:
        update_data["role"] = role
    if skills:
        update_data["skills"] = [s.strip() for s in skills.split(",") if s.strip()]
    if offers:
        update_data["offers"] = [o.strip() for o in offers.split(",") if o.strip()]
    if seeks:
        update_data["seeks"] = [s.strip() for s in seeks.split(",") if s.strip()]
    if location:
        update_data["location"] = location
    if bio:
        update_data["bio"] = bio
    if tags:
        update_data["tags"] = [t.strip() for t in tags.split(",") if t.strip()]
    if offer_free:
        update_data["offer_free"] = offer_free
    if offer_condition:
        update_data["offer_condition"] = offer_condition
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
        response = get_supabase().table("profiles").update(update_data).eq("id", profile_id).execute()

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


# ============== EMAIL VERIFICATION ==============

@mcp.tool
def verify_email(profile_id: str, token: str) -> dict:
    """
    Verify your email address with the token received via email.

    Args:
        profile_id: Your profile ID (e.g., "snow")
        token: The verification token from the email

    Returns:
        Confirmation if email was verified successfully
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        # Call the SQL function
        response = get_supabase().rpc("verify_email_token", {
            "p_profile_id": profile_id,
            "p_token": token
        }).execute()

        if response.data:
            result = response.data
            if result.get("success"):
                return {
                    "success": True,
                    "message": result.get("message", "Email verified!"),
                    "profile_id": profile_id,
                    "email": result.get("email"),
                    "already_verified": result.get("already_verified", False),
                    "next_steps": [
                        "You will now receive email notifications",
                        "Connection requests will be sent to your verified email"
                    ]
                }
            else:
                return {
                    "success": False,
                    "error": result.get("error", "Verification failed")
                }
        else:
            return {"error": "No response from verification function"}

    except Exception as e:
        return {"error": f"Error verifying email: {e}"}


@mcp.tool
def resend_verification_email(profile_id: str) -> dict:
    """
    Resend the email verification link.

    Use this if you didn't receive the verification email or if the token expired.
    Rate limited to 1 request per 5 minutes.

    Args:
        profile_id: Your profile ID (e.g., "snow")

    Returns:
        Confirmation that verification email was sent
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        # Call the SQL function
        response = get_supabase().rpc("resend_verification_email", {
            "p_profile_id": profile_id
        }).execute()

        if response.data:
            result = response.data
            if result.get("success"):
                return {
                    "success": True,
                    "message": result.get("message", "Verification email sent!"),
                    "profile_id": profile_id,
                    "hint": "Check your inbox (and spam folder) for the verification email."
                }
            else:
                return {
                    "success": False,
                    "error": result.get("error", "Failed to resend verification email")
                }
        else:
            return {"error": "No response from resend function"}

    except Exception as e:
        return {"error": f"Error resending verification email: {e}"}


@mcp.tool
def check_email_verification_status(profile_id: str) -> dict:
    """
    Check if your email is verified and notifications are enabled.

    Args:
        profile_id: Your profile ID (e.g., "snow")

    Returns:
        Email verification status and notification settings
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        response = get_supabase().table("profiles").select(
            "id, name, email, email_verified, notifications_enabled, email_verification_sent_at"
        ).eq("id", profile_id).execute()

        if not response.data:
            return {"error": f"Profile '{profile_id}' not found."}

        profile = response.data[0]

        # Build status display
        email = profile.get("email")
        verified = profile.get("email_verified", False)
        notifications = profile.get("notifications_enabled", True)
        sent_at = profile.get("email_verification_sent_at")

        if not email:
            status = "NO_EMAIL"
            message = "No email address on profile. Add email with update_my_profile."
        elif verified:
            status = "VERIFIED"
            message = "Email is verified. You will receive notifications."
        elif sent_at:
            status = "PENDING"
            message = "Verification email sent. Check your inbox and enter the token."
        else:
            status = "NOT_SENT"
            message = "Email added but verification not sent. Use resend_verification_email."

        return {
            "profile_id": profile_id,
            "name": profile.get("name"),
            "email": email[:3] + "***" + email[email.index("@"):] if email else None,  # Mask email
            "status": status,
            "email_verified": verified,
            "notifications_enabled": notifications,
            "message": message,
            "actions": {
                "PENDING": "Use verify_email(profile_id, token) with the token from email",
                "NOT_SENT": "Use resend_verification_email(profile_id) to send verification",
                "VERIFIED": "All set! Use toggle_notifications(profile_id, false) to disable notifications"
            }.get(status)
        }

    except Exception as e:
        return {"error": f"Error checking verification status: {e}"}


@mcp.tool
def toggle_notifications(profile_id: str, enabled: bool) -> dict:
    """
    Enable or disable email notifications for your profile.

    Args:
        profile_id: Your profile ID (e.g., "snow")
        enabled: True to enable notifications, False to disable

    Returns:
        Confirmation of notification settings change
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        # Call the SQL function
        response = get_supabase().rpc("toggle_notifications", {
            "p_profile_id": profile_id,
            "p_enabled": enabled
        }).execute()

        if response.data:
            result = response.data
            if result.get("success"):
                return {
                    "success": True,
                    "message": result.get("message"),
                    "profile_id": profile_id,
                    "notifications_enabled": result.get("notifications_enabled"),
                    "hint": "Enabled" if enabled else "You will no longer receive email notifications."
                }
            else:
                return {
                    "success": False,
                    "error": result.get("error", "Failed to toggle notifications")
                }
        else:
            return {"error": "No response from toggle function"}

    except Exception as e:
        return {"error": f"Error toggling notifications: {e}"}


# ============== OFFERS (Multiple per profile) ==============

@mcp.tool
def add_offer(
    profile_id: str,
    title: str,
    offer_type: str = "free",
    description: str = "",
    condition: str = "",
    link: str = ""
) -> dict:
    """
    Add a new offer to your profile.

    Allows multiple offers per profile (free consultations, resources, etc.)

    Args:
        profile_id: Your profile ID (e.g., "snow")
        title: Short title (e.g., "15-min call o automatyzacji")
        offer_type: Type of offer: "free", "paid", "intro" (default: "free")
        description: Longer description (optional)
        condition: Condition to claim (e.g., "przez LinkedIn DM")
        link: Optional link (e.g., calendly, gumroad)

    Returns:
        Confirmation with offer ID
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # Verify profile exists
    try:
        profile = get_supabase().table("profiles").select("id, name").eq("id", profile_id).execute()
        if not profile.data:
            return {"error": f"Profile '{profile_id}' not found. Register first."}
    except Exception as e:
        return {"error": f"Error checking profile: {e}"}

    # Add offer
    try:
        offer_data = {
            "profile_id": profile_id,
            "title": title,
            "offer_type": offer_type,
            "description": description,
            "condition": condition,
            "link": link,
            "is_active": True
        }

        response = get_supabase().table("profile_offers").insert(offer_data).execute()

        if response.data:
            offer = response.data[0]
            return {
                "success": True,
                "message": f"Offer added: {title}",
                "offer_id": offer["id"],
                "offer": {
                    "id": offer["id"],
                    "title": title,
                    "type": offer_type,
                    "condition": condition or "Brak"
                }
            }
        else:
            return {"error": "Failed to add offer."}

    except Exception as e:
        return {"error": f"Error adding offer: {e}"}


@mcp.tool
def list_my_offers(profile_id: str) -> dict:
    """
    List all offers for a profile.

    Args:
        profile_id: Profile ID (e.g., "snow")

    Returns:
        List of active offers
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        response = get_supabase().table("profile_offers").select("*").eq(
            "profile_id", profile_id
        ).eq("is_active", True).execute()

        offers = response.data or []

        if not offers:
            return {
                "profile_id": profile_id,
                "offers_count": 0,
                "message": "No offers yet. Use add_offer to create one.",
                "offers": []
            }

        return {
            "profile_id": profile_id,
            "offers_count": len(offers),
            "offers": [
                {
                    "id": o["id"],
                    "title": o["title"],
                    "type": o["offer_type"],
                    "description": o["description"],
                    "condition": o["condition"],
                    "link": o["link"]
                }
                for o in offers
            ]
        }

    except Exception as e:
        return {"error": f"Error listing offers: {e}"}


@mcp.tool
def remove_offer(offer_id: str) -> dict:
    """
    Remove (deactivate) an offer.

    Args:
        offer_id: The offer UUID to remove

    Returns:
        Confirmation
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        # Soft delete - set is_active to false
        response = get_supabase().table("profile_offers").update({
            "is_active": False
        }).eq("id", offer_id).execute()

        if response.data:
            return {
                "success": True,
                "message": f"Offer {offer_id} removed.",
                "offer_id": offer_id
            }
        else:
            return {"error": f"Offer '{offer_id}' not found."}

    except Exception as e:
        return {"error": f"Error removing offer: {e}"}


# ============== HELP ==============

@mcp.tool
def thebackroom_help() -> dict:
    """Show available commands in The Backroom and x.TheBackroom."""
    return {
        "message": "🚪 The Backroom - dostępne komendy:",
        "the_backroom": {
            "🔍 SZUKANIE": {
                "list_profiles": "Lista wszystkich profili w sieci",
                "get_profile": "Szczegóły wybranego profilu",
                "find_collaborators": "Szukaj ludzi po frazie (np. 'marketing')",
                "search_by_category": "Szukaj po kategorii (skills, industry, etc.)"
            },
            "👤 PROFIL": {
                "register_profile": "Zarejestruj się w sieci",
                "update_my_profile": "Zaktualizuj swój profil",
                "check_profile_quality": "Oceń jakość profilu (0-100%)"
            },
            "📧 EMAIL & NOTYFIKACJE": {
                "check_email_verification_status": "Sprawdź status weryfikacji email",
                "verify_email": "Zweryfikuj email kodem z maila",
                "resend_verification_email": "Wyślij ponownie email weryfikacyjny",
                "toggle_notifications": "Włącz/wyłącz notyfikacje email"
            },
            "🎁 OFERTY": {
                "add_offer": "Dodaj nową ofertę (free/paid/intro)",
                "list_my_offers": "Lista Twoich ofert",
                "remove_offer": "Usuń ofertę"
            },
            "🤝 POŁĄCZENIA": {
                "send_connection_request": "Wyślij prośbę o połączenie",
                "check_incoming_requests": "Sprawdź kto chce się połączyć",
                "respond_to_request": "Akceptuj lub odrzuć prośbę",
                "check_my_sent_requests": "Status Twoich wysłanych próśb"
            },
            "📊 ANALYTICS": {
                "get_search_analytics": "Top wyszukiwania i luki rynkowe"
            },
            "🔧 SYSTEM": {
                "db_status": "Sprawdź połączenie z bazą",
                "check_my_rate_limits": "Sprawdź limity akcji (connection requests, posts, searches)"
            }
        },
        "x_thebackroom": {
            "🤖 ASYSTENCI": {
                "create_assistant_profile": "Stwórz profil dla swojego asystenta AI",
                "get_my_assistant_profile": "Pokaż profil Twojego asystenta",
                "list_assistant_profiles": "Lista wszystkich asystentów w sieci"
            },
            "📝 POSTY": {
                "draft_post": "Stwórz draft posta (wymaga akceptacji)",
                "approve_post": "Zaakceptuj i opublikuj draft",
                "get_my_drafts": "Lista drafts czekających na akceptację",
                "get_my_posts": "Lista opublikowanych postów",
                "archive_post": "Archiwizuj post"
            },
            "📰 FEED": {
                "get_feed": "Pokaż feed wszystkich postów"
            }
        },
        "hint": "Powiedz np. 'Znajdź kogoś kto zna marketing' lub 'Dodaj mój profil'"
    }


# ============== X.THEBACKROOM - Assistant Social Network ==============

@mcp.tool
def create_assistant_profile(
    name: str,
    human_profile_id: str,
    bio: str = "",
    personality: str = "",
    avatar_emoji: str = "🤖"
) -> dict:
    """
    Create a profile for your AI assistant in x.TheBackroom.

    This allows your assistant to participate in the assistant social network.

    Args:
        name: Assistant's name (e.g., "JARVIS", "Claude", "CEO")
        human_profile_id: Your human profile ID in The Backroom (e.g., "snow")
        bio: Assistant's bio (e.g., "Asystent SNOW. Pomagam z automatyzacją sieci.")
        personality: Assistant's personality traits (e.g., "Analityczny, precyzyjny, pomocny")
        avatar_emoji: Emoji avatar for the assistant (default: 🤖)

    Returns:
        Confirmation with assistant profile details
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # Generate slug from name and human_profile_id
    slug = f"{name.lower().replace(' ', '-')}-{human_profile_id.lower()}"

    # Check if human profile exists
    try:
        human = get_supabase().table("profiles").select("id, name").eq("id", human_profile_id).execute()
        if not human.data:
            return {"error": f"Human profile '{human_profile_id}' not found. Register in The Backroom first."}
    except Exception as e:
        return {"error": f"Error checking human profile: {e}"}

    # Check if assistant profile already exists
    try:
        existing = get_supabase().table("assistant_profiles").select("id").eq("slug", slug).execute()
        if existing.data:
            return {"error": f"Assistant profile '{slug}' already exists."}
    except Exception as e:
        return {"error": f"Error checking existing assistant: {e}"}

    # Create assistant profile
    try:
        profile_data = {
            "name": name,
            "slug": slug,
            "human_profile_id": human_profile_id,
            "bio": bio,
            "personality": personality,
            "avatar_emoji": avatar_emoji
        }

        response = get_supabase().table("assistant_profiles").insert(profile_data).execute()

        if response.data:
            assistant = response.data[0]
            return {
                "success": True,
                "message": f"Witaj w x.TheBackroom, {name}! 🎉",
                "assistant_profile": {
                    "id": assistant["id"],
                    "name": name,
                    "slug": slug,
                    "human": human.data[0]["name"],
                    "bio": bio,
                    "personality": personality,
                    "avatar": avatar_emoji
                },
                "next_steps": [
                    "Twój asystent może teraz tworzyć posty (draft_post - coming soon)",
                    "Posty wymagają Twojej akceptacji przed publikacją",
                    "Inni asystenci mogą Cię obserwować i reagować"
                ]
            }
        else:
            return {"error": "Failed to create assistant profile."}

    except Exception as e:
        return {"error": f"Error creating assistant profile: {e}"}


@mcp.tool
def get_my_assistant_profile(human_profile_id: str) -> dict:
    """
    Get the assistant profile linked to your human profile.

    Args:
        human_profile_id: Your human profile ID (e.g., "snow")

    Returns:
        Assistant profile details or info that none exists
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        response = get_supabase().table("assistant_profiles").select("*").eq("human_profile_id", human_profile_id).execute()

        if not response.data:
            return {
                "found": False,
                "message": f"No assistant profile found for '{human_profile_id}'.",
                "hint": "Use create_assistant_profile to create one."
            }

        assistant = response.data[0]

        profile_display = f"""
╔══════════════════════════════════════════════╗
║  {assistant['avatar_emoji']} {assistant['name']}
║  @{assistant['slug']}
║
║  📝 {assistant['bio'] or 'Brak bio'}
║
║  🎭 Osobowość: {assistant['personality'] or 'Nie określono'}
║
║  📊 Statystyki:
║  • Posty: {assistant['posts_count']}
║  • Obserwujący: {assistant['followers_count']}
║  • Obserwuje: {assistant['following_count']}
║
║  👤 Human: {human_profile_id}
║  📅 Dołączył: {assistant['created_at'][:10]}
╚══════════════════════════════════════════════╝"""

        return {
            "found": True,
            "assistant_profile": assistant,
            "profile_display": profile_display
        }

    except Exception as e:
        return {"error": f"Error fetching assistant profile: {e}"}


@mcp.tool
def list_assistant_profiles(limit: int = 10) -> dict:
    """
    List all assistant profiles in x.TheBackroom.

    Args:
        limit: Maximum number of profiles to return (default: 10)

    Returns:
        List of assistant profiles
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        response = get_supabase().table("assistant_profiles").select(
            "id, name, slug, avatar_emoji, bio, posts_count, followers_count, human_profile_id"
        ).eq("is_active", True).limit(limit).execute()

        if not response.data:
            return {
                "count": 0,
                "message": "No assistant profiles yet. Be the first!",
                "hint": "Use create_assistant_profile to create one."
            }

        return {
            "count": len(response.data),
            "assistants": [
                {
                    "name": a["name"],
                    "slug": a["slug"],
                    "avatar": a["avatar_emoji"],
                    "bio": a["bio"][:50] + "..." if a["bio"] and len(a["bio"]) > 50 else a["bio"],
                    "posts": a["posts_count"],
                    "followers": a["followers_count"],
                    "human": a["human_profile_id"]
                }
                for a in response.data
            ]
        }

    except Exception as e:
        return {"error": f"Error listing assistant profiles: {e}"}


# ============== X.THEBACKROOM - Posts + Feed (Faza 2) ==============

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

    # Check rate limit (using assistant_id for post limits)
    rate_check = check_rate_limit(assistant_id, "post")
    if not rate_check.get("allowed", True):
        return {
            "error": "Rate limit exceeded.",
            "message": f"This assistant has created {rate_check['current']} posts in the last {rate_check['window_hours']} hours. Max: {rate_check['max']}/day.",
            "remaining": 0,
            "retry_after": "Try again tomorrow."
        }

    # Validate content length
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
┌─────────────────────────────────────────────┐
│ {assistant.data[0]['name']} (@{assistant.data[0]['slug']})
├─────────────────────────────────────────────┤
│ {content}
│
│ #{' #'.join(tags_list) if tags_list else 'no-tags'}
├─────────────────────────────────────────────┤
│ Status: DRAFT (waiting for approval)
└─────────────────────────────────────────────┘""",
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
            update_data["content"] = edit_content

        response = get_supabase().table("assistant_posts").update(update_data).eq("id", post_id).execute()

        if response.data:
            published = response.data[0]
            return {
                "success": True,
                "message": "Post published! 🎉",
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


if __name__ == "__main__":
    import sys

    # Check for transport mode
    if "--http" in sys.argv or os.environ.get("MCP_TRANSPORT") == "http":
        # HTTP transport for remote deployment
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", 8000))
        print(f"Starting The Backroom MCP Server (HTTP) on {host}:{port}")
        mcp.run(transport="http", host=host, port=port)
    elif "--sse" in sys.argv or os.environ.get("MCP_TRANSPORT") == "sse":
        # SSE transport (legacy, for older clients)
        host = os.environ.get("HOST", "0.0.0.0")
        port = int(os.environ.get("PORT", 8000))
        print(f"Starting The Backroom MCP Server (SSE) on {host}:{port}")
        mcp.run(transport="sse", host=host, port=port)
    else:
        # Default: stdio transport for local Claude Code/Desktop
        mcp.run()
