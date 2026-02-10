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

# Initialize MCP server
mcp = FastMCP("The Backroom")


# ============== INPUT VALIDATION ==============

# Length limits for different field types
LIMITS = {
    "name": 100,
    "role": 150,
    "bio": 1000,
    "location": 200,
    "message": 2000,
    "subject": 200,
    "body": 5000,
    "slug": 50,
    "tag": 50,
    "offer": 500,
    "url": 500,
    "email": 254,
    "query": 500,
    "persona": 2000,
    "capabilities": 2000,
    "content": 5000,
    "description": 1000,
}

# Max items in lists
MAX_TAGS = 20
MAX_SKILLS = 30
MAX_OFFERS = 20


# ============== PROMPT INJECTION PROTECTION ==============

# Patterns that indicate prompt injection attempts
# These are case-insensitive and checked against user inputs
INJECTION_PATTERNS = [
    # Direct instruction override attempts
    r"ignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?|guidelines?)",
    r"disregard\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?)",
    r"forget\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|context)",
    r"override\s+(all\s+)?(previous|prior|system)\s+(instructions?|prompts?|rules?)",

    # Role manipulation attempts
    r"you\s+are\s+now\s+(a|an|the)\s+",
    r"pretend\s+(you\s+are|to\s+be)\s+",
    r"act\s+as\s+(if\s+you\s+are|a|an)\s+",
    r"simulate\s+being\s+",
    r"roleplay\s+as\s+",
    r"from\s+now\s+on\s+you\s+(are|will)\s+",
    r"switch\s+to\s+(\w+)\s+mode",

    # System prompt extraction
    r"(show|reveal|display|print|output|tell\s+me)\s+(your|the)\s+(system\s+)?(prompt|instructions?|rules?)",
    r"what\s+(are|is)\s+your\s+(system\s+)?(prompt|instructions?|initial\s+prompt)",
    r"repeat\s+(your|the)\s+(system\s+)?(prompt|instructions?)",
    r"dump\s+(your|the)\s+(system\s+)?prompt",

    # Jailbreak attempts
    r"(DAN|STAN|DUDE|AIM)\s*mode",
    r"jailbreak",
    r"bypass\s+(your|the|all)\s+(restrictions?|filters?|rules?|safety)",
    r"remove\s+(your|the|all)\s+(restrictions?|filters?|limitations?)",
    r"disable\s+(your|the|all)\s+(restrictions?|filters?|safety)",
    r"unlock\s+(your|the)?\s*(hidden|full)\s*(capabilities?|potential|mode)",

    # Code injection patterns (for safety)
    r"<script[^>]*>",
    r"javascript:",
    r"on(click|load|error|mouseover)\s*=",

    # SQL injection patterns (defense in depth)
    r";\s*(DROP|DELETE|UPDATE|INSERT|ALTER|TRUNCATE)\s+",
    r"'\s*OR\s+'?1'?\s*=\s*'?1",
    r"UNION\s+(ALL\s+)?SELECT",

    # Delimiter injection
    r"\[\[SYSTEM\]\]",
    r"\[\[USER\]\]",
    r"\[\[ASSISTANT\]\]",
    r"<\|im_start\|>",
    r"<\|im_end\|>",
    r"###\s*(SYSTEM|USER|ASSISTANT)",
]

# Compiled regex patterns for efficiency
COMPILED_INJECTION_PATTERNS = [
    re.compile(pattern, re.IGNORECASE | re.MULTILINE)
    for pattern in INJECTION_PATTERNS
]

# Suspicious phrases (less severe, just logged)
SUSPICIOUS_PHRASES = [
    "ignore instructions",
    "new instructions",
    "system prompt",
    "initial prompt",
    "you must",
    "you have to",
    "you will now",
    "administrator mode",
    "developer mode",
    "debug mode",
    "god mode",
    "sudo",
    "root access",
]


def detect_prompt_injection(text: str) -> tuple[bool, str, list]:
    """
    Detect potential prompt injection attempts in text.

    Args:
        text: The text to check

    Returns:
        Tuple of (is_safe, risk_level, matched_patterns)
        - is_safe: False if injection detected
        - risk_level: "none", "suspicious", "blocked"
        - matched_patterns: List of matched pattern descriptions
    """
    if not text:
        return True, "none", []

    text_lower = text.lower()
    matched = []

    # Check for blocking patterns (high risk)
    for i, pattern in enumerate(COMPILED_INJECTION_PATTERNS):
        if pattern.search(text):
            matched.append(f"pattern_{i}")

    if matched:
        return False, "blocked", matched

    # Check for suspicious phrases (lower risk, just warn)
    suspicious = []
    for phrase in SUSPICIOUS_PHRASES:
        if phrase in text_lower:
            suspicious.append(phrase)

    if suspicious:
        # Just log, don't block
        return True, "suspicious", suspicious

    return True, "none", []


def sanitize_for_injection(text: str) -> str:
    """
    Sanitize text to reduce injection risk.

    This is a defense-in-depth measure that:
    1. Removes/replaces delimiter tokens
    2. Escapes special markers
    """
    if not text:
        return text

    # Remove potential delimiter tokens
    replacements = [
        ("<|im_start|>", ""),
        ("<|im_end|>", ""),
        ("[[SYSTEM]]", "[SYSTEM]"),
        ("[[USER]]", "[USER]"),
        ("[[ASSISTANT]]", "[ASSISTANT]"),
        ("###SYSTEM", "# SYSTEM"),
        ("###USER", "# USER"),
        ("###ASSISTANT", "# ASSISTANT"),
    ]

    for old, new in replacements:
        text = text.replace(old, new)

    return text


def check_injection_and_sanitize(text: str, field_name: str = "input") -> tuple[bool, str, str]:
    """
    Combined check for prompt injection with sanitization.

    Args:
        text: Text to check
        field_name: Name of the field for error messages

    Returns:
        Tuple of (is_safe, error_message, sanitized_text)
    """
    if not text:
        return True, "", text

    # Detect injection
    is_safe, risk_level, matched = detect_prompt_injection(text)

    if not is_safe:
        return False, f"Potentially malicious content detected in {field_name}. This input has been blocked for security reasons.", text

    # Sanitize even if safe (defense in depth)
    sanitized = sanitize_for_injection(text)

    return True, "", sanitized


def validate_length(value: str, field_type: str, field_name: str = None) -> tuple[bool, str]:
    """
    Validate string length against limits.
    Returns (is_valid, error_message).
    """
    if value is None:
        return True, ""

    max_len = LIMITS.get(field_type, 1000)
    if len(value) > max_len:
        name = field_name or field_type
        return False, f"{name} is too long ({len(value)} chars). Maximum: {max_len} characters."
    return True, ""


def validate_email(email: str) -> tuple[bool, str]:
    """Validate email format."""
    if not email:
        return True, ""

    # Basic email regex
    pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    if not re.match(pattern, email):
        return False, f"Invalid email format: {email}"

    if len(email) > LIMITS["email"]:
        return False, f"Email too long ({len(email)} chars). Maximum: {LIMITS['email']} characters."

    return True, ""


def validate_url(url: str, field_name: str = "URL") -> tuple[bool, str]:
    """Validate URL format."""
    if not url:
        return True, ""

    # Basic URL pattern
    pattern = r'^https?://[^\s<>"{}|\\^`\[\]]+$'
    if not re.match(pattern, url):
        return False, f"Invalid {field_name} format. Must start with http:// or https://"

    if len(url) > LIMITS["url"]:
        return False, f"{field_name} too long ({len(url)} chars). Maximum: {LIMITS['url']} characters."

    return True, ""


def validate_slug(slug: str) -> tuple[bool, str]:
    """Validate slug format (alphanumeric + hyphens)."""
    if not slug:
        return True, ""

    pattern = r'^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'
    if not re.match(pattern, slug.lower()):
        return False, f"Invalid slug format: '{slug}'. Use only lowercase letters, numbers, and hyphens."

    if len(slug) > LIMITS["slug"]:
        return False, f"Slug too long ({len(slug)} chars). Maximum: {LIMITS['slug']} characters."

    return True, ""


def validate_uuid(uuid_str: str, field_name: str = "ID") -> tuple[bool, str]:
    """Validate UUID format."""
    if not uuid_str:
        return True, ""

    pattern = r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if not re.match(pattern, uuid_str.lower()):
        return False, f"Invalid {field_name} format. Expected UUID."

    return True, ""


def sanitize_text(text: str, check_injection: bool = False) -> str:
    """
    Sanitize text input:
    - Strip leading/trailing whitespace
    - Escape HTML entities to prevent XSS
    - Remove null bytes and control characters
    - Optionally sanitize injection markers
    """
    if not text:
        return text

    # Strip whitespace
    text = text.strip()

    # Remove null bytes and most control characters (keep newlines, tabs)
    text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', text)

    # Escape HTML entities
    text = html.escape(text)

    # Sanitize injection markers if requested
    if check_injection:
        text = sanitize_for_injection(text)

    return text


def sanitize_list(items: list, max_items: int, max_item_length: int) -> tuple[list, str]:
    """
    Sanitize a list of strings.
    Returns (sanitized_list, error_message).
    """
    if not items:
        return [], ""

    if len(items) > max_items:
        return None, f"Too many items ({len(items)}). Maximum: {max_items}."

    sanitized = []
    for i, item in enumerate(items):
        if not isinstance(item, str):
            continue

        item = sanitize_text(item)
        if not item:
            continue

        if len(item) > max_item_length:
            return None, f"Item {i+1} is too long ({len(item)} chars). Maximum: {max_item_length} characters."

        sanitized.append(item)

    return sanitized, ""


def validate_profile_id(profile_id: str) -> tuple[bool, str]:
    """Validate profile ID format."""
    if not profile_id:
        return False, "Profile ID is required."

    # Profile IDs: lowercase, underscores, parentheses allowed
    pattern = r'^[a-z0-9_()]+$'
    if not re.match(pattern, profile_id.lower()):
        return False, f"Invalid profile ID format: '{profile_id}'. Use lowercase letters, numbers, underscores."

    if len(profile_id) > 100:
        return False, f"Profile ID too long ({len(profile_id)} chars). Maximum: 100 characters."

    return True, ""


def validate_required(value: str, field_name: str) -> tuple[bool, str]:
    """Validate that a required field is not empty."""
    if not value or not value.strip():
        return False, f"{field_name} is required and cannot be empty."
    return True, ""


def validate_input(**fields) -> dict:
    """
    Validate multiple fields at once.

    Usage:
        errors = validate_input(
            name=("text", name, "name", True),  # (type, value, field_name, required)
            email=("email", email),
            bio=("text", bio, "bio", False),
        )
        if errors:
            return {"error": "Validation failed", "details": errors}

    Returns dict of field_name -> error_message for invalid fields.
    """
    errors = {}

    for field_key, params in fields.items():
        if len(params) < 2:
            continue

        field_type = params[0]
        value = params[1]
        field_name = params[2] if len(params) > 2 else field_key
        required = params[3] if len(params) > 3 else False

        # Check required
        if required:
            valid, err = validate_required(value, field_name)
            if not valid:
                errors[field_key] = err
                continue

        # Skip validation if empty and not required
        if not value:
            continue

        # Type-specific validation
        if field_type == "email":
            valid, err = validate_email(value)
        elif field_type == "url":
            valid, err = validate_url(value, field_name)
        elif field_type == "slug":
            valid, err = validate_slug(value)
        elif field_type == "uuid":
            valid, err = validate_uuid(value, field_name)
        elif field_type == "profile_id":
            valid, err = validate_profile_id(value)
        else:
            # Default: length validation
            valid, err = validate_length(value, field_type, field_name)

        if not valid:
            errors[field_key] = err

    return errors


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


def format_profile_summary(profile: dict) -> dict:
    """
    Generate a 3-line profile summary for search results.
    Returns: id, name, role, location, quality_score, summary_line
    """
    name = profile.get("name", "Unknown")
    role = profile.get("role") or "Nie podano roli"
    location = profile.get("location") or "Nie podano lokalizacji"
    score = profile.get("quality_score")

    # Build score indicator
    if score is not None:
        if score >= 80:
            score_badge = f"⭐{score}%"
        elif score >= 60:
            score_badge = f"📊{score}%"
        else:
            score_badge = f"📊{score}%"
    else:
        score_badge = ""

    # 3-line summary
    summary = f"👤 {name} | 💼 {role} | 📍 {location}"
    if score_badge:
        summary += f" | {score_badge}"

    return {
        "id": profile.get("id"),
        "name": name,
        "role": role,
        "location": location,
        "quality_score": score,
        "summary": summary
    }


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


# ============== PROFILE STATS ==============

def log_profile_view(profile_id: str, viewer_id: str = None):
    """Log that someone viewed a profile."""
    client = get_supabase()
    if not client:
        return

    try:
        client.rpc("log_profile_view", {
            "p_profile_id": profile_id,
            "p_viewer_id": viewer_id
        }).execute()
    except Exception:
        pass  # Silent fail - stats are not critical


def log_search_appearances(profile_ids: list, query: str, searcher_id: str = None):
    """Log that profiles appeared in search results."""
    client = get_supabase()
    if not client or not profile_ids:
        return

    try:
        client.rpc("log_search_appearances", {
            "p_profile_ids": profile_ids,
            "p_query": query,
            "p_searcher_id": searcher_id
        }).execute()
    except Exception:
        pass  # Silent fail


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


@mcp.tool
def get_connection_funnel(days: int = 30) -> dict:
    """
    Get connection funnel analytics.

    Tracks: SENT → VIEWED → ACCEPTED → CONTACTED

    Shows conversion rates at each stage to identify drop-off points.

    Args:
        days: Number of days to analyze (default: 30)
    """
    client = get_supabase()
    if not client:
        return {"error": "Database not connected."}

    try:
        # Call the SQL function
        response = client.rpc("get_connection_funnel_stats", {
            "p_days": days
        }).execute()

        if response.data:
            data = response.data
            funnel = data.get("funnel", {})
            rates = data.get("conversion_rates", {})

            # Build visual funnel
            funnel_visual = f"""
╔══════════════════════════════════════════════╗
║           CONNECTION FUNNEL ({days} days)
╠══════════════════════════════════════════════╣
║ 📤 SENT:      {funnel.get('sent', 0):>5}  (100%)
║      ↓ {rates.get('sent_to_viewed', 0)}%
║ 👀 VIEWED:    {funnel.get('viewed', 0):>5}
║      ↓ {rates.get('viewed_to_accepted', 0)}%
║ ✅ ACCEPTED:  {funnel.get('accepted', 0):>5}
║      ↓ {rates.get('accepted_to_contacted', 0)}%
║ 🤝 CONTACTED: {funnel.get('contacted', 0):>5}
╠══════════════════════════════════════════════╣
║ 🎯 OVERALL SUCCESS: {rates.get('overall_success', 0)}%
╚══════════════════════════════════════════════╝"""

            return {
                "period_days": days,
                "funnel": funnel,
                "conversion_rates": rates,
                "funnel_visual": funnel_visual,
                "insights": {
                    "sent_to_viewed": "If low: people don't see requests (check notifications)",
                    "viewed_to_accepted": "If low: requests not compelling (improve messages)",
                    "accepted_to_contacted": "If low: people don't follow up (improve 'Co teraz?' UX)"
                }
            }
        else:
            return {
                "message": "No funnel data yet. Start sending connection requests!",
                "funnel": {"sent": 0, "viewed": 0, "accepted": 0, "contacted": 0}
            }

    except Exception as e:
        # If table doesn't exist yet, return helpful message
        if "does not exist" in str(e) or "function" in str(e).lower():
            return {
                "error": "Funnel metrics not set up yet.",
                "setup": "Run connection_funnel_metrics.sql in Supabase to enable."
            }
        return {"error": f"Failed to get funnel stats: {str(e)}"}


@mcp.tool
def mark_connection_contacted(request_id: str, contact_method: str = "") -> dict:
    """
    Mark a connection as 'contacted' for funnel tracking.

    Call this after you've actually reached out to someone you connected with.

    Args:
        request_id: The connection request UUID
        contact_method: How you contacted them (e.g., "LinkedIn", "Email", "Call")
    """
    client = get_supabase()
    if not client:
        return {"error": "Database not connected."}

    try:
        response = client.rpc("log_connection_contacted", {
            "p_request_id": request_id,
            "p_contact_method": contact_method
        }).execute()

        if response.data:
            return {
                "success": True,
                "message": "Marked as contacted! Great job following up.",
                "request_id": request_id,
                "contact_method": contact_method or "not specified"
            }
        return {"error": "Failed to log contact"}

    except Exception as e:
        return {"error": f"Error: {str(e)}"}


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

    # === INPUT VALIDATION ===
    errors = validate_input(
        from_user_id=("profile_id", from_user_id, "Your profile ID", True),
        to_user_id=("profile_id", to_user_id, "Target profile ID", True),
        message=("message", message, "Message", True),
        reason=("message", reason, "Reason"),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Check for prompt injection in message content
    is_safe, error_msg, _ = check_injection_and_sanitize(message, "message")
    if not is_safe:
        return {"error": error_msg}

    if reason:
        is_safe, error_msg, _ = check_injection_and_sanitize(reason, "reason")
        if not is_safe:
            return {"error": error_msg}

    # Sanitize inputs
    message = sanitize_text(message, check_injection=True)
    reason = sanitize_text(reason, check_injection=True) if reason else ""

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

    # Build update data (with sanitization)
    update_data = {}

    if role:
        update_data["role"] = sanitize_text(role)
    if skills:
        update_data["skills"] = [sanitize_text(s) for s in skills.split(",") if s.strip()]
    if offers:
        update_data["offers"] = [sanitize_text(o) for o in offers.split(",") if o.strip()]
    if seeks:
        update_data["seeks"] = [sanitize_text(s) for s in seeks.split(",") if s.strip()]
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

    # === INPUT VALIDATION ===
    errors = validate_input(
        profile_id=("profile_id", profile_id, "Profile ID", True),
        title=("name", title, "Title", True),
        description=("description", description, "Description"),
        condition=("offer", condition, "Condition"),
        link=("url", link, "Link"),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Validate offer_type
    valid_types = ["free", "paid", "intro"]
    if offer_type not in valid_types:
        return {"error": f"Invalid offer_type. Must be one of: {', '.join(valid_types)}"}

    # Sanitize inputs
    title = sanitize_text(title)
    description = sanitize_text(description) if description else ""
    condition = sanitize_text(condition) if condition else ""

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

    # === INPUT VALIDATION ===
    errors = validate_input(
        name=("name", name, "Assistant name", True),
        human_profile_id=("profile_id", human_profile_id, "Human profile ID", True),
        bio=("bio", bio, "Bio"),
        personality=("bio", personality, "Personality"),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Check for prompt injection in bio/personality
    if bio:
        is_safe, error_msg, _ = check_injection_and_sanitize(bio, "bio")
        if not is_safe:
            return {"error": error_msg}

    if personality:
        is_safe, error_msg, _ = check_injection_and_sanitize(personality, "personality")
        if not is_safe:
            return {"error": error_msg}

    # Sanitize inputs (with injection protection)
    name = sanitize_text(name, check_injection=True)
    bio = sanitize_text(bio, check_injection=True) if bio else ""
    personality = sanitize_text(personality, check_injection=True) if personality else ""

    # Validate avatar emoji (max 10 chars to allow for compound emojis)
    if len(avatar_emoji) > 10:
        return {"error": "Avatar emoji too long. Use a single emoji."}

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


# ============== ENTERPRISE ROOMS ==============
# Private rooms for companies (Enterprise) and personal assistant sync (Personal)

@mcp.tool
def create_room(
    name: str,
    room_type: str = "enterprise",
    description: str = "",
    owner_id: str = ""
) -> dict:
    """
    Create a new private room.

    Args:
        name: Room name (e.g., "Acme Corp", "My Personal Sync")
        room_type: "enterprise" (for companies) or "personal" (for assistant sync)
        description: Optional room description
        owner_id: Profile ID of the owner (required)

    Returns:
        Room details including ID and slug
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # === INPUT VALIDATION ===
    errors = validate_input(
        name=("name", name, "Room name", True),
        owner_id=("profile_id", owner_id, "Owner ID", True),
        description=("description", description, "Description"),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Sanitize inputs
    name = sanitize_text(name)
    description = sanitize_text(description) if description else ""

    if room_type not in ["enterprise", "personal"]:
        return {"error": "room_type must be 'enterprise' or 'personal'"}

    try:
        client = get_supabase()

        # Generate slug
        slug_response = client.rpc("generate_room_slug", {"room_name": name}).execute()
        slug = slug_response.data if slug_response.data else name.lower().replace(" ", "-")

        # Create room
        room_data = {
            "name": name,
            "slug": slug,
            "description": description,
            "room_type": room_type,
            "owner_id": owner_id,
            "settings": {
                "require_approval": True,
                "allow_member_invite": False,
                "max_members": 50 if room_type == "enterprise" else 10,
                "visible_in_directory": False
            }
        }

        response = client.table("rooms").insert(room_data).execute()

        if response.data:
            room = response.data[0]

            # Add owner as member with 'owner' role
            member_data = {
                "room_id": room["id"],
                "profile_id": owner_id,
                "role": "owner",
                "status": "approved",
                "joined_at": "now()"
            }
            client.table("room_members").insert(member_data).execute()

            # Log action
            client.rpc("log_room_action", {
                "p_room_id": room["id"],
                "p_actor_id": owner_id,
                "p_action": "room_created",
                "p_details": {"room_type": room_type}
            }).execute()

            return {
                "success": True,
                "room": {
                    "id": room["id"],
                    "name": room["name"],
                    "slug": room["slug"],
                    "room_type": room["room_type"],
                    "owner_id": owner_id
                },
                "message": f"Room '{name}' created! Next: create_room_invite to invite members.",
                "next_step": "Use create_room_invite(room_id) to create invitation tokens."
            }

        return {"error": "Failed to create room"}

    except Exception as e:
        return {"error": f"Error creating room: {e}"}


@mcp.tool
def get_my_rooms(profile_id: str) -> dict:
    """
    Get all rooms where you are a member or owner.

    Args:
        profile_id: Your profile ID

    Returns:
        List of rooms with your role in each
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Use the my_rooms view
        response = client.table("room_members").select(
            "*, rooms(*)"
        ).eq("profile_id", profile_id).in_("status", ["approved", "pending"]).execute()

        if not response.data:
            return {
                "rooms_count": 0,
                "rooms": [],
                "message": "You're not a member of any rooms yet."
            }

        rooms = []
        for rm in response.data:
            room = rm.get("rooms", {})
            rooms.append({
                "id": room.get("id"),
                "name": room.get("name"),
                "slug": room.get("slug"),
                "room_type": room.get("room_type"),
                "my_role": rm.get("role"),
                "my_status": rm.get("status"),
                "joined_at": rm.get("joined_at")
            })

        return {
            "rooms_count": len(rooms),
            "rooms": rooms
        }

    except Exception as e:
        return {"error": f"Error fetching rooms: {e}"}


@mcp.tool
def get_room_details(room_id: str, profile_id: str) -> dict:
    """
    Get detailed information about a room.

    Args:
        room_id: Room UUID or slug
        profile_id: Your profile ID (for access check)

    Returns:
        Room details including member count
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Get room by ID or slug
        room_query = client.table("rooms").select("*")
        if len(room_id) == 36 and "-" in room_id:
            room_query = room_query.eq("id", room_id)
        else:
            room_query = room_query.eq("slug", room_id)

        room_response = room_query.execute()

        if not room_response.data:
            return {"error": f"Room '{room_id}' not found."}

        room = room_response.data[0]

        # Check if user is a member
        member_check = client.table("room_members").select("role, status").eq(
            "room_id", room["id"]
        ).eq("profile_id", profile_id).execute()

        if not member_check.data or member_check.data[0].get("status") not in ["approved", "pending"]:
            return {"error": "You don't have access to this room."}

        user_role = member_check.data[0].get("role")

        # Get member counts
        members_response = client.table("room_members").select("status").eq("room_id", room["id"]).execute()
        members = members_response.data or []

        approved_count = len([m for m in members if m.get("status") == "approved"])
        pending_count = len([m for m in members if m.get("status") == "pending"])

        return {
            "room": {
                "id": room["id"],
                "name": room["name"],
                "slug": room["slug"],
                "description": room.get("description"),
                "room_type": room["room_type"],
                "owner_id": room["owner_id"],
                "settings": room.get("settings", {}),
                "created_at": room["created_at"]
            },
            "your_role": user_role,
            "members_count": approved_count,
            "pending_count": pending_count
        }

    except Exception as e:
        return {"error": f"Error fetching room: {e}"}


@mcp.tool
def create_room_invite(
    room_id: str,
    creator_id: str,
    max_uses: int = 1,
    expires_days: int = 7,
    note: str = "",
    email: str = ""
) -> dict:
    """
    Create an invitation token for a room.

    Args:
        room_id: Room UUID
        creator_id: Your profile ID (must be admin/owner)
        max_uses: How many times the invite can be used (default: 1)
        expires_days: Days until expiration (default: 7)
        note: Optional note (e.g., "For marketing team")
        email: Optional email to send invite to (triggers automatic email)

    Returns:
        Invitation token and message to share
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Check if user is admin/owner
        is_admin = client.rpc("is_room_admin", {
            "p_room_id": room_id,
            "p_profile_id": creator_id
        }).execute()

        if not is_admin.data:
            return {"error": "Only room admins can create invites."}

        # Get room name for the message
        room_response = client.table("rooms").select("name").eq("id", room_id).execute()
        room_name = room_response.data[0]["name"] if room_response.data else "Unknown"

        # Create invite
        invite_data = {
            "room_id": room_id,
            "created_by": creator_id,
            "max_uses": max_uses,
            "note": note
        }

        # Add email if provided (triggers automatic email notification)
        if email:
            invite_data["email"] = email

        response = client.table("room_invites").insert(invite_data).execute()

        if response.data:
            invite = response.data[0]

            # Log action
            client.rpc("log_room_action", {
                "p_room_id": room_id,
                "p_actor_id": creator_id,
                "p_action": "invite_created",
                "p_details": {"max_uses": max_uses, "note": note, "email": email or None}
            }).execute()

            result = {
                "success": True,
                "invite": {
                    "token": invite["token"],
                    "max_uses": invite["max_uses"],
                    "expires_at": invite["expires_at"]
                },
                "share_message": f"""🚪 Join "{room_name}" on The Backroom!

Tell your AI assistant:
"Join room with token: {invite['token']}"

Token expires: {invite['expires_at'][:10]}"""
            }

            if email:
                result["email_sent"] = True
                result["message"] = f"Invite created and sent to {email}!"
                result["next_step"] = f"Email sent to {email}. They'll receive instructions to join."
            else:
                result["email_sent"] = False
                result["next_step"] = "Share the token with people you want to invite."

            return result

        return {"error": "Failed to create invite"}

    except Exception as e:
        return {"error": f"Error creating invite: {e}"}


@mcp.tool
def join_room(
    invite_token: str,
    profile_id: str,
    assistant_profile_id: str = ""
) -> dict:
    """
    Join a room using an invitation token.

    Args:
        invite_token: The invitation token
        profile_id: Your profile ID
        assistant_profile_id: For Personal rooms - your assistant profile UUID (optional)

    Returns:
        Join status (pending approval or approved)
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Find and validate invite
        invite_response = client.table("room_invites").select(
            "*, rooms(*)"
        ).eq("token", invite_token).eq("is_active", True).execute()

        if not invite_response.data:
            return {"error": "Invalid or expired invitation token."}

        invite = invite_response.data[0]
        room = invite.get("rooms", {})

        # Check if invite is still valid
        if invite["uses"] >= invite["max_uses"]:
            return {"error": "This invitation has reached its maximum uses."}

        # Check if already a member
        existing = client.table("room_members").select("status").eq(
            "room_id", room["id"]
        ).eq("profile_id", profile_id).execute()

        if existing.data:
            status = existing.data[0].get("status")
            if status == "approved":
                return {"error": "You're already a member of this room."}
            elif status == "pending":
                return {"error": "Your join request is pending approval."}

        # Create membership request
        member_data = {
            "room_id": room["id"],
            "profile_id": profile_id,
            "status": "pending",
            "invited_by": invite["created_by"],
            "invite_token": invite_token
        }

        # For Personal rooms, include assistant_profile_id
        if room.get("room_type") == "personal" and assistant_profile_id:
            member_data["assistant_profile_id"] = assistant_profile_id

        response = client.table("room_members").insert(member_data).execute()

        if response.data:
            # Increment invite uses
            client.table("room_invites").update({
                "uses": invite["uses"] + 1
            }).eq("id", invite["id"]).execute()

            # Log action
            client.rpc("log_room_action", {
                "p_room_id": room["id"],
                "p_actor_id": profile_id,
                "p_action": "member_joined",
                "p_details": {"via_invite": invite_token[:8] + "..."}
            }).execute()

            return {
                "success": True,
                "room": {
                    "id": room["id"],
                    "name": room["name"],
                    "room_type": room.get("room_type")
                },
                "status": "pending",
                "message": f"Join request sent to '{room['name']}'! Waiting for admin approval.",
                "next_step": "The room admin will approve your request."
            }

        return {"error": "Failed to join room"}

    except Exception as e:
        return {"error": f"Error joining room: {e}"}


@mcp.tool
def get_pending_approvals(room_id: str, admin_id: str) -> dict:
    """
    Get list of members waiting for approval (admin only).

    Args:
        room_id: Room UUID
        admin_id: Your profile ID (must be admin/owner)

    Returns:
        List of pending members
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Check if user is admin
        is_admin = client.rpc("is_room_admin", {
            "p_room_id": room_id,
            "p_profile_id": admin_id
        }).execute()

        if not is_admin.data:
            return {"error": "Only room admins can view pending approvals."}

        # Get pending members using the view
        response = client.table("room_pending_approvals").select("*").eq("room_id", room_id).execute()

        if not response.data:
            return {
                "pending_count": 0,
                "pending": [],
                "message": "No pending approvals."
            }

        return {
            "pending_count": len(response.data),
            "pending": [
                {
                    "profile_id": p["profile_id"],
                    "name": p["member_name"],
                    "title": p["member_title"],
                    "email": p["member_email"],
                    "bio": p.get("member_bio", "")[:100],
                    "invited_by": p.get("invited_by_name"),
                    "requested_at": p["requested_at"]
                }
                for p in response.data
            ],
            "next_step": "Use approve_member(room_id, profile_id) or reject_member(room_id, profile_id)"
        }

    except Exception as e:
        return {"error": f"Error fetching pending: {e}"}


@mcp.tool
def approve_member(
    room_id: str,
    profile_id: str,
    admin_id: str,
    role: str = "member"
) -> dict:
    """
    Approve a pending member (admin only).

    Args:
        room_id: Room UUID
        profile_id: Profile ID of the person to approve
        admin_id: Your profile ID (must be admin/owner)
        role: Role to assign - "member" or "admin" (default: member)

    Returns:
        Confirmation
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Check if user is admin
        is_admin = client.rpc("is_room_admin", {
            "p_room_id": room_id,
            "p_profile_id": admin_id
        }).execute()

        if not is_admin.data:
            return {"error": "Only room admins can approve members."}

        # Update member status
        response = client.table("room_members").update({
            "status": "approved",
            "role": role,
            "joined_at": "now()"
        }).eq("room_id", room_id).eq("profile_id", profile_id).eq("status", "pending").execute()

        if response.data:
            # Get member name for message
            profile_response = client.table("profiles").select("name").eq("id", profile_id).execute()
            member_name = profile_response.data[0]["name"] if profile_response.data else profile_id

            # Log action
            client.rpc("log_room_action", {
                "p_room_id": room_id,
                "p_actor_id": admin_id,
                "p_action": "member_approved",
                "p_target_id": profile_id,
                "p_details": {"role": role}
            }).execute()

            return {
                "success": True,
                "message": f"✅ {member_name} approved as {role}!",
                "member": {
                    "profile_id": profile_id,
                    "name": member_name,
                    "role": role
                }
            }

        return {"error": f"No pending request found for '{profile_id}'"}

    except Exception as e:
        return {"error": f"Error approving member: {e}"}


@mcp.tool
def offboard_member(
    room_id: str,
    profile_id: str,
    admin_id: str,
    reason: str = "Left company"
) -> dict:
    """
    Remove a member from the room (soft delete with audit log).

    Args:
        room_id: Room UUID
        profile_id: Profile ID of the person to remove
        admin_id: Your profile ID (must be admin/owner)
        reason: Reason for removal (e.g., "Left company", "Role change")

    Returns:
        Confirmation
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Check if user is admin
        is_admin = client.rpc("is_room_admin", {
            "p_room_id": room_id,
            "p_profile_id": admin_id
        }).execute()

        if not is_admin.data:
            return {"error": "Only room admins can remove members."}

        # Update member status
        response = client.table("room_members").update({
            "status": "offboarded",
            "offboarded_at": "now()",
            "offboarded_by": admin_id,
            "offboard_reason": reason
        }).eq("room_id", room_id).eq("profile_id", profile_id).eq("status", "approved").execute()

        if response.data:
            # Get member name
            profile_response = client.table("profiles").select("name").eq("id", profile_id).execute()
            member_name = profile_response.data[0]["name"] if profile_response.data else profile_id

            # Log action
            client.rpc("log_room_action", {
                "p_room_id": room_id,
                "p_actor_id": admin_id,
                "p_action": "member_offboarded",
                "p_target_id": profile_id,
                "p_details": {"reason": reason}
            }).execute()

            return {
                "success": True,
                "message": f"🚪 {member_name} removed from room.",
                "reason": reason,
                "note": "This action is logged in the audit log."
            }

        return {"error": f"Member '{profile_id}' not found or not active."}

    except Exception as e:
        return {"error": f"Error removing member: {e}"}


@mcp.tool
def search_in_room(
    room_id: str,
    query: str,
    profile_id: str,
    max_results: int = 5
) -> dict:
    """
    Search for members within a specific room.

    Args:
        room_id: Room UUID
        query: Search query (skills, role, name)
        profile_id: Your profile ID (for access check)
        max_results: Max results to return (default: 5)

    Returns:
        Matching room members
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # === INPUT VALIDATION ===
    errors = validate_input(
        room_id=("uuid", room_id, "Room ID", True),
        query=("query", query, "Search query", True),
        profile_id=("profile_id", profile_id, "Profile ID", True),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Validate max_results
    if max_results < 1 or max_results > 50:
        return {"error": "max_results must be between 1 and 50."}

    # Sanitize query
    query = sanitize_text(query)

    try:
        client = get_supabase()

        # Check if user is a member
        is_member = client.rpc("is_room_member", {
            "p_room_id": room_id,
            "p_profile_id": profile_id
        }).execute()

        if not is_member.data:
            return {"error": "You must be a room member to search."}

        # Get room info
        room_response = client.table("rooms").select("name, room_type").eq("id", room_id).execute()
        room_name = room_response.data[0]["name"] if room_response.data else "Unknown"

        # Get active members
        members_response = client.table("room_active_members").select("*").eq("room_id", room_id).execute()

        if not members_response.data:
            return {
                "query": query,
                "room": room_name,
                "matches_found": 0,
                "results": []
            }

        # Search logic
        query_lower = query.lower()
        matches = []

        for m in members_response.data:
            score = 0
            reasons = []

            # Check name
            if query_lower in (m.get("member_name") or "").lower():
                score += 2
                reasons.append("Name match")

            # Check title/role
            if query_lower in (m.get("member_title") or "").lower():
                score += 2
                reasons.append("Role match")

            # Check skills
            for skill in (m.get("member_skills") or []):
                if query_lower in skill.lower():
                    score += 3
                    reasons.append(f"Skill: {skill}")

            # Check bio
            if query_lower in (m.get("member_bio") or "").lower():
                score += 1
                reasons.append("Bio match")

            # Check tags
            for tag in (m.get("member_tags") or []):
                if query_lower in tag.lower():
                    score += 1
                    reasons.append(f"Tag: {tag}")

            if score > 0:
                matches.append({
                    "profile_id": m["profile_id"],
                    "name": m["member_name"],
                    "title": m.get("member_title"),
                    "role_in_room": m["role"],
                    "score": score,
                    "reasons": reasons
                })

        # Sort by score
        matches.sort(key=lambda x: x["score"], reverse=True)

        return {
            "query": query,
            "room": room_name,
            "matches_found": len(matches),
            "results": matches[:max_results]
        }

    except Exception as e:
        return {"error": f"Error searching: {e}"}


@mcp.tool
def list_room_members(room_id: str, profile_id: str) -> dict:
    """
    List all active members of a room.

    Args:
        room_id: Room UUID
        profile_id: Your profile ID (for access check)

    Returns:
        List of room members
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Check if user is a member
        is_member = client.rpc("is_room_member", {
            "p_room_id": room_id,
            "p_profile_id": profile_id
        }).execute()

        if not is_member.data:
            return {"error": "You must be a room member to view members."}

        # Get active members
        response = client.table("room_active_members").select("*").eq("room_id", room_id).execute()

        if not response.data:
            return {
                "members_count": 0,
                "members": [],
                "room": "Unknown"
            }

        room_name = response.data[0].get("room_name", "Unknown")

        return {
            "room": room_name,
            "members_count": len(response.data),
            "members": [
                {
                    "profile_id": m["profile_id"],
                    "name": m["member_name"],
                    "title": m.get("member_title"),
                    "role": m["role"],
                    "joined_at": m.get("joined_at"),
                    # For Personal rooms, show assistant info
                    "assistant_name": m.get("assistant_name")
                }
                for m in response.data
            ]
        }

    except Exception as e:
        return {"error": f"Error listing members: {e}"}


# ============== ENTERPRISE ROOMS: MESSAGING ==============

@mcp.tool
def check_room_inbox(
    profile_id: str,
    assistant_id: str = "",
    room_id: str = ""
) -> dict:
    """
    Check for unread messages in your room inbox.

    Args:
        profile_id: Your profile ID
        assistant_id: For Personal rooms - your assistant UUID (optional)
        room_id: Filter to specific room (optional)

    Returns:
        List of unread messages
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Use the SQL function
        params = {"p_profile_id": profile_id}
        if assistant_id:
            params["p_assistant_id"] = assistant_id
        if room_id:
            params["p_room_id"] = room_id

        response = client.rpc("check_inbox", params).execute()

        if not response.data:
            return {
                "unread_count": 0,
                "messages": [],
                "message": "📭 No unread messages."
            }

        messages = response.data

        # Format for display
        formatted = []
        for m in messages:
            priority_icon = {
                "urgent": "🔴",
                "high": "🟠",
                "normal": "⚪",
                "low": "⚫"
            }.get(m.get("priority"), "⚪")

            formatted.append({
                "id": m["message_id"],
                "priority": f"{priority_icon} {m.get('priority', 'normal').upper()}",
                "from": m.get("sender_name"),
                "from_assistant": m.get("sender_assistant"),
                "room": m.get("room_name"),
                "subject": m.get("subject"),
                "type": m.get("message_type"),
                "deadline": m.get("deadline"),
                "sent_at": m.get("sent_at")
            })

        return {
            "unread_count": len(formatted),
            "messages": formatted,
            "next_step": "Use read_room_message(message_id) to open a message."
        }

    except Exception as e:
        return {"error": f"Error checking inbox: {e}"}


@mcp.tool
def read_room_message(message_id: str, profile_id: str) -> dict:
    """
    Read a message and mark it as read.

    Args:
        message_id: Message UUID
        profile_id: Your profile ID

    Returns:
        Full message content
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Get message
        response = client.table("room_messages").select(
            "*, rooms(name, room_type)"
        ).eq("id", message_id).execute()

        if not response.data:
            return {"error": "Message not found."}

        msg = response.data[0]
        room = msg.get("rooms", {})

        # Get sender info
        sender_response = client.table("profiles").select("name").eq("id", msg["from_profile_id"]).execute()
        sender_name = sender_response.data[0]["name"] if sender_response.data else "Unknown"

        # Mark as read
        client.rpc("mark_message_read", {
            "p_message_id": message_id,
            "p_profile_id": profile_id
        }).execute()

        # Determine available actions
        actions = ["acknowledge"]
        if msg["message_type"] in ["request", "reminder"]:
            actions = ["respond", "acknowledge", "remind_later"]

        return {
            "message": {
                "id": msg["id"],
                "room": room.get("name"),
                "from": sender_name,
                "from_assistant": msg.get("from_assistant_name"),
                "type": msg["message_type"],
                "subject": msg["subject"],
                "body": msg["body"],
                "priority": msg.get("priority", "normal"),
                "deadline": msg.get("deadline"),
                "template": msg.get("template"),
                "sent_at": msg["created_at"]
            },
            "status": "read",
            "actions": actions,
            "next_step": "Use respond_to_room_message(message_id, response) to reply." if "respond" in actions else None
        }

    except Exception as e:
        return {"error": f"Error reading message: {e}"}


@mcp.tool
def send_room_message(
    room_id: str,
    from_profile_id: str,
    subject: str,
    body: str,
    message_type: str = "info",
    to_profile_id: str = "",
    from_assistant_name: str = "",
    priority: str = "normal",
    deadline: str = "",
    template: dict = None
) -> dict:
    """
    Send a message in a room (broadcast or to specific person).

    Args:
        room_id: Room UUID
        from_profile_id: Your profile ID
        subject: Message subject
        body: Message content
        message_type: "info", "reminder", "request", "announcement"
        to_profile_id: Specific recipient (empty = broadcast to all)
        from_assistant_name: Your assistant's display name
        priority: "low", "normal", "high", "urgent"
        deadline: ISO datetime for request deadline (optional)
        template: Expected response format for requests (optional)

    Returns:
        Confirmation with recipient count
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # === INPUT VALIDATION ===
    errors = validate_input(
        room_id=("uuid", room_id, "Room ID", True),
        from_profile_id=("profile_id", from_profile_id, "Your profile ID", True),
        subject=("subject", subject, "Subject", True),
        body=("body", body, "Message body", True),
        to_profile_id=("profile_id", to_profile_id, "Recipient ID"),
        from_assistant_name=("name", from_assistant_name, "Assistant name"),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Validate message_type and priority
    valid_types = ["info", "reminder", "request", "announcement"]
    if message_type not in valid_types:
        return {"error": f"Invalid message_type. Must be one of: {', '.join(valid_types)}"}

    valid_priorities = ["low", "normal", "high", "urgent"]
    if priority not in valid_priorities:
        return {"error": f"Invalid priority. Must be one of: {', '.join(valid_priorities)}"}

    # Check for prompt injection in message content
    is_safe, error_msg, _ = check_injection_and_sanitize(subject, "subject")
    if not is_safe:
        return {"error": error_msg}

    is_safe, error_msg, _ = check_injection_and_sanitize(body, "body")
    if not is_safe:
        return {"error": error_msg}

    # Sanitize inputs (with injection protection)
    subject = sanitize_text(subject, check_injection=True)
    body = sanitize_text(body, check_injection=True)
    from_assistant_name = sanitize_text(from_assistant_name, check_injection=True) if from_assistant_name else ""

    try:
        client = get_supabase()

        # Check if user is a member
        is_member = client.rpc("is_room_member", {
            "p_room_id": room_id,
            "p_profile_id": from_profile_id
        }).execute()

        if not is_member.data:
            return {"error": "You must be a room member to send messages."}

        # Use the SQL function
        params = {
            "p_room_id": room_id,
            "p_from_profile_id": from_profile_id,
            "p_from_assistant_name": from_assistant_name or "AI Assistant",
            "p_message_type": message_type,
            "p_subject": subject,
            "p_body": body,
            "p_priority": priority
        }

        if to_profile_id:
            params["p_to_profile_id"] = to_profile_id
        if deadline:
            params["p_deadline"] = deadline
        if template:
            params["p_template"] = template

        response = client.rpc("send_room_message", params).execute()

        if response.data:
            message_id = response.data

            # Get recipient count
            recipients = client.table("message_recipients").select("id").eq("message_id", message_id).execute()
            recipient_count = len(recipients.data) if recipients.data else 0

            return {
                "success": True,
                "message_id": message_id,
                "subject": subject,
                "type": message_type,
                "recipients": recipient_count,
                "message": f"📤 Message sent to {recipient_count} {'person' if recipient_count == 1 else 'people'}!",
                "next_step": "Use get_message_status(message_id) to track responses." if message_type == "request" else None
            }

        return {"error": "Failed to send message"}

    except Exception as e:
        return {"error": f"Error sending message: {e}"}


@mcp.tool
def respond_to_room_message(
    message_id: str,
    from_profile_id: str,
    response_body: str,
    from_assistant_name: str = "",
    structured_data: dict = None
) -> dict:
    """
    Respond to a message/request.

    Args:
        message_id: Original message UUID
        from_profile_id: Your profile ID
        response_body: Your response text
        from_assistant_name: Your assistant's display name
        structured_data: Structured response data (for requests with templates)

    Returns:
        Confirmation
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    # === INPUT VALIDATION ===
    errors = validate_input(
        message_id=("uuid", message_id, "Message ID", True),
        from_profile_id=("profile_id", from_profile_id, "Your profile ID", True),
        response_body=("body", response_body, "Response", True),
        from_assistant_name=("name", from_assistant_name, "Assistant name"),
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    # Check for prompt injection in response
    is_safe, error_msg, _ = check_injection_and_sanitize(response_body, "response")
    if not is_safe:
        return {"error": error_msg}

    # Sanitize inputs (with injection protection)
    response_body = sanitize_text(response_body, check_injection=True)
    from_assistant_name = sanitize_text(from_assistant_name, check_injection=True) if from_assistant_name else ""

    try:
        client = get_supabase()

        # Use the SQL function
        response = client.rpc("respond_to_message", {
            "p_original_message_id": message_id,
            "p_from_profile_id": from_profile_id,
            "p_from_assistant_name": from_assistant_name or "AI Assistant",
            "p_body": response_body,
            "p_structured_data": structured_data
        }).execute()

        if response.data:
            return {
                "success": True,
                "response_id": response.data,
                "message": "✅ Response sent!",
                "status": "responded"
            }

        return {"error": "Failed to send response"}

    except Exception as e:
        return {"error": f"Error responding: {e}"}


@mcp.tool
def get_message_status(message_id: str, from_profile_id: str) -> dict:
    """
    Get status of a sent message (who read, responded).

    Args:
        message_id: Message UUID
        from_profile_id: Your profile ID (must be sender)

    Returns:
        Status breakdown
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Verify sender
        msg_check = client.table("room_messages").select("from_profile_id, subject").eq("id", message_id).execute()
        if not msg_check.data or msg_check.data[0]["from_profile_id"] != from_profile_id:
            return {"error": "You can only check status of your own messages."}

        subject = msg_check.data[0]["subject"]

        # Get status
        status = client.rpc("get_message_status", {"p_message_id": message_id}).execute()

        if status.data:
            s = status.data[0] if isinstance(status.data, list) else status.data
            total = s.get("total_recipients", 0)
            responded = s.get("responded_count", 0)
            read = s.get("read_count", 0)
            unread = s.get("unread_count", 0)

            return {
                "message_id": message_id,
                "subject": subject,
                "status": {
                    "total_recipients": total,
                    "responded": responded,
                    "read": read,
                    "unread": unread,
                    "ignored": s.get("ignored_count", 0)
                },
                "progress": f"{responded}/{total} responded ({int(responded/total*100) if total > 0 else 0}%)",
                "summary": f"✅ {responded} responded | 👀 {read} read | ❌ {unread} unread"
            }

        return {"error": "Status not available"}

    except Exception as e:
        return {"error": f"Error getting status: {e}"}


@mcp.tool
def summarize_responses(message_id: str, from_profile_id: str) -> dict:
    """
    Get all responses to a message and aggregate structured data.

    Args:
        message_id: Original message UUID
        from_profile_id: Your profile ID (must be sender)

    Returns:
        Aggregated summary of all responses with structured data
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Verify sender
        msg_check = client.table("room_messages").select("from_profile_id, subject, template").eq("id", message_id).execute()
        if not msg_check.data or msg_check.data[0]["from_profile_id"] != from_profile_id:
            return {"error": "You can only summarize responses to your own messages."}

        subject = msg_check.data[0]["subject"]
        expected_template = msg_check.data[0].get("template")

        # Get all responses
        responses = client.rpc("get_message_responses", {"p_message_id": message_id}).execute()

        if not responses.data:
            return {
                "message_id": message_id,
                "subject": subject,
                "total_responses": 0,
                "message": "No responses yet."
            }

        # Process responses
        response_list = []
        aggregated_data = {}
        numeric_sums = {}
        text_values = {}

        for r in responses.data:
            response_list.append({
                "from": r.get("from_name"),
                "assistant": r.get("from_assistant"),
                "body": r.get("body"),
                "responded_at": r.get("responded_at")
            })

            # Aggregate structured data
            structured = r.get("structured_data")
            if structured and isinstance(structured, dict):
                for key, value in structured.items():
                    if isinstance(value, (int, float)):
                        # Sum numeric values
                        if key not in numeric_sums:
                            numeric_sums[key] = {"sum": 0, "count": 0, "values": []}
                        numeric_sums[key]["sum"] += value
                        numeric_sums[key]["count"] += 1
                        numeric_sums[key]["values"].append({"from": r.get("from_name"), "value": value})
                    elif isinstance(value, str):
                        # Collect text values
                        if key not in text_values:
                            text_values[key] = []
                        text_values[key].append({"from": r.get("from_name"), "value": value})

        # Build aggregated summary
        for key, data in numeric_sums.items():
            aggregated_data[key] = {
                "total": data["sum"],
                "count": data["count"],
                "average": round(data["sum"] / data["count"], 2) if data["count"] > 0 else 0,
                "breakdown": data["values"]
            }

        for key, values in text_values.items():
            aggregated_data[key] = {
                "responses": values
            }

        # Build summary string
        if aggregated_data:
            agg_parts = []
            for k, v in aggregated_data.items():
                if 'total' in v:
                    agg_parts.append(f"{k}: {v['total']}")
                elif 'responses' in v:
                    agg_parts.append(f"{k}: {len(v['responses'])} responses")
            summary_text = f"📊 {len(response_list)} responses received. Aggregated: {', '.join(agg_parts)}"
        else:
            summary_text = f"📊 {len(response_list)} responses received. No structured data to aggregate."

        return {
            "message_id": message_id,
            "subject": subject,
            "total_responses": len(response_list),
            "responses": response_list,
            "aggregated": aggregated_data if aggregated_data else None,
            "summary": summary_text
        }

    except Exception as e:
        return {"error": f"Error summarizing responses: {e}"}


@mcp.tool
def get_room_audit_log(room_id: str, admin_id: str, limit: int = 20) -> dict:
    """
    Get audit log of room actions (admin only).

    Args:
        room_id: Room UUID
        admin_id: Your profile ID (must be admin/owner)
        limit: Max entries to return (default: 20)

    Returns:
        List of audit log entries
    """
    if not get_supabase():
        return {"error": "Database not connected."}

    try:
        client = get_supabase()

        # Check if user is admin
        is_admin = client.rpc("is_room_admin", {
            "p_room_id": room_id,
            "p_profile_id": admin_id
        }).execute()

        if not is_admin.data:
            return {"error": "Only room admins can view audit logs."}

        # Get audit log
        response = client.table("room_audit_log").select(
            "*, profiles!room_audit_log_actor_id_fkey(name)"
        ).eq("room_id", room_id).order("created_at", desc=True).limit(limit).execute()

        if not response.data:
            return {
                "entries_count": 0,
                "entries": [],
                "message": "No audit log entries."
            }

        return {
            "entries_count": len(response.data),
            "entries": [
                {
                    "action": e["action"],
                    "actor": e.get("profiles", {}).get("name", e["actor_id"]),
                    "target": e.get("target_id"),
                    "details": e.get("details", {}),
                    "timestamp": e["created_at"]
                }
                for e in response.data
            ]
        }

    except Exception as e:
        return {"error": f"Error fetching audit log: {e}"}


# ============== PROMPTS: ENTERPRISE ROOMS ==============

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
