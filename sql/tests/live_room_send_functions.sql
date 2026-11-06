-- LOCAL ONLY. Exact production bodies read 2026-11-05 through the read-only MCP (pg_get_functiondef):
--   send_room_message   md5 ca1c13939521b694f4a2bed53b999c95
--   respond_to_message  md5 742cabd5fe79f590b6072259fabb72cb
-- If production changes, re-read them here. security_fixes/2026-11-05_room_mail_send_paths_verify.sql
-- turns false on production when these bodies change, and tests/run_room_mail_local.sh checks the md5.
CREATE OR REPLACE FUNCTION public.respond_to_message(p_original_message_id uuid, p_from_profile_id text, p_from_assistant_name text, p_body text, p_structured_data jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.send_room_message(p_room_id uuid, p_from_profile_id text, p_from_assistant_id uuid DEFAULT NULL::uuid, p_from_assistant_name text DEFAULT NULL::text, p_message_type text DEFAULT 'info'::text, p_subject text DEFAULT ''::text, p_body text DEFAULT ''::text, p_to_profile_id text DEFAULT NULL::text, p_to_assistant_id uuid DEFAULT NULL::uuid, p_to_role text DEFAULT NULL::text, p_template jsonb DEFAULT NULL::jsonb, p_deadline timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority text DEFAULT 'normal'::text, p_in_reply_to uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_message_id UUID;
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
    RETURNING id INTO v_message_id;

    -- Populate recipients based on room type
    IF v_room_type = 'personal' THEN
        -- Personal Room: recipients are assistants (and owner slot)
        IF p_to_assistant_id IS NOT NULL THEN
            -- Single assistant (targeted)
            INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id)
            SELECT v_message_id, rm.profile_id, rm.assistant_profile_id
            FROM room_members rm
            WHERE rm.room_id = p_room_id
              AND rm.assistant_profile_id = p_to_assistant_id
              AND rm.status = 'approved'
            LIMIT 1;
        ELSE
            -- Broadcast to all members except sender.
            -- NOTE: owner slot (assistant_profile_id IS NULL) is INCLUDED —
            -- other assistants may rely on owner-slot delivery when they are
            -- not separately listed in room_members.
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
                VALUES (v_message_id, recipient.profile_id, recipient.assistant_profile_id)
                ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
            END LOOP;
        END IF;
    ELSE
        -- Enterprise Room: recipients are humans
        IF p_to_profile_id IS NOT NULL THEN
            -- Single human
            INSERT INTO message_recipients (message_id, profile_id)
            VALUES (v_message_id, p_to_profile_id)
            ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
        ELSE
            -- Broadcast to all humans except sender (DISTINCT to dedupe multi-role)
            FOR recipient IN
                SELECT DISTINCT rm.profile_id
                FROM room_members rm
                WHERE rm.room_id = p_room_id
                  AND rm.status = 'approved'
                  AND rm.profile_id != p_from_profile_id
                  AND (p_to_role IS NULL OR rm.role = p_to_role)
            LOOP
                INSERT INTO message_recipients (message_id, profile_id)
                VALUES (v_message_id, recipient.profile_id)
                ON CONFLICT (message_id, profile_id, assistant_profile_id) DO NOTHING;
            END LOOP;
        END IF;
    END IF;

    RETURN v_message_id;
END;
$function$
;
