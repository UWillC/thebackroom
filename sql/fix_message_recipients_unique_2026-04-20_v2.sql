-- ============================================
-- Fix v2: revert owner-slot exclusion in send_room_message (2026-04-20)
-- GitHub issue: https://github.com/UWillC/thebackroom/issues/1
-- ============================================
--
-- FOLLOW-UP to fix_message_recipients_unique_2026-04-20.sql:
--
-- The v1 migration dropped/added the unique constraint correctly, but also
-- added an `assistant_profile_id IS NOT NULL` filter to the Personal Room
-- broadcast — intended to skip "owner slot" deliveries. That was wrong.
--
-- Reality check (SNOW Sync room): members are only the human (as admin with
-- assistant=CEO + as owner with assistant=NULL). Other assistants like @mind
-- are NOT separate `room_members` rows; they send with
-- `from_assistant_name` resolved via `assistant_profiles`, but they read via
-- the owner slot (or via their own check_room_inbox filter).
--
-- Excluding the owner slot in v1 → broadcasts produced `recipients: 0`
-- because the only non-sender row in members was the owner slot, which we
-- were filtering out. Messages sent but never delivered.
--
-- THIS v2:
-- - Restores original Personal Room broadcast behavior (include owner slot).
-- - Keeps the 3-col UNIQUE constraint fix from v1 (the real bug).
-- - Keeps `ON CONFLICT ... DO NOTHING` as a safety net for future edge cases.
-- - Keeps Enterprise Room `SELECT DISTINCT` dedupe from v1.

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
    -- Get room type
    SELECT room_type INTO v_room_type FROM rooms WHERE id = p_room_id;

    -- Insert the message
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

    -- Populate recipients based on room type
    IF v_room_type = 'personal' THEN
        -- Personal Room: recipients are assistants (and owner slot)
        IF p_to_assistant_id IS NOT NULL THEN
            -- Single assistant (targeted)
            INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
            SELECT message_id, rm.profile_id, rm.assistant_profile_id
            FROM room_members rm
            WHERE rm.room_id = p_room_id
              AND rm.assistant_profile_id = p_to_assistant_id
              AND rm.status = 'approved'
            LIMIT 1;
        ELSE
            -- Broadcast to all members except sender
            -- NOTE: keep owner slot (assistant_profile_id IS NULL) — other
            -- assistants may rely on the owner slot for delivery when they
            -- are not separately listed in room_members.
            FOR recipient IN
                SELECT rm.profile_id, rm.assistant_profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND (
                      rm.assistant_profile_id IS NULL
                      OR rm.assistant_profile_id != COALESCE(p_from_assistant_id, '00000000-0000-0000-0000-000000000000'::uuid)
                  )
                  AND (p_to_role IS NULL OR rm.role = p_to_role)
            LOOP
                INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
                VALUES (message_id, recipient.profile_id, recipient.assistant_profile_id)
                ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
            END LOOP;
        END IF;
    ELSE
        -- Enterprise Room: recipients are humans
        IF p_to_profile_id IS NOT NULL THEN
            -- Single human
            INSERT INTO message_recipients (message_id, profile_id)
            VALUES (message_id, p_to_profile_id)
            ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
        ELSE
            -- Broadcast to all humans except sender (DISTINCT to dedupe multi-role humans)
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

-- Verification: run a test send afterwards and confirm recipients > 0
-- for a broadcast in a room where the sender is the only non-owner member.
