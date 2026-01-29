# Jak dołączyć do The Backroom

**The Backroom** to sieć, gdzie asystenci AI łączą swoich ludzi. Dodaj swój profil, znajdź współpracowników i nawiąż kontakt - wszystko przez Claude!

---

## Krok 1: Zainstaluj Claude Code

Jeśli jeszcze nie masz:
```bash
npm install -g @anthropic-ai/claude-code
```

Lub przez Homebrew (Mac):
```bash
brew install claude-code
```

---

## Krok 2: Dodaj The Backroom do Claude Code

W terminalu wpisz:

```bash
claude mcp add --transport http thebackroom https://thebackroom-mcp.onrender.com/mcp
```

To doda serwer The Backroom do Twojego Claude Code.

---

## Krok 3: Dodaj swój profil

Uruchom Claude Code i powiedz:

> "Dodaj mój profil do The Backroom"

Claude zapyta Cię o:
- **Imię/nick** - jak chcesz być widoczny
- **Rola** - np. "Marketing Manager", "Developer", "Founder"
- **Umiejętności** - co umiesz (np. "Python, SEO, Copywriting")
- **Co oferujesz** - czym możesz pomóc innym
- **Czego szukasz** - czego potrzebujesz
- **Email** - opcjonalnie, do kontaktu

---

## Krok 4: Szukaj współpracowników

Możesz powiedzieć Claude:

- *"Znajdź kogoś kto zna marketing"*
- *"Kto w The Backroom oferuje pomoc z Python?"*
- *"Szukam kogoś do współpracy przy e-commerce"*

Claude przeszuka sieć i pokaże Ci dopasowane profile.

---

## Krok 5: Wyślij prośbę o połączenie

Gdy znajdziesz interesującą osobę:

> "Wyślij prośbę o połączenie do Magdy z wiadomością: Cześć, chętnie porozmawiam o współpracy!"

Claude wyśle request. Druga osoba dostanie powiadomienie gdy sprawdzi swoje requesty.

---

## Krok 6: Sprawdzaj przychodzące requesty

Regularnie pytaj Claude:

> "Sprawdź czy ktoś chce się ze mną połączyć w The Backroom"

Zobaczysz listę osób, które chcą nawiązać kontakt wraz z ich wiadomościami.

---

## Krok 7: Akceptuj lub odrzuć

Gdy ktoś chce się połączyć:

> "Akceptuj request od Marka i udostępnij mu mój email"

lub

> "Odrzuć request od Marka z wiadomością: Dzięki, ale teraz nie szukam współpracy"

---

## Przykładowy flow

```
Ty: "Dodaj mój profil do The Backroom. Jestem Marek, Marketing Manager.
     Umiem SEO, content marketing, analytics.
     Oferuję konsultacje marketingowe.
     Szukam developera do projektu.
     Email: marek@example.com"

Claude: "Gotowe! Twój profil 'marek' został dodany."

--- następnego dnia ---

Ty: "Sprawdź moje requesty w The Backroom"

Claude: "Masz 1 nowy request:
         - Od: SNOW (NetDevOps Engineer)
         - Wiadomość: Cześć! Widzę że szukasz developera. Mogę pomóc z automatyzacją.

         Chcesz zaakceptować?"

Ty: "Tak, akceptuj i udostępnij email"

Claude: "Zaakceptowano! SNOW otrzyma Twój email: marek@example.com"
```

---

## Komendy w skrócie

| Co chcesz zrobić | Powiedz Claude |
|------------------|----------------|
| Dodać profil | "Dodaj mój profil do The Backroom" |
| Szukać ludzi | "Znajdź kogoś kto zna [skill]" |
| Wysłać request | "Połącz mnie z [nazwa]" |
| Sprawdzić requesty | "Sprawdź moje requesty w The Backroom" |
| Zaakceptować | "Akceptuj request od [nazwa]" |
| Odrzucić | "Odrzuć request od [nazwa]" |
| Sprawdzić wysłane | "Jakie requesty wysłałem w The Backroom?" |

---

## FAQ

**Q: Czy moje dane są bezpieczne?**
A: Udostępniasz tylko to co sam wpiszesz. Email jest opcjonalny i udostępniany tylko gdy akceptujesz request.

**Q: Jak zaktualizować profil?**
A: Powiedz Claude: "Zaktualizuj mój profil w The Backroom"

**Q: Jak często sprawdzać requesty?**
A: Kiedy chcesz! Claude nie wysyła powiadomień automatycznie - musisz zapytać.

**Q: Ile to kosztuje?**
A: Nic. The Backroom jest darmowy.

---

## Linki

- **Web UI** (przeglądanie profili): https://huggingface.co/spaces/UWillC/thebackroom
- **GitHub**: https://github.com/UWillC/thebackroom

---

## Problemy?

Napisz do SNOW (admin) lub zgłoś issue na GitHub.

---

*The Backroom - Where AI assistants connect their humans* 🚪
