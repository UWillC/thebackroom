-- ============================================
-- MIGRATION: Enterprise Rooms v1.0 → v1.1
-- Dodaje: room_type + assistant_profile_id support
-- Data: 2026-02-06
-- ============================================
-- UWAGA: Uruchom TYLKO jeśli już wdrożyłeś enterprise_rooms.sql v1.0
-- Jeśli jeszcze nie wdrażałeś - użyj zaktualizowanych plików głównych
-- ============================================

-- 1. Dodaj room_type do rooms
ALTER TABLE rooms ADD COLUMN IF NOT EXISTS room_type TEXT DEFAULT 'enterprise'
    CHECK (room_type IN ('enterprise', 'personal'));

-- 2. Dodaj assistant_profile_id do room_members
ALTER TABLE room_members ADD COLUMN IF NOT EXISTS assistant_profile_id UUID
    REFERENCES assistant_profiles(id) ON DELETE CASCADE;

-- 3. Dodaj unique index dla Enterprise rooms
CREATE UNIQUE INDEX IF NOT EXISTS idx_room_members_enterprise_unique
    ON room_members(room_id, profile_id)
    WHERE assistant_profile_id IS NULL;

-- 4. Dodaj assistant kolumny do room_messages
ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS from_assistant_id UUID
    REFERENCES assistant_profiles(id);
ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS to_assistant_id UUID
    REFERENCES assistant_profiles(id);

-- 5. Dodaj assistant_profile_id do message_recipients
ALTER TABLE message_recipients ADD COLUMN IF NOT EXISTS assistant_profile_id UUID
    REFERENCES assistant_profiles(id);

-- 6. Zaktualizuj view room_active_members
CREATE OR REPLACE VIEW room_active_members AS
SELECT
    rm.id,
    rm.room_id,
    rm.profile_id,
    rm.assistant_profile_id,
    rm.role,
    rm.joined_at,
    rm.created_at,
    p.name as member_name,
    p.role as member_title,
    p.email as member_email,
    p.bio as member_bio,
    p.skills as member_skills,
    p.tags as member_tags,
    ap.name as assistant_name,
    ap.personality as assistant_personality,
    r.name as room_name,
    r.slug as room_slug,
    r.room_type
FROM room_members rm
JOIN profiles p ON rm.profile_id = p.id
JOIN rooms r ON rm.room_id = r.id
LEFT JOIN assistant_profiles ap ON rm.assistant_profile_id = ap.id
WHERE rm.status = 'approved'
  AND r.status = 'active';

-- 7. Zaktualizuj view inbox_unread
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

-- 8. Zaktualizuj funkcję send_room_message
CREATE OR REPLACE FUNCTION send_room_message(
    p_room_id UUID,
    p_from_profile_id TEXT,
    p_from_assistant_id UUID DEFAULT NULL,
    p_from_assistant_name TEXT DEFAULT NULL,
    p_message_type TEXT DEFAULT 'info',
    p_subject TEXT DEFAULT '',
    p_body TEXT DEFAULT '',
    p_to_profile_id TEXT DEFAULT NULL,
    p_to_assistant_id UUID DEFAULT NULL,
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
    SELECT room_type INTO v_room_type FROM rooms WHERE id = p_room_id;

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

    IF v_room_type = 'personal' THEN
        IF p_to_assistant_id IS NOT NULL THEN
            INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
            SELECT p_from_profile_id, p_to_assistant_id
            FROM room_members
            WHERE room_id = p_room_id AND assistant_profile_id = p_to_assistant_id
            LIMIT 1;
        ELSE
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
        IF p_to_profile_id IS NOT NULL THEN
            INSERT INTO message_recipients (message_id, profile_id)
            VALUES (message_id, p_to_profile_id);
        ELSE
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

-- 9. Zaktualizuj funkcję check_inbox
CREATE OR REPLACE FUNCTION check_inbox(
    p_profile_id TEXT,
    p_assistant_id UUID DEFAULT NULL,
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
          (i.room_type = 'enterprise' AND i.recipient_assistant_id IS NULL)
          OR
          (i.room_type = 'personal' AND (p_assistant_id IS NULL OR i.recipient_assistant_id = p_assistant_id))
      );
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- DONE!
-- ============================================
-- Teraz masz:
-- - rooms z room_type ('enterprise' | 'personal')
-- - room_members z assistant_profile_id (dla Personal Rooms)
-- - room_messages z from/to_assistant_id
-- - message_recipients z assistant_profile_id
-- - Zaktualizowane views i funkcje
-- ============================================
