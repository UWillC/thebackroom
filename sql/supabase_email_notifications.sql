-- THE BACKROOM - Email Notifications via Resend
-- Connection Request Notification
-- Data: 2026-02-04
-- Requires: pg_net extension, Resend API key

-- 1. Enable pg_net extension (for HTTP calls)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 2. Function to send email via Resend
CREATE OR REPLACE FUNCTION notify_connection_request()
RETURNS TRIGGER AS $$
DECLARE
    recipient_email TEXT;
    recipient_name TEXT;
    sender_name TEXT;
    sender_role TEXT;
    email_html TEXT;
BEGIN
    -- Get recipient email
    SELECT email, name INTO recipient_email, recipient_name
    FROM profiles WHERE id = NEW.to_user;

    -- Get sender info
    SELECT name, role INTO sender_name, sender_role
    FROM profiles WHERE id = NEW.from_user;

    -- Only send if recipient has email
    IF recipient_email IS NOT NULL THEN
        -- Build HTML
        email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
    <h1 style="color: #6B46C1;">🤝 Nowy Connection Request!</h1>

    <p>Cześć <strong>' || recipient_name || '</strong>!</p>

    <p><strong>' || sender_name || '</strong> chce się z Tobą połączyć w The Backroom.</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">👤 O nadawcy:</h3>
        <ul style="list-style: none; padding: 0;">
            <li><strong>Imię:</strong> ' || sender_name || '</li>
            <li><strong>Rola:</strong> ' || COALESCE(sender_role, 'Nie podano') || '</li>
        </ul>

        <h3>💬 Wiadomość:</h3>
        <p style="background: white; padding: 15px; border-radius: 4px; border-left: 4px solid #6B46C1;">' || COALESCE(NEW.message, 'Brak wiadomości') || '</p>

        <h3>🎯 Powód:</h3>
        <p>' || COALESCE(NEW.reason, 'Nie podano') || '</p>
    </div>

    <h3>🚀 Co możesz zrobić?</h3>
    <ol>
        <li><strong>Zaakceptuj:</strong> "Zaakceptuj request od ' || sender_name || '"</li>
        <li><strong>Odrzuć:</strong> "Odrzuć request od ' || sender_name || '"</li>
        <li><strong>Sprawdź profil:</strong> "Pokaż profil ' || sender_name || '"</li>
    </ol>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom">GitHub</a>
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
                'to', recipient_email,
                'subject', '🤝 ' || sender_name || ' chce się połączyć!',
                'html', email_html
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Create trigger on connection_requests table
DROP TRIGGER IF EXISTS on_new_connection_request ON connection_requests;
CREATE TRIGGER on_new_connection_request
    AFTER INSERT ON connection_requests
    FOR EACH ROW
    EXECUTE FUNCTION notify_connection_request();
