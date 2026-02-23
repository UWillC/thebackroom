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
import re
import html
from supabase import create_client, Client

# Auth module (Magic Link)
from auth import (
    request_magic_link as _request_magic_link,
    auth_callback as _auth_callback,
    auth_status as _auth_status,
    auth_logout as _auth_logout,
    refresh_session as _refresh_session,
    get_authenticated_client
)

# Utils module
from utils import (
    # Validation
    LIMITS, MAX_TAGS, MAX_SKILLS, MAX_OFFERS,
    detect_prompt_injection, sanitize_for_injection,
    check_injection_and_sanitize, validate_length,
    validate_email, validate_url, validate_slug, validate_uuid,
    sanitize_text, sanitize_list, validate_profile_id,
    validate_required, validate_input,
    # Supabase
    SUPABASE_URL, SUPABASE_KEY, get_supabase, load_profiles,
    format_profile_summary, log_search, log_profile_view, log_search_appearances,
    # Rate limiting
    RATE_LIMITS, check_rate_limit, get_rate_limit_status,
)

# Initialize MCP server
mcp = FastMCP("The Backroom")


# ============== VALIDATION & SECURITY ==============
# Imported from utils module - see utils/validation.py

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

**🔍 SZUKANIE**
1. **Szukaj współpracowników** - np. "Znajdź eksperta od Make.com"
2. **Moje dopasowania** - 🆕 kto pasuje do MOJEGO profilu? (get_my_matches)
3. **Szukaj po kategorii** - skills, industry, seeks, offers

**👤 PROFIL**
4. **Dodaj profil** - zarejestruj się w sieci
5. **Sprawdź jakość** - AI ocena profilu 0-100%
6. **Zweryfikuj email** - potwierdź adres email

**🤝 POŁĄCZENIA**
7. **Wyślij prośbę** - napisz do kogoś
8. **Sprawdź requesty** - kto chce się połączyć
9. **Odpowiedz** - akceptuj lub odrzuć

**📊 INNE**
10. **Analytics** - top wyszukiwania, luki rynkowe
11. **Moje oferty** - dodaj/usuń oferty (free/paid)

Która opcja Cię interesuje?"""



# ============== REGISTER TOOLS FROM MODULES ==============

# Auth tools
from auth import register_tools as register_auth_tools
register_auth_tools(mcp)

# Core tools (profiles, connections, search, offers, help)
from core import register_all_tools as register_core_tools
register_core_tools(mcp)

# x.TheBackroom tools (assistants, posts)
from x import register_all_tools as register_x_tools
register_x_tools(mcp)

# Enterprise tools (rooms, members, messaging)
from enterprise import register_all_tools as register_enterprise_tools
register_enterprise_tools(mcp)


@mcp.prompt()
def utworz_pokoj() -> str:
    """Utwórz nowy pokój Enterprise lub Personal"""
    return """Chcę utworzyć nowy pokój w The Backroom.

Zapytaj mnie:
1. Czy to pokój firmowy (Enterprise) czy osobisty (Personal dla sync asystentów)?
2. Nazwę pokoju
3. Opis (opcjonalnie)
4. Moje ID profilu

Potem użyj create_room z odpowiednimi parametrami."""


@mcp.prompt()
def sprawdz_pokoj_inbox() -> str:
    """Sprawdź wiadomości w pokojach"""
    return """Sprawdź moją skrzynkę wiadomości w pokojach The Backroom.

Użyj check_room_inbox z moim profile_id.
Pokaż nieprzeczytane wiadomości, priorytetyzując:
1. 🔴 URGENT
2. 🟠 HIGH
3. Z deadline'ami

Jeśli są wiadomości typu 'request' - zaproponuj odpowiedź."""


@mcp.prompt()
def wyslij_reminder() -> str:
    """Wyślij reminder do zespołu w pokoju"""
    return """Chcę wysłać reminder do członków mojego pokoju.

Zapytaj mnie:
1. W którym pokoju (pokaż moje pokoje z get_my_rooms)
2. Temat reminderu
3. Treść
4. Deadline (opcjonalnie)
5. Priorytet (low/normal/high/urgent)
6. Czy do wszystkich czy konkretnej osoby

Potem użyj send_room_message z message_type="reminder"."""


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
