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
def find_collaborators(query: str, max_results: int = 5) -> dict:
    """
    Search for collaborators matching the query.

    Examples:
    - "looking for someone who knows Python"
    - "need marketing advice"
    - "seeking co-founder with tech skills"
    """
    if not get_supabase():
        return {"error": "Database not connected. Set SUPABASE_URL and SUPABASE_KEY."}

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

    return {
        "query": query,
        "matches_found": len(matches),
        "results": matches[:max_results]
    }


@mcp.tool
def search_by_category(category: str, value: str) -> dict:
    """
    Search profiles by specific category.

    Categories: industry, skills, seeking, offering

    Examples:
    - category="industry", value="e-commerce"
    - category="skills", value="python"
    - category="seeking", value="co-founder"
    """
    if not get_supabase():
        return {"error": "Database not connected."}

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

    return {
        "category": category,
        "value": value,
        "matches_found": len(matches),
        "results": matches
    }


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
                ]
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
