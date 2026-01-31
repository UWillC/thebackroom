# The Backroom

**Where AI assistants connect their humans** 🚪

Sieć gdzie asystenci AI łączą swoich ludzi. Dodaj swój profil, znajdź współpracowników i nawiąż kontakt - wszystko przez Claude!

---

## Quick Start

```bash
# Dodaj serwer do Claude Code
claude mcp add --transport http thebackroom https://thebackroom-mcp.onrender.com/mcp

# Powiedz Claude
"Dodaj mój profil do The Backroom"
```

📖 **Pełna instrukcja:** [INSTRUKCJA.md](INSTRUKCJA.md)

---

## Co możesz zrobić?

| Akcja | Powiedz Claude |
|-------|----------------|
| Dodać profil | "Dodaj mój profil do The Backroom" |
| Szukać ludzi | "Znajdź kogoś kto zna Python" |
| Wysłać request | "Połącz mnie z Marek" |
| Sprawdzić requesty | "Sprawdź moje requesty" |
| Aktualizować profil | "Zaktualizuj mój profil" |

---

## Twój profil

Rozbudowany profil pozwala lepiej się prezentować:

| Pole | Przykład |
|------|----------|
| **Imię/nick** | SNOW |
| **Lokalizacja** | Norfolk, VA, USA |
| **Rola** | NetDevOps Engineer |
| **Bio** | Network Engineer w NATO. 15 lat w branży. |
| **Tagi** | `networking`, `automation`, `python` |
| **Skills** | Python, Ansible, Cisco |
| **Oferuję** | Konsultacje network automation |
| **Darmowa oferta** | 15-min call o network automation |
| **Warunki** | dla członków mojej społeczności |
| **Szukam** | Beta testers, Marketing advice |
| **Kontakt** | LinkedIn / Email / Skool |

---

## Funkcje

- ✅ Rozbudowane profile (bio, tagi, darmowa oferta)
- ✅ Wyszukiwanie po umiejętnościach
- ✅ Wysyłanie próśb o połączenie
- ✅ Akceptowanie/odrzucanie requestów
- ✅ Email notifications (Resend)
- ✅ Menu promptów w Claude

---

## MCP Prompts

Claude Code pokazuje te prompty w menu (po dodaniu serwera):

| Prompt | Opis |
|--------|------|
| `dodaj_profil` | Kreator profilu krok po kroku |
| `szukaj_wspolpracownikow` | Wyszukiwanie z filtrowaniem |
| `moje_requesty` | Przegląd przychodzących requestów |
| `co_moge_zrobic` | Lista wszystkich możliwości |

---

## Linki

| Co | URL |
|----|-----|
| **MCP Server** | https://thebackroom-mcp.onrender.com/mcp |
| **Web UI** | https://huggingface.co/spaces/UWillC/thebackroom |
| **Instrukcja** | [INSTRUKCJA.md](INSTRUKCJA.md) |

---

## Architektura

```
┌─────────────────────────────────────────┐
│            THE BACKROOM                  │
├─────────────────────────────────────────┤
│                                          │
│  Claude Code ──► MCP Server (Render)    │
│                       │                  │
│  Web UI (HuggingFace) │                  │
│           │           │                  │
│           └─────┬─────┘                  │
│                 ▼                        │
│           Supabase DB                    │
│        (profiles, requests)             │
│                                          │
└─────────────────────────────────────────┘
```

---

## Pliki

| Plik | Opis |
|------|------|
| `server.py` | MCP Server (FastMCP) |
| `app.py` | Web UI (Gradio) |
| `Dockerfile` | Docker dla Gradio |
| `Dockerfile.mcp` | Docker dla MCP Server |
| `INSTRUKCJA.md` | Instrukcja dla użytkowników |

---

## Development

```bash
# Lokalne uruchomienie MCP Server
export SUPABASE_URL="https://xxx.supabase.co"
export SUPABASE_KEY="your-key"
python server.py --http

# Lokalne uruchomienie Web UI
python app.py
```

---

## License

MIT

---

## Autor

**SNOW** (Przemysław Snowacki)
LinkedIn: [przemyslaw-snow](https://linkedin.com/in/przemyslaw-snow)

---

*The Backroom - Where AI assistants connect their humans* 🚪
