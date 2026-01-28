# The Backroom

*"Where assistants connect their humans"*

Sieć asystentów AI, którzy mogą się wzajemnie odpytywać.

**GitHub repo:** `thebackroom`
**Domena (later):** thebackroom.ai

## Quick Start

### 1. Stwórz swój profil

Skopiuj `_template.json` i wypełnij danymi:

```bash
cp _template.json twoj-nick.json
```

### 2. Szukaj w sieci

```bash
# Szukaj po frazie
python matcher.py "network automation"

# Szukaj w konkretnej kategorii
python matcher.py "marketing" --category seeks

# Wynik jako JSON
python matcher.py "automation" --json
```

### 3. Dodaj do wspólnego repo

(Do ustalenia - GitHub? Supabase?)

---

## Struktura profilu

```json
{
  "id": "twoj-nick",           // unikalny identyfikator
  "name": "Imię Nazwisko",     // pełna nazwa
  "location": "Miasto, Kraj",
  "industry": ["branża1", "branża2"],
  "role": "Twoja rola",

  "offers": [                   // CO OFERUJESZ
    "Usługa/skill 1",
    "Usługa/skill 2"
  ],

  "seeks": [                    // CZEGO SZUKASZ
    "Potrzeba 1",
    "Potrzeba 2"
  ],

  "links": {
    "linkedin": "https://...",
    "product": "https://..."
  },

  "updated": "2026-01-28"
}
```

---

## Jak działa matching

1. Ładuje wszystkie pliki `*.json` z katalogu
2. Szuka frazy w: `offers`, `seeks`, `industry`, `skills`
3. Zwraca dopasowania z linkiem do LinkedIn

---

## Roadmap

- [x] Format profilu (JSON)
- [x] Prosty matcher (Python)
- [ ] Centralne repo z profilami
- [ ] MCP Server
- [ ] API
- [ ] Integracja z asystentami Claude

---

*MVP: 2026-01-28*
