-- =====================================================
-- CONNECTION ACCEPTED EMAIL with "Co teraz?" section
-- The Backroom - Faza 2 UX
-- Date: 2026-02-10
-- =====================================================
-- Sends email to BOTH parties when connection is accepted:
-- 1. To sender: "Your request was accepted!"
-- 2. To recipient: "You accepted, here's what to do next"

-- Function to notify both parties when connection is accepted
CREATE OR REPLACE FUNCTION notify_connection_accepted()
RETURNS TRIGGER AS $$
DECLARE
    sender_email TEXT;
    sender_name TEXT;
    sender_verified BOOLEAN;
    sender_notifications BOOLEAN;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_role TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
    recipient_linkedin TEXT;
    recipient_contact TEXT;
BEGIN
    -- Only trigger when status changes to 'accepted'
    IF OLD.status != 'accepted' AND NEW.status = 'accepted' THEN

        -- Get sender (who sent the request) info
        SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
        INTO sender_email, sender_name, sender_verified, sender_notifications
        FROM profiles WHERE id = NEW.from_user;

        -- Get recipient (who accepted) info
        SELECT email, name, role, email_verified, COALESCE(notifications_enabled, true),
               linkedin_url, preferred_contact
        INTO recipient_email, recipient_name, recipient_role, recipient_verified,
             recipient_notifications, recipient_linkedin, recipient_contact
        FROM profiles WHERE id = NEW.to_user;

        -- =====================================================
        -- EMAIL 1: To the SENDER (their request was accepted!)
        -- =====================================================
        IF sender_email IS NOT NULL
           AND sender_verified = true
           AND sender_notifications = true
        THEN
            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', sender_email,
                    'subject', recipient_name || ' zaakceptował(a) Twój request!',
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection Accepted!</h1>

    <p>Cześć <strong>' || sender_name || '</strong>!</p>

    <p>Świetna wiadomość - <strong>' || recipient_name || '</strong> zaakceptował(a) Twój connection request!</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;"><strong>Napisz. Krótko się przedstaw. Umówcie się na kawę lub call.</strong></p>
    </div>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">Dane kontaktowe:</h3>
        <ul style="list-style: none; padding: 0; margin: 0;">
            <li><strong>Imię:</strong> ' || recipient_name || '</li>
            <li><strong>Rola:</strong> ' || COALESCE(recipient_role, 'Nie podano') || '</li>
            ' || CASE WHEN recipient_linkedin IS NOT NULL THEN '
            <li><strong>LinkedIn:</strong> <a href="' || recipient_linkedin || '">' || recipient_linkedin || '</a></li>
            ' ELSE '' END || '
            <li><strong>Preferowany kontakt:</strong> ' || COALESCE(recipient_contact, 'Nie podano') || '</li>
        </ul>
    </div>

    ' || CASE WHEN NEW.response_message IS NOT NULL AND NEW.response_message != '' THEN '
    <div style="background: #EBF8FF; padding: 15px; border-radius: 8px; margin: 20px 0;">
        <p style="margin: 0;"><strong>Wiadomość od ' || recipient_name || ':</strong></p>
        <p style="margin: 10px 0 0 0; font-style: italic;">"' || NEW.response_message || '"</p>
    </div>
    ' ELSE '' END || '

    <h3>Sugerowana pierwsza wiadomość:</h3>
    <div style="background: #FFFAF0; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 14px;">
        Cześć ' || recipient_name || '!<br><br>
        Dzięki za akceptację w The Backroom.<br>
        [WSTAW: krótko czego szukasz / co oferujesz]<br><br>
        Masz czas na krótki call w tym tygodniu?<br><br>
        Pozdrawiam,<br>
        ' || sender_name || '
    </div>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>
</div>
'
                )
            );
        END IF;

        -- =====================================================
        -- EMAIL 2: To the RECIPIENT (confirmation + next steps)
        -- =====================================================
        IF recipient_email IS NOT NULL
           AND recipient_verified = true
           AND recipient_notifications = true
        THEN
            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', recipient_email,
                    'subject', 'Zaakceptowałeś(aś) request od ' || sender_name,
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection nawiązany!</h1>

    <p>Cześć <strong>' || recipient_name || '</strong>!</p>

    <p>Zaakceptowałeś(aś) connection request od <strong>' || sender_name || '</strong>.</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;">' || sender_name || ' otrzymał(a) Twoje dane kontaktowe i prawdopodobnie niedługo się odezwie.</p>
    </div>

    <p style="color: #718096;">Jeśli chcesz, możesz też sam(a) napisać pierwszą wiadomość!</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans
    </p>
</div>
'
                )
            );
        END IF;

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger on connection_requests UPDATE
DROP TRIGGER IF EXISTS on_connection_accepted ON connection_requests;
CREATE TRIGGER on_connection_accepted
    AFTER UPDATE OF status ON connection_requests
    FOR EACH ROW
    EXECUTE FUNCTION notify_connection_accepted();

-- =====================================================
-- VERIFICATION: Check trigger exists
-- =====================================================
-- SELECT * FROM pg_trigger WHERE tgname = 'on_connection_accepted';
