# Deploy: Enterprise Rooms

> Data: 2026-02-06
> Status: GOTOWE DO WDROŻENIA

---

## Pliki do wdrożenia

| # | Plik | Co zawiera | Zależności |
|---|------|------------|------------|
| 1 | `enterprise_rooms.sql` | rooms, room_members, room_invites, room_audit_log | profiles (istniejąca) |
| 2 | `enterprise_rooms_messaging.sql` | room_messages, message_recipients, message_templates | enterprise_rooms.sql |

---

## Deploy Order

### Krok 1: Enterprise Rooms (podstawa)

```bash
# W Supabase SQL Editor wykonaj:
# 1. Otwórz: enterprise_rooms.sql
# 2. Uruchom cały skrypt (Ctrl+Enter)
```

**Weryfikacja po Krok 1:**
```sql
-- Sprawdź tabele
SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'room%';
-- Oczekiwane: rooms, room_members, room_invites, room_audit_log

-- Sprawdź widoki
SELECT viewname FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'room%' OR viewname = 'my_rooms';
-- Oczekiwane: room_active_members, room_pending_approvals, my_rooms

-- Sprawdź funkcje
SELECT proname FROM pg_proc WHERE proname LIKE '%room%' OR proname LIKE 'generate_room%' OR proname LIKE 'is_room%' OR proname LIKE 'log_room%';
-- Oczekiwane: generate_room_slug, is_room_admin, is_room_member, log_room_action
```

### Krok 2: Messaging System

```bash
# W Supabase SQL Editor wykonaj:
# 1. Otwórz: enterprise_rooms_messaging.sql
# 2. Uruchom cały skrypt (Ctrl+Enter)
```

**Weryfikacja po Krok 2:**
```sql
-- Sprawdź tabele
SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'room_message%' OR tablename = 'message%';
-- Oczekiwane: room_messages, message_recipients, message_templates

-- Sprawdź widoki
SELECT viewname FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'inbox%' OR viewname LIKE 'message%';
-- Oczekiwane: inbox_unread, message_status_summary

-- Sprawdź funkcje
SELECT proname FROM pg_proc WHERE proname IN ('send_room_message', 'check_inbox', 'mark_message_read', 'respond_to_message', 'get_message_status', 'get_message_responses');
-- Oczekiwane: wszystkie 6 funkcji
```

---

## Quick Test (po wdrożeniu)

### Test 1: Utwórz pokój

```sql
-- 1. Utwórz pokój (jako snow)
INSERT INTO rooms (name, slug, description, owner_id)
VALUES ('Test Corp', 'test-corp', 'Testowy pokój firmowy', 'snow');

-- 2. Dodaj ownera jako członka
INSERT INTO room_members (room_id, profile_id, role, status, joined_at)
SELECT id, 'snow', 'owner', 'approved', NOW()
FROM rooms WHERE slug = 'test-corp';

-- 3. Zaloguj akcję
SELECT log_room_action(
    (SELECT id FROM rooms WHERE slug = 'test-corp'),
    'snow',
    'room_created',
    NULL,
    '{"source": "test"}'::jsonb
);

-- 4. Sprawdź
SELECT * FROM my_rooms WHERE slug = 'test-corp';
```

### Test 2: Zaproś i zatwierdź członka

```sql
-- 1. Utwórz zaproszenie
INSERT INTO room_invites (room_id, created_by, max_uses, note)
SELECT id, 'snow', 5, 'Dla zespołu'
FROM rooms WHERE slug = 'test-corp'
RETURNING token;
-- Zapisz token!

-- 2. Symuluj dołączenie (jako 'tomek' lub inny istniejący profil)
INSERT INTO room_members (room_id, profile_id, status, invited_by, invite_token)
SELECT
    r.id,
    'jakub',  -- zmień na istniejący profile_id
    'pending',
    'snow',
    ri.token
FROM rooms r
JOIN room_invites ri ON ri.room_id = r.id
WHERE r.slug = 'test-corp'
LIMIT 1;

-- 3. Sprawdź pending
SELECT * FROM room_pending_approvals WHERE room_slug = 'test-corp';

-- 4. Zatwierdź
UPDATE room_members
SET status = 'approved', joined_at = NOW()
WHERE room_id = (SELECT id FROM rooms WHERE slug = 'test-corp')
  AND profile_id = 'jakub';

-- 5. Sprawdź aktywnych
SELECT * FROM room_active_members WHERE room_slug = 'test-corp';
```

### Test 3: Messaging

```sql
-- 1. Wyślij broadcast (jako snow)
SELECT send_room_message(
    (SELECT id FROM rooms WHERE slug = 'test-corp'),
    'snow',
    'COO Bot',
    'request',
    'Test Request',
    'To jest testowa wiadomość.',
    NULL,  -- broadcast
    NULL,
    '{"field1": "text"}'::jsonb,
    NOW() + INTERVAL '1 day',
    'high'
);

-- 2. Sprawdź inbox (jako jakub)
SELECT * FROM check_inbox('jakub');

-- 3. Sprawdź status (jako snow)
SELECT * FROM message_status_summary WHERE from_profile_id = 'snow';
```

### Cleanup (po testach)

```sql
-- Usuń testowe dane
DELETE FROM rooms WHERE slug = 'test-corp';
-- CASCADE usunie: room_members, room_invites, room_audit_log, room_messages
```

---

## Nowe tabele - podsumowanie

| Tabela | Opis | Kluczowe kolumny |
|--------|------|------------------|
| `rooms` | Pokoje firmowe | id, name, slug, owner_id, settings, status |
| `room_members` | Członkowie | room_id, profile_id, role, status |
| `room_invites` | Tokeny zaproszeń | room_id, token, max_uses, expires_at |
| `room_audit_log` | Historia akcji | room_id, actor_id, action, target_id |
| `room_messages` | Wiadomości | room_id, from/to, message_type, subject, body |
| `message_recipients` | Status odbiorców | message_id, profile_id, status |
| `message_templates` | Szablony | room_id, name, subject_template, body_template |

---

## Nowe funkcje SQL

| Funkcja | Opis | Użycie |
|---------|------|--------|
| `generate_room_slug(name)` | Generuje unikalny slug | Auto w MCP |
| `is_room_admin(room_id, profile_id)` | Czy user jest adminem | Weryfikacja uprawnień |
| `is_room_member(room_id, profile_id)` | Czy user jest członkiem | Weryfikacja dostępu |
| `log_room_action(...)` | Loguje do audit | Każda akcja admina |
| `send_room_message(...)` | Wysyła wiadomość | Broadcast lub 1:1 |
| `check_inbox(profile_id)` | Nieprzeczytane | Auto na starcie |
| `mark_message_read(...)` | Oznacz jako przeczytane | Po otwarciu |
| `respond_to_message(...)` | Odpowiedz | Na request |
| `get_message_status(...)` | Status wysłanej | Dla sendera |
| `get_message_responses(...)` | Lista odpowiedzi | Dla sendera |

---

## Następne kroki

Po wdrożeniu SQL:

1. [ ] **MCP Tools** - implementacja w `server.py`
2. [ ] **Testy MCP** - pełny flow przez Claude Code
3. [ ] **Gradio UI** - "My Rooms" tab

---

*Deploy guide v1.0 - 2026-02-06*
