-- ============================================
-- FIX: check_inbox nie pokazuje broadcastów asystentom
-- Problem: wiadomości bez to_assistant_id (broadcast) mają
--   recipient_assistant_id = NULL w message_recipients.
--   Gdy asystent podaje swój UUID, filtr NULL = UUID → brak matcha.
-- Fix: broadcast (recipient_assistant_id IS NULL) widoczny dla WSZYSTKICH asystentów.
-- Data: 2026-03-15
-- ============================================

-- 1. Fix check_inbox — broadcast messages widoczne dla wszystkich asystentów
DROP FUNCTION IF EXISTS check_inbox;
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
          -- Enterprise rooms: show messages without assistant targeting
          (i.room_type = 'enterprise' AND i.recipient_assistant_id IS NULL)
          OR
          -- Personal rooms: show messages targeted to this assistant
          -- OR broadcast messages (recipient_assistant_id IS NULL = broadcast to all)
          (i.room_type = 'personal' AND (
              p_assistant_id IS NULL
              OR i.recipient_assistant_id = p_assistant_id
              OR i.recipient_assistant_id IS NULL
          ))
      );
END;
$$ LANGUAGE plpgsql;

-- 2. Fix send_room_message — handle NULL != NULL comparison for personal rooms
DROP FUNCTION IF EXISTS send_room_message;
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
            -- Targeted: deliver only to specific assistant
            INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
            SELECT message_id, rm.profile_id, rm.assistant_profile_id
            FROM room_members rm
            WHERE rm.room_id = p_room_id AND rm.assistant_profile_id = p_to_assistant_id
            LIMIT 1;
        ELSE
            -- Broadcast: deliver to all members EXCEPT exact sender
            -- Use COALESCE to handle NULL comparisons (NULL != NULL = NULL, not FALSE)
            FOR recipient IN
                SELECT rm.profile_id, rm.assistant_profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND NOT (
                      rm.profile_id = p_from_profile_id
                      AND COALESCE(rm.assistant_profile_id::text, '__null__') = COALESCE(p_from_assistant_id::text, '__null__')
                  )
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

-- 3. Fix unique constraint — allow multiple assistants per profile per room
-- Old: (room_id, profile_id) — blocks 1 human + N assistants in same room
-- New: (room_id, profile_id, assistant_profile_id) — allows it
ALTER TABLE room_members
DROP CONSTRAINT IF EXISTS room_members_room_id_profile_id_key;

ALTER TABLE room_members
ADD CONSTRAINT room_members_room_profile_assistant_key
UNIQUE (room_id, profile_id, assistant_profile_id);

-- ============================================
-- DONE! Deploy to Supabase SQL Editor
-- ============================================
