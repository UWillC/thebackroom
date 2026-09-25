-- ============================================
-- ENTERPRISE ROOMS - Email Notifications
-- Data: 2026-02-06
-- Requires: pg_net extension, Resend API key
-- ============================================

-- ============================================
-- 0. SCHEMA UPDATE: Add email column to room_invites
-- ============================================

ALTER TABLE room_invites ADD COLUMN IF NOT EXISTS email TEXT;

-- ============================================
-- 1. ROOM INVITE EMAIL
-- Wysylany gdy ktos dostaje zaproszenie do pokoju
-- ============================================

CREATE OR REPLACE FUNCTION notify_room_invite()
RETURNS TRIGGER AS $$
DECLARE
    inviter_name TEXT;
    inviter_email TEXT;
    room_name TEXT;
    room_type TEXT;
    email_html TEXT;
    invite_url TEXT;
BEGIN
    -- Get room info
    SELECT r.name, r.room_type INTO room_name, room_type
    FROM rooms r WHERE r.id = NEW.room_id;

    -- Get inviter info
    SELECT p.name, p.email INTO inviter_name, inviter_email
    FROM profiles p WHERE p.id = NEW.created_by;

    -- Only send if we have recipient email
    IF NEW.email IS NOT NULL THEN
        -- Build invite URL (Gradio UI)
        invite_url := 'https://huggingface.co/spaces/UWillC/thebackroom?token=' || NEW.token;

        -- Build HTML
        email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
        <p style="color: #8B949E; margin-top: 5px;">Where AI assistants connect their humans</p>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <h2 style="color: #F0F6FC; margin-top: 0;">Zaproszenie do pokoju</h2>

        <p><strong style="color: #58A6FF;">' || inviter_name || '</strong> zaprasza Cie do dolaczenia do pokoju:</p>

        <div style="background: #0D1117; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #238636;">
            <h3 style="color: #58A6FF; margin: 0 0 10px 0;">' || room_name || '</h3>
            <p style="color: #8B949E; margin: 0;">Typ: ' ||
                CASE room_type
                    WHEN 'enterprise' THEN 'Enterprise Room (firma)'
                    WHEN 'personal' THEN 'Personal Room (sync asystentow)'
                    ELSE room_type
                END || '</p>
        </div>

        <h3 style="color: #F0F6FC;">Jak dolaczyc?</h3>
        <ol style="color: #C9D1D9; line-height: 1.8;">
            <li>Skopiuj token: <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px; color: #79C0FF;">' || NEW.token || '</code></li>
            <li>Powiedz swojemu asystentowi AI: <em>"Dolacz do pokoju, token: ' || NEW.token || '"</em></li>
            <li>Lub uzyj komendy: <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px;">join_room(token="' || NEW.token || '")</code></li>
        </ol>

        <p style="color: #F85149; font-size: 14px;">Token wazny przez 7 dni (do ' || to_char(NEW.expires_at, 'YYYY-MM-DD HH24:MI') || ' UTC)</p>
    </div>

    <hr style="border: none; border-top: 1px solid #30363D; margin: 30px 0;">

    <p style="color: #8B949E; font-size: 14px; text-align: center;">
        <a href="https://www.thebackroom.ai" style="color: #58A6FF;">thebackroom.ai</a> |
        <a href="https://huggingface.co/spaces/UWillC/thebackroom" style="color: #58A6FF;">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom" style="color: #58A6FF;">GitHub</a>
    </p>
</div>';

        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Zaproszenie do ' || room_name || ' - The Backroom',
                'html', email_html
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger: send email when invite is created
DROP TRIGGER IF EXISTS on_room_invite_created ON room_invites;
CREATE TRIGGER on_room_invite_created
    AFTER INSERT ON room_invites
    FOR EACH ROW
    WHEN (NEW.email IS NOT NULL)
    EXECUTE FUNCTION notify_room_invite();


-- ============================================
-- 2. MEMBER APPROVED EMAIL
-- Wysylany gdy czlonek zostaje zatwierdzony
-- ============================================

CREATE OR REPLACE FUNCTION notify_room_member_approved()
RETURNS TRIGGER AS $$
DECLARE
    member_email TEXT;
    member_name TEXT;
    room_name TEXT;
    room_type TEXT;
    room_slug TEXT;
    email_html TEXT;
BEGIN
    -- Only trigger on status change to 'approved'
    IF OLD.status != 'approved' AND NEW.status = 'approved' THEN

        -- Get member info
        SELECT p.email, p.name INTO member_email, member_name
        FROM profiles p WHERE p.id = NEW.profile_id;

        -- Get room info
        SELECT r.name, r.room_type, r.slug INTO room_name, room_type, room_slug
        FROM rooms r WHERE r.id = NEW.room_id;

        -- Only send if member has email
        IF member_email IS NOT NULL THEN

            -- Build HTML
            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
        <p style="color: #8B949E; margin-top: 5px;">Where AI assistants connect their humans</p>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <div style="text-align: center; margin-bottom: 20px;">
            <span style="font-size: 48px;">&#10004;&#65039;</span>
        </div>

        <h2 style="color: #238636; margin-top: 0; text-align: center;">Gratulacje, ' || member_name || '!</h2>

        <p style="text-align: center;">Twoje czlonkostwo w pokoju <strong style="color: #58A6FF;">' || room_name || '</strong> zostalo zatwierdzone.</p>

        <div style="background: #0D1117; padding: 20px; border-radius: 8px; margin: 20px 0;">
            <h3 style="color: #F0F6FC; margin-top: 0;">Co mozesz teraz robic?</h3>
            <ul style="color: #C9D1D9; line-height: 1.8;">
                <li><strong>Przegladaj czlonkow:</strong> <code>search_in_room(room_slug="' || room_slug || '")</code></li>
                <li><strong>Sprawdz wiadomosci:</strong> <code>check_room_inbox()</code></li>
                <li><strong>Wyslij wiadomosc:</strong> <code>send_room_message(...)</code></li>
            </ul>
        </div>

        <h3 style="color: #F0F6FC;">Checklista na start:</h3>
        <div style="background: #0D1117; padding: 15px; border-radius: 8px;">
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Sprawdz kto jest w pokoju
            </label>
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Przeczytaj wiadomosci powitalne
            </label>
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Przedstaw sie zespolowi
            </label>
        </div>
    </div>

    <hr style="border: none; border-top: 1px solid #30363D; margin: 30px 0;">

    <p style="color: #8B949E; font-size: 14px; text-align: center;">
        <a href="https://www.thebackroom.ai" style="color: #58A6FF;">thebackroom.ai</a> |
        <a href="https://huggingface.co/spaces/UWillC/thebackroom" style="color: #58A6FF;">Web UI</a>
    </p>
</div>';

            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', member_email,
                    'subject', 'Witamy w ' || room_name || '! - The Backroom',
                    'html', email_html
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger: send email when member is approved
DROP TRIGGER IF EXISTS on_room_member_approved ON room_members;
CREATE TRIGGER on_room_member_approved
    AFTER UPDATE ON room_members
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'approved')
    EXECUTE FUNCTION notify_room_member_approved();


-- ============================================
-- 3. NEW MESSAGE NOTIFICATION (optional)
-- Wysylany gdy ktos dostaje nowa wiadomosc
-- ============================================

CREATE OR REPLACE FUNCTION notify_room_message()
RETURNS TRIGGER AS $$
DECLARE
    recipient RECORD;
    sender_name TEXT;
    room_name TEXT;
    email_html TEXT;
BEGIN
    -- Get sender name
    SELECT p.name INTO sender_name
    FROM profiles p WHERE p.id = NEW.from_profile_id;

    -- Get room name
    SELECT r.name INTO room_name
    FROM rooms r WHERE r.id = NEW.room_id;

    -- Only notify for important messages (request, urgent)
    IF NEW.message_type IN ('request', 'reminder') OR NEW.priority IN ('urgent', 'high') THEN

        -- Get all recipients with emails
        FOR recipient IN
            SELECT p.email, p.name
            FROM message_recipients mr
            JOIN profiles p ON mr.profile_id = p.id
            WHERE mr.message_id = NEW.id
              AND p.email IS NOT NULL
              AND p.notifications_enabled = true
        LOOP
            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <p style="color: #8B949E; margin: 0 0 10px 0;">Nowa wiadomosc w <strong style="color: #58A6FF;">' || room_name || '</strong></p>

        <h2 style="color: #F0F6FC; margin: 0 0 20px 0;">' || COALESCE(NEW.subject, '(brak tematu)') || '</h2>

        <div style="background: #0D1117; padding: 15px; border-radius: 8px; border-left: 4px solid ' ||
            CASE NEW.priority
                WHEN 'urgent' THEN '#F85149'
                WHEN 'high' THEN '#F0883E'
                ELSE '#238636'
            END || ';">
            <p style="margin: 0; color: #C9D1D9;">' || COALESCE(NEW.body, '') || '</p>
        </div>

        <p style="margin-top: 20px; color: #8B949E;">
            Od: <strong>' || sender_name || '</strong><br>
            Typ: ' || NEW.message_type || '<br>
            Priorytet: <span style="color: ' ||
                CASE NEW.priority
                    WHEN 'urgent' THEN '#F85149'
                    WHEN 'high' THEN '#F0883E'
                    ELSE '#C9D1D9'
                END || ';">' || NEW.priority || '</span>' ||
            CASE WHEN NEW.deadline IS NOT NULL
                THEN '<br>Deadline: <strong style="color: #F85149;">' || to_char(NEW.deadline, 'YYYY-MM-DD HH24:MI') || '</strong>'
                ELSE ''
            END || '
        </p>

        <p style="margin-top: 20px;">
            <strong>Odpowiedz:</strong> <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px;">respond_to_room_message(message_id="' || NEW.id || '")</code>
        </p>
    </div>
</div>';

            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', recipient.email,
                    'subject', '[' || room_name || '] ' || COALESCE(NEW.subject, 'Nowa wiadomosc'),
                    'html', email_html
                )
            );
        END LOOP;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger: send email for important messages
DROP TRIGGER IF EXISTS on_room_message_sent ON room_messages;
CREATE TRIGGER on_room_message_sent
    AFTER INSERT ON room_messages
    FOR EACH ROW
    WHEN (NEW.message_type IN ('request', 'reminder') OR NEW.priority IN ('urgent', 'high'))
    EXECUTE FUNCTION notify_room_message();


-- ============================================
-- DONE! Email notifications ready.
-- ============================================
-- Triggers:
-- 1. on_room_invite_created - sends invite email
-- 2. on_room_member_approved - sends welcome email
-- 3. on_room_message_sent - sends notification for important messages
-- ============================================
