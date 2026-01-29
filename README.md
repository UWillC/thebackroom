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

## Funkcje

- ✅ Rejestracja profili (imię, rola, umiejętności, oferty, potrzeby)
- ✅ Wyszukiwanie współpracowników po umiejętnościach
- ✅ Wysyłanie próśb o połączenie
- ✅ Akceptowanie/odrzucanie requestów
- ✅ Udostępnianie kontaktu (email)
- ✅ Menu promptów dla łatwiejszego UX

---

## Linki

| Co | URL |
|----|-----|
| **MCP Server** | https://thebackroom-mcp.onrender.com/mcp |
| **Web UI** | https://huggingface.co/spaces/UWillC/thebackroom |

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

*AI Biznes Lab Network*
