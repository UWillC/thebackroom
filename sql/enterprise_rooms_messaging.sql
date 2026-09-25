-- ============================================
-- THE BACKROOM: ENTERPRISE ROOMS - MESSAGING
-- Schema v1.0 - 2026-02-06
-- ============================================
-- Requires: enterprise_rooms.sql (run first!)
-- ============================================

-- ============================================
-- 1. TABELA: room_messages (wiadomości A2A)
-- ============================================

CREATE TABLE IF NOT EXISTS room_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Context
    room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,

    -- Sender (human)
    from_profile_id TEXT NOT NULL REFERENCES profiles(id),

    -- Sender assistant (for Personal Rooms OR acting on behalf in Enterprise)
    from_assistant_id UUID REFERENCES assistant_profiles(id),
    from_assistant_name TEXT,              -- "Asystent Szefa", "COO Bot" (display name)

    -- Recipients
    -- Enterprise: to_profile_id = human, to_assistant_id = NULL
    -- Personal: to_profile_id = owner, to_assistant_id = specific assistant
    -- NULL = broadcast do wszystkich approved members
    to_profile_id TEXT REFERENCES profiles(id),
    to_assistant_id UUID REFERENCES assistant_profiles(id),
    to_role TEXT,                          -- NULL, 'admin', 'member' - filtr

    -- Message type
    message_type TEXT NOT NULL CHECK (message_type IN (
        'info',           -- Informacja (bez odpowiedzi)
        'reminder',       -- Przypomnienie (z deadline)
        'request',        -- Prośba o dane/akcję
        'response',       -- Odpowiedź na request
        'announcement'    -- Ogłoszenie od admina
    )),

    -- Content
    subject TEXT NOT NULL,
    body TEXT NOT NULL,

    -- Structured data (dla requests)
    template JSONB,                        -- Template odpowiedzi
    expected_format TEXT,                  -- "JSON", "text", "structured"
    deadline TIMESTAMPTZ,                  -- Deadline na odpowiedź

    -- Reference (dla responses)
    in_reply_to UUID REFERENCES room_messages(id),

    -- Priority
    priority TEXT DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),

    -- Status
    status TEXT DEFAULT 'sent' CHECK (status IN ('draft', 'sent', 'cancelled')),

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    sent_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_messages_room ON room_messages(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_to ON room_messages(to_profile_id);
CREATE INDEX IF NOT EXISTS idx_messages_from ON room_messages(from_profile_id);
CREATE INDEX IF NOT EXISTS idx_messages_type ON room_messages(message_type);
CREATE INDEX IF NOT EXISTS idx_messages_created ON room_messages(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_reply ON room_messages(in_reply_to)
    WHERE in_reply_to IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_deadline ON room_messages(deadline)
    WHERE deadline IS NOT NULL AND status = 'sent';

-- ============================================
-- 2. TABELA: message_recipients (status per odbiorca)
-- ============================================

CREATE TABLE IF NOT EXISTS message_recipients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    message_id UUID NOT NULL REFERENCES room_messages(id) ON DELETE CASCADE,
    profile_id TEXT NOT NULL REFERENCES profiles(id),

    -- For Personal Rooms: which assistant received the message
    assistant_profile_id UUID REFERENCES assistant_profiles(id),

    -- Status
    status TEXT DEFAULT 'unread' CHECK (status IN (
        'unread',         -- Nie przeczytane
        'read',           -- Przeczytane
        'acknowledged',   -- Potwierdzone (kliknął "OK")
        'responded',      -- Odpowiedział
        'ignored'         -- Zignorował (po deadline)
    )),

    -- Timestamps
    delivered_at TIMESTAMPTZ DEFAULT NOW(),
    read_at TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    responded_at TIMESTAMPTZ,

    -- Response reference (jeśli odpowiedział)
    response_message_id UUID REFERENCES room_messages(id),

    -- Unique: jeden odbiorca per wiadomość
    -- Enterprise: profile_id unique
    -- Personal: assistant_profile_id unique
    UNIQUE(message_id, profile_id, assistant_profile_id)
);

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_recipients_profile ON message_recipients(profile_id);
CREATE INDEX IF NOT EXISTS idx_recipients_status ON message_recipients(status);
CREATE INDEX IF NOT EXISTS idx_recipients_unread ON message_recipients(profile_id, status)
    WHERE status = 'unread';
CREATE INDEX IF NOT EXISTS idx_recipients_message ON message_recipients(message_id);

-- ============================================
-- 3. TABELA: message_templates (szablony)
-- ============================================

CREATE TABLE IF NOT EXISTS message_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES profiles(id),

    -- Template info
    name TEXT NOT NULL,                    -- "Raport miesięczny"
    description TEXT,

    -- Content
    subject_template TEXT NOT NULL,        -- "Raport za {month}"
    body_template TEXT NOT NULL,           -- "Proszę o przesłanie..."

    -- Expected response
    response_schema JSONB,                 -- JSON schema oczekiwanej odpowiedzi
    response_example TEXT,                 -- Przykład odpowiedzi

    -- Settings
    default_deadline_hours INT DEFAULT 48,
    default_priority TEXT DEFAULT 'normal',

    -- Status
    is_active BOOLEAN DEFAULT true,

    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indeksy
CREATE INDEX IF NOT EXISTS idx_templates_room ON message_templates(room_id);
CREATE INDEX IF NOT EXISTS idx_templates_active ON message_templates(room_id, is_active)
    WHERE is_active = true;

-- ============================================
-- 4. VIEWS (pomocnicze widoki)
-- ============================================

-- Inbox: nieprzeczytane wiadomości dla użytkownika
CREATE OR REPLACE VIEW inbox_unread AS
SELECT
    mr.id as recipient_id,
    mr.message_id,
    mr.profile_id as recipient_profile_id,
    mr.assistant_profile_id as recipient_assistant_id,
    mr.status as read_status,
    mr.delivered_at,
    m.room_id,
    m.from_profile_id,
    m.from_assistant_id,
    m.from_assistant_name,
    m.message_type,
    m.subject,
    m.priority,
    m.deadline,
    m.created_at as sent_at,
    r.name as room_name,
    r.room_type,
    p.name as sender_name,
    ap.name as sender_assistant_name
FROM message_recipients mr
JOIN room_messages m ON mr.message_id = m.id
JOIN rooms r ON m.room_id = r.id
JOIN profiles p ON m.from_profile_id = p.id
LEFT JOIN assistant_profiles ap ON m.from_assistant_id = ap.id
WHERE mr.status = 'unread'
  AND m.status = 'sent'
ORDER BY
    CASE m.priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'normal' THEN 3
        WHEN 'low' THEN 4
    END,
    m.created_at DESC;

-- Message status summary (dla sendera)
CREATE OR REPLACE VIEW message_status_summary AS
SELECT
    m.id as message_id,
    m.room_id,
    m.from_profile_id,
    m.subject,
    m.message_type,
    m.deadline,
    m.created_at as sent_at,
    COUNT(mr.id) as total_recipients,
    COUNT(CASE WHEN mr.status = 'unread' THEN 1 END) as unread_count,
    COUNT(CASE WHEN mr.status = 'read' THEN 1 END) as read_count,
    COUNT(CASE WHEN mr.status = 'acknowledged' THEN 1 END) as acknowledged_count,
    COUNT(CASE WHEN mr.status = 'responded' THEN 1 END) as responded_count,
    COUNT(CASE WHEN mr.status = 'ignored' THEN 1 END) as ignored_count
FROM room_messages m
LEFT JOIN message_recipients mr ON m.id = mr.message_id
WHERE m.status = 'sent'
GROUP BY m.id;

-- ============================================
-- 5. RLS POLICIES
-- ============================================

-- Włącz RLS
ALTER TABLE room_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_templates ENABLE ROW LEVEL SECURITY;

-- Na razie: PERMISSIVE policies (sprawdzanie w MCP tools)
CREATE POLICY "room_messages_all" ON room_messages FOR ALL USING (true);
CREATE POLICY "message_recipients_all" ON message_recipients FOR ALL USING (true);
CREATE POLICY "message_templates_all" ON message_templates FOR ALL USING (true);

-- ============================================
-- 6. HELPER FUNCTIONS
-- ============================================

-- Funkcja: wyślij wiadomość (broadcast lub do jednej osoby/asystenta)
-- Obsługuje zarówno Enterprise (profile_id) jak i Personal (assistant_profile_id)
CREATE OR REPLACE FUNCTION send_room_message(
    p_room_id UUID,
    p_from_profile_id TEXT,
    p_from_assistant_id UUID DEFAULT NULL,     -- UUID asystenta wysyłającego
    p_from_assistant_name TEXT DEFAULT NULL,   -- Display name
    p_message_type TEXT DEFAULT 'info',
    p_subject TEXT DEFAULT '',
    p_body TEXT DEFAULT '',
    p_to_profile_id TEXT DEFAULT NULL,         -- Dla Enterprise
    p_to_assistant_id UUID DEFAULT NULL,       -- Dla Personal
    p_to_role TEXT DEFAULT NULL,
    p_template JSONB DEFAULT NULL,
    p_deadline TIMESTAMPTZ DEFAULT NULL,
    p_priority TEXT DEFAULT 'normal',
    p_in_reply_to UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    message_id UUID;
    recipient RECORD;
    v_room_type TEXT;
BEGIN
    -- Pobierz typ pokoju
    SELECT room_type INTO v_room_type FROM rooms WHERE id = p_room_id;

    -- Wstaw wiadomość
    INSERT INTO room_messages (
        room_id, from_profile_id, from_assistant_id, from_assistant_name,
        to_profile_id, to_assistant_id, to_role, message_type,
        subject, body, template, deadline, priority, in_reply_to
    ) VALUES (
        p_room_id, p_from_profile_id, p_from_assistant_id, p_from_assistant_name,
        p_to_profile_id, p_to_assistant_id, p_to_role, p_message_type,
        p_subject, p_body, p_template, p_deadline, p_priority, p_in_reply_to
    )
    RETURNING id INTO message_id;

    -- Dodaj odbiorców w zależności od typu pokoju
    IF v_room_type = 'personal' THEN
        -- Personal Room: odbiorcy to asystenci
        IF p_to_assistant_id IS NOT NULL THEN
            -- Jeden asystent
            INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
            SELECT p_from_profile_id, p_to_assistant_id  -- owner is always profile_id
            FROM room_members
            WHERE room_id = p_room_id AND assistant_profile_id = p_to_assistant_id
            LIMIT 1;
        ELSE
            -- Broadcast do wszystkich asystentów (oprócz sendera)
            FOR recipient IN
                SELECT rm.profile_id, rm.assistant_profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND (rm.assistant_profile_id IS NULL OR rm.assistant_profile_id != p_from_assistant_id)
                  AND (p_to_role IS NULL OR rm.role = p_to_role)
            LOOP
                INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
                VALUES (message_id, recipient.profile_id, recipient.assistant_profile_id);
            END LOOP;
        END IF;
    ELSE
        -- Enterprise Room: odbiorcy to ludzie
        IF p_to_profile_id IS NOT NULL THEN
            -- Jeden człowiek
            INSERT INTO message_recipients (message_id, profile_id)
            VALUES (message_id, p_to_profile_id);
        ELSE
            -- Broadcast do wszystkich ludzi (oprócz sendera)
            FOR recipient IN
                SELECT rm.profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND rm.profile_id != p_from_profile_id
                  AND (p_to_role IS NULL OR rm.role = p_to_role)
            LOOP
                INSERT INTO message_recipients (message_id, profile_id)
                VALUES (message_id, recipient.profile_id);
            END LOOP;
        END IF;
    END IF;

    RETURN message_id;
END;
$$ LANGUAGE plpgsql;

-- Funkcja: sprawdź inbox (nieprzeczytane)
-- Dla Enterprise: filtruj po profile_id
-- Dla Personal: filtruj po assistant_profile_id
CREATE OR REPLACE FUNCTION check_inbox(
    p_profile_id TEXT,
    p_assistant_id UUID DEFAULT NULL,  -- Dla Personal Rooms
    p_room_id UUID DEFAULT NULL
)
RETURNS TABLE (
    message_id UUID,
    room_name TEXT,
    room_type TEXT,
    sender_name TEXT,
    sender_assistant TEXT,
    subject TEXT,
    message_type TEXT,
    priority TEXT,
    deadline TIMESTAMPTZ,
    sent_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        i.message_id,
        i.room_name,
        i.room_type,
        i.sender_name,
        COALESCE(i.sender_assistant_name, i.from_assistant_name) as sender_assistant,
        i.subject,
        i.message_type,
        i.priority,
        i.deadline,
        i.sent_at
    FROM inbox_unread i
    WHERE i.recipient_profile_id = p_profile_id
      AND (p_room_id IS NULL OR i.room_id = p_room_id)
      AND (
          -- Enterprise: assistant_id nie ma znaczenia
          (i.room_type = 'enterprise' AND i.recipient_assistant_id IS NULL)
          OR
          -- Personal: filtruj po assistant_id jeśli podany
          (i.room_type = 'personal' AND (p_assistant_id IS NULL OR i.recipient_assistant_id = p_assistant_id))
      );
END;
$$ LANGUAGE plpgsql;

-- Funkcja: oznacz jako przeczytane
CREATE OR REPLACE FUNCTION mark_message_read(p_message_id UUID, p_profile_id TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE message_recipients
    SET status = 'read', read_at = NOW()
    WHERE message_id = p_message_id
      AND profile_id = p_profile_id
      AND status = 'unread';

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- Funkcja: odpowiedz na wiadomość
CREATE OR REPLACE FUNCTION respond_to_message(
    p_original_message_id UUID,
    p_from_profile_id TEXT,
    p_from_assistant_name TEXT,
    p_body TEXT,
    p_structured_data JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    original RECORD;
    response_id UUID;
BEGIN
    -- Pobierz oryginalną wiadomość
    SELECT * INTO original FROM room_messages WHERE id = p_original_message_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Message not found: %', p_original_message_id;
    END IF;

    -- Utwórz odpowiedź
    INSERT INTO room_messages (
        room_id, from_profile_id, from_assistant_name,
        to_profile_id, message_type, subject, body,
        template, in_reply_to
    ) VALUES (
        original.room_id,
        p_from_profile_id,
        p_from_assistant_name,
        original.from_profile_id,  -- Odpowiedź do sendera
        'response',
        'RE: ' || original.subject,
        p_body,
        p_structured_data,
        p_original_message_id
    )
    RETURNING id INTO response_id;

    -- Dodaj sendera oryginalnej jako odbiorcę odpowiedzi
    INSERT INTO message_recipients (message_id, profile_id)
    VALUES (response_id, original.from_profile_id);

    -- Zaktualizuj status odbiorcy w oryginalnej wiadomości
    UPDATE message_recipients
    SET status = 'responded',
        responded_at = NOW(),
        response_message_id = response_id
    WHERE message_id = p_original_message_id
      AND profile_id = p_from_profile_id;

    RETURN response_id;
END;
$$ LANGUAGE plpgsql;

-- Funkcja: pobierz status wiadomości
CREATE OR REPLACE FUNCTION get_message_status(p_message_id UUID)
RETURNS TABLE (
    total_recipients INT,
    unread_count INT,
    read_count INT,
    acknowledged_count INT,
    responded_count INT,
    ignored_count INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.total_recipients::INT,
        s.unread_count::INT,
        s.read_count::INT,
        s.acknowledged_count::INT,
        s.responded_count::INT,
        s.ignored_count::INT
    FROM message_status_summary s
    WHERE s.message_id = p_message_id;
END;
$$ LANGUAGE plpgsql;

-- Funkcja: pobierz odpowiedzi na wiadomość
CREATE OR REPLACE FUNCTION get_message_responses(p_message_id UUID)
RETURNS TABLE (
    response_id UUID,
    from_profile_id TEXT,
    from_name TEXT,
    from_assistant TEXT,
    body TEXT,
    structured_data JSONB,
    responded_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.from_profile_id,
        p.name,
        m.from_assistant_name,
        m.body,
        m.template,  -- structured data stored in template for responses
        m.created_at
    FROM room_messages m
    JOIN profiles p ON m.from_profile_id = p.id
    WHERE m.in_reply_to = p_message_id
      AND m.message_type = 'response'
    ORDER BY m.created_at ASC;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 7. TRIGGER: Auto-mark as ignored after deadline
-- ============================================

CREATE OR REPLACE FUNCTION mark_ignored_after_deadline()
RETURNS void AS $$
BEGIN
    UPDATE message_recipients mr
    SET status = 'ignored'
    FROM room_messages m
    WHERE mr.message_id = m.id
      AND mr.status IN ('unread', 'read')
      AND m.deadline IS NOT NULL
      AND m.deadline < NOW();
END;
$$ LANGUAGE plpgsql;

-- Można uruchomić jako scheduled job (pg_cron) lub ręcznie

-- ============================================
-- 8. TEST DATA (opcjonalne, zakomentowane)
-- ============================================

/*
-- Test: wyślij broadcast
SELECT send_room_message(
    (SELECT id FROM rooms WHERE slug = 'test-corp'),
    'snow',
    'COO Bot',
    'request',
    'Raport finansowy Q1',
    'Proszę o przesłanie raportu finansowego za Q1.',
    NULL,  -- broadcast
    NULL,  -- all roles
    '{"przychody": "number", "koszty": "number"}'::jsonb,
    NOW() + INTERVAL '3 days',
    'high'
);

-- Test: sprawdź inbox
SELECT * FROM check_inbox('tomek');

-- Test: odpowiedz
SELECT respond_to_message(
    (SELECT id FROM room_messages WHERE subject = 'Raport finansowy Q1' LIMIT 1),
    'tomek',
    'Asystent Tomka',
    'Przychody: 150k, Koszty: 120k',
    '{"przychody": 150000, "koszty": 120000}'::jsonb
);

-- Test: status
SELECT * FROM get_message_status(
    (SELECT id FROM room_messages WHERE subject = 'Raport finansowy Q1' LIMIT 1)
);
*/

-- ============================================
-- DEPLOYMENT NOTES
-- ============================================

/*
DEPLOY ORDER:
1. FIRST: Run enterprise_rooms.sql
2. THEN: Run this script (enterprise_rooms_messaging.sql)
3. Verify tables: room_messages, message_recipients, message_templates
4. Verify views: inbox_unread, message_status_summary
5. Verify functions: send_room_message, check_inbox, mark_message_read,
                     respond_to_message, get_message_status, get_message_responses
6. Optional: Set up pg_cron for mark_ignored_after_deadline()

NEXT STEPS:
- MCP tools implementation
- Auto-check inbox hook (Claude Code startup)
- Gradio inbox UI
*/
