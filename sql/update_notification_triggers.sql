-- =====================================================
-- UPDATE NOTIFICATION TRIGGERS - Check email_verified
-- The Backroom - Security Sprint 1
-- Date: 2026-02-05
-- =====================================================

-- =====================================================
-- 1. UPDATE: Connection Request Notification
-- Only send email if recipient has VERIFIED email
-- =====================================================
CREATE OR REPLACE FUNCTION notify_connection_request()
RETURNS TRIGGER AS $$
DECLARE
    sender_name TEXT;
    sender_role TEXT;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
BEGIN
    -- Get sender info
    SELECT name, role INTO sender_name, sender_role
    FROM profiles WHERE id = NEW.from_user;

    -- Get recipient info including verification status
    SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
    INTO recipient_email, recipient_name, recipient_verified, recipient_notifications
    FROM profiles WHERE id = NEW.to_user;

    -- Only send email if:
    -- 1. Recipient has email
    -- 2. Email is VERIFIED
    -- 3. Notifications are enabled
    IF recipient_email IS NOT NULL
       AND recipient_verified = true
       AND recipient_notifications = true
    THEN
        -- Send email via Resend
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', recipient_email,
                'subject', sender_name || ' chce się z Tobą połączyć!',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🤝 Nowy Connection Request!</h1>

    <p>Cześć <strong>' || recipient_name || '</strong>!</p>

    <p><strong>' || sender_name || '</strong> (' || COALESCE(sender_role, 'Członek sieci') || ') chce się z Tobą połączyć w The Backroom.</p>

    ' || CASE WHEN NEW.message IS NOT NULL AND NEW.message != '' THEN '
    <div style="background: #F7FAFC; padding: 15px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #6B46C1;">
        <p style="margin: 0; font-style: italic;">"' || NEW.message || '"</p>
    </div>
    ' ELSE '' END || '

    <p>Aby odpowiedzieć, powiedz swojemu asystentowi AI:</p>
    <ul>
        <li><code>"Sprawdź moje requesty w The Backroom"</code></li>
        <li><code>"Odpowiedz na request od ' || sender_name || '"</code></li>
    </ul>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>

    <p style="color: #A0AEC0; font-size: 12px;">
        Nie chcesz otrzymywać powiadomień? Powiedz: "Wyłącz notyfikacje The Backroom"
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate trigger (function already replaced)
DROP TRIGGER IF EXISTS on_new_connection_request ON connection_requests;
CREATE TRIGGER on_new_connection_request
    AFTER INSERT ON connection_requests
    FOR EACH ROW
    EXECUTE FUNCTION notify_connection_request();

-- =====================================================
-- 2. UPDATE: Onboarding Email
-- Send welcome email ONLY after email is verified
-- =====================================================
CREATE OR REPLACE FUNCTION send_welcome_email_after_verification()
RETURNS TRIGGER AS $$
BEGIN
    -- Only send welcome email when:
    -- 1. email_verified changed from false to true
    -- 2. notifications are enabled
    IF OLD.email_verified = false
       AND NEW.email_verified = true
       AND COALESCE(NEW.notifications_enabled, true) = true
       AND NEW.email IS NOT NULL
    THEN
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Email zweryfikowany - Witaj w The Backroom, ' || NEW.name || '!',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
    <h1 style="color: #6B46C1;">✅ Email zweryfikowany!</h1>

    <p>Cześć <strong>' || NEW.name || '</strong>!</p>

    <p>Twój email został zweryfikowany. Będziesz teraz otrzymywać powiadomienia o:</p>
    <ul>
        <li>Nowych connection requests</li>
        <li>Odpowiedziach na Twoje requesty</li>
        <li>Matchach znalezionych przez AI</li>
    </ul>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">📋 Twój profil:</h3>
        <ul style="list-style: none; padding: 0;">
            <li><strong>ID:</strong> ' || NEW.id || '</li>
            <li><strong>Rola:</strong> ' || COALESCE(NEW.role, 'Nie podano') || '</li>
            <li><strong>Lokalizacja:</strong> ' || COALESCE(NEW.location, 'Nie podano') || '</li>
        </ul>
    </div>

    <h3>🚀 Co możesz teraz zrobić?</h3>
    <ol>
        <li><strong>Szukaj:</strong> "Znajdź kogoś kto zna marketing"</li>
        <li><strong>Łącz się:</strong> "Wyślij request do [osoba]"</li>
        <li><strong>Sprawdzaj:</strong> "Moje requesty"</li>
    </ol>

    <p>Potrzebujesz pomocy? Powiedz: <code>"Pomoc The Backroom"</code></p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom">GitHub</a>
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop old onboarding trigger (was sending immediately on INSERT)
DROP TRIGGER IF EXISTS on_new_profile ON profiles;

-- Create new trigger that sends welcome email after verification
DROP TRIGGER IF EXISTS on_email_verified ON profiles;
CREATE TRIGGER on_email_verified
    AFTER UPDATE OF email_verified ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION send_welcome_email_after_verification();

-- =====================================================
-- 3. FUNCTION: Toggle notifications
-- =====================================================
CREATE OR REPLACE FUNCTION toggle_notifications(
    p_profile_id TEXT,
    p_enabled BOOLEAN
)
RETURNS jsonb AS $$
BEGIN
    UPDATE profiles
    SET notifications_enabled = p_enabled,
        updated_at = NOW()
    WHERE id = p_profile_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Profile not found'
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE
            WHEN p_enabled THEN 'Notifications enabled'
            ELSE 'Notifications disabled'
        END,
        'notifications_enabled', p_enabled
    );
END;
$$ LANGUAGE plpgsql;
