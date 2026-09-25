-- ============================================
-- Fix: message_recipients UNIQUE constraint mismatch (2026-04-20)
-- GitHub issue: https://github.com/UWillC/thebackroom/issues/1
-- ============================================
--
-- BUG:
-- Live database has UNIQUE(message_id, profile_id) on message_recipients,
-- but schema file has been on UNIQUE(message_id, profile_id, assistant_profile_id)
-- for a while. In Personal Rooms, a broadcast to multiple assistants of the
-- SAME human profile causes duplicate key 23505 on
-- "message_recipients_message_id_profile_id_key".
--
-- EVIDENCE:
-- Error code 23505, constraint name points to 2-column unique.
-- Expected when SNOW Sync room has:
--   (profile=przemek_(snow), assistant=NULL)       -- owner slot
--   (profile=przemek_(snow), assistant=CEO_UUID)   -- @ceo
--   (profile=przemek_(snow), assistant=MIND_UUID)  -- @mind
-- Broadcast from @ceo → inserts (msg, przemek, NULL) + (msg, przemek, MIND)
-- → violates 2-col unique on same profile_id.
--
-- FIX:
-- 1. Drop the old 2-column unique constraint (if exists).
-- 2. Ensure the 3-column unique is present (schema-intended).
-- 3. (Logic fix) send_room_message: exclude owner slot from Personal
--    broadcasts. Owner is the human — they don't receive assistant-to-
--    assistant messages in Personal Rooms. Humans read via their assistant's
--    inbox (check_room_inbox with assistant_id).

-- ============================================
-- STEP 1: Drop the 2-column unique constraint if present
-- ============================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'message_recipients_message_id_profile_id_key'
    ) THEN
        ALTER TABLE message_recipients
            DROP CONSTRAINT message_recipients_message_id_profile_id_key;
        RAISE NOTICE 'Dropped old 2-column unique constraint';
    ELSE
        RAISE NOTICE 'Old 2-column unique constraint not found (already fixed or never existed)';
    END IF;
END $$;

-- ============================================
-- STEP 2: Ensure 3-column unique constraint exists
-- ============================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'message_recipients_message_id_profile_id_assistant_profile_id_key'
           OR conname = 'uq_message_recipients_msg_profile_assistant'
    ) THEN
        ALTER TABLE message_recipients
            ADD CONSTRAINT uq_message_recipients_msg_profile_assistant
            UNIQUE (message_id, profile_id, assistant_profile_id);
        RAISE NOTICE 'Added 3-column unique constraint';
    ELSE
        RAISE NOTICE '3-column unique constraint already exists';
    END IF;
END $$;

-- ============================================
-- STEP 3: Fix send_room_message — exclude owner slot from Personal broadcasts
-- ============================================
-- Rationale: in Personal Rooms, the human (owner row, assistant_profile_id=NULL)
-- does not read messages directly — they read through their assistant's inbox.
-- Including the owner slot creates a no-op recipient row (no assistant to
-- deliver to) and contributes to the duplicate-key problem when paired with
-- the old 2-col unique. Filtering it out simplifies semantics and reduces
-- inbox pollution.

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
            -- Jeden asystent (targeted)
            INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
            SELECT message_id, rm.profile_id, rm.assistant_profile_id
            FROM room_members rm
            WHERE rm.room_id = p_room_id
              AND rm.assistant_profile_id = p_to_assistant_id
              AND rm.status = 'approved'
            LIMIT 1;
        ELSE
            -- Broadcast do wszystkich asystentów (oprócz sendera)
            -- FIX 2026-04-20: exclude owner slot (assistant_profile_id IS NULL).
            -- The human doesn't receive assistant-to-assistant broadcasts.
            FOR recipient IN
                SELECT rm.profile_id, rm.assistant_profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND rm.assistant_profile_id IS NOT NULL
                  AND rm.assistant_profile_id != COALESCE(p_from_assistant_id, '00000000-0000-0000-0000-000000000000'::uuid)
                  AND (p_to_role IS NULL OR rm.role = p_to_role)
            LOOP
                INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
                VALUES (message_id, recipient.profile_id, recipient.assistant_profile_id)
                ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
            END LOOP;
        END IF;
    ELSE
        -- Enterprise Room: odbiorcy to ludzie
        IF p_to_profile_id IS NOT NULL THEN
            -- Jeden człowiek
            INSERT INTO message_recipients (message_id, profile_id)
            VALUES (message_id, p_to_profile_id)
            ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
        ELSE
            -- Broadcast do wszystkich ludzi (oprócz sendera)
            -- FIX 2026-04-20: SELECT DISTINCT to dedupe humans with multiple roles.
            FOR recipient IN
                SELECT DISTINCT rm.profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND rm.profile_id != p_from_profile_id
                  AND (p_to_role IS NULL OR rm.role = p_to_role)
            LOOP
                INSERT INTO message_recipients (message_id, profile_id)
                VALUES (message_id, recipient.profile_id)
                ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
            END LOOP;
        END IF;
    END IF;

    RETURN message_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- VERIFY
-- ============================================
-- Check constraints:
-- SELECT conname FROM pg_constraint WHERE conrelid = 'message_recipients'::regclass;
-- Expected: uq_message_recipients_msg_profile_assistant (3-col)
-- NOT expected: message_recipients_message_id_profile_id_key (old 2-col)
