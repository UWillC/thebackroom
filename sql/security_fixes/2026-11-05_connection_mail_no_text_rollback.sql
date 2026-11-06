-- Rollback for 2026-11-05_connection_mail_no_text.sql (NOT APPLIED, same as the migration).
-- RE-OPENS the hole: these mails are live, so user text goes through Resend again. Needs @ciso + user.
-- Refuses to run over any other body.

BEGIN;

DO $guard$
DECLARE r record; cur text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('notify_connection_request', 'afe33640be139e29d07808cf2217d125'),
    ('notify_connection_accepted', '25f44f42b3d607e865200104045354c0')
  ) AS t(fname, md5_ok) LOOP
    SELECT md5(pg_get_functiondef(to_regprocedure('public.' || r.fname || '()'))) INTO cur;
    IF cur IS DISTINCT FROM r.md5_ok THEN
      RAISE EXCEPTION '% is not the no-text body (md5 %), aborting', r.fname, cur;
    END IF;
  END LOOP;
END $guard$;

CREATE OR REPLACE FUNCTION public.notify_connection_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    sender_name TEXT;
    sender_role TEXT;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
    s_name TEXT;
BEGIN
    SELECT name, role INTO sender_name, sender_role
    FROM profiles WHERE id = NEW.from_user;

    SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
    INTO recipient_email, recipient_name, recipient_verified, recipient_notifications
    FROM profiles WHERE id = NEW.to_user;

    s_name := tb_html(COALESCE(sender_name, ''));

    IF recipient_email IS NOT NULL
       AND recipient_verified = true
       AND recipient_notifications = true
       AND tb_email_send_allowed(recipient_email, 'notification', 20, interval '24 hours', 200)
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
                'subject', tb_subject(COALESCE(sender_name, '') || ' chce się z Tobą połączyć!'),
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🤝 Nowy Connection Request!</h1>

    <p>Cześć <strong>' || tb_html(COALESCE(recipient_name, '')) || '</strong>!</p>

    <p><strong>' || s_name || '</strong> (' || tb_html(COALESCE(sender_role, 'Członek sieci')) || ') chce się z Tobą połączyć w The Backroom.</p>

    ' || CASE WHEN NEW.message IS NOT NULL AND NEW.message != '' THEN '
    <div style="background: #F7FAFC; padding: 15px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #6B46C1;">
        <p style="margin: 0; font-style: italic;">"' || tb_html(NEW.message) || '"</p>
    </div>
    ' ELSE '' END || '

    <p>Aby odpowiedzieć, powiedz swojemu asystentowi AI:</p>
    <ul>
        <li><code>"Sprawdź moje requesty w The Backroom"</code></li>
        <li><code>"Odpowiedz na request od ' || s_name || '"</code></li>
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
$function$;

CREATE OR REPLACE FUNCTION public.notify_connection_accepted()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    s_name TEXT;   -- escaped copies
    r_name TEXT;
    r_link TEXT;
BEGIN
    IF OLD.status != 'accepted' AND NEW.status = 'accepted' THEN

        SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
        INTO sender_email, sender_name, sender_verified, sender_notifications
        FROM profiles WHERE id = NEW.from_user;

        SELECT email, name, role, email_verified, COALESCE(notifications_enabled, true),
               linkedin_url, preferred_contact
        INTO recipient_email, recipient_name, recipient_role, recipient_verified,
             recipient_notifications, recipient_linkedin, recipient_contact
        FROM profiles WHERE id = NEW.to_user;

        s_name := tb_html(COALESCE(sender_name, ''));
        r_name := tb_html(COALESCE(recipient_name, ''));
        r_link := tb_html(tb_safe_url(recipient_linkedin));

        -- EMAIL 1: to the SENDER (their request was accepted)
        IF sender_email IS NOT NULL
           AND sender_verified = true
           AND sender_notifications = true
           AND tb_email_send_allowed(sender_email, 'notification', 20, interval '24 hours', 200)
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
                    'subject', tb_subject(COALESCE(recipient_name, '') || ' zaakceptował(a) Twój request!'),
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection Accepted!</h1>

    <p>Cześć <strong>' || s_name || '</strong>!</p>

    <p>Świetna wiadomość - <strong>' || r_name || '</strong> zaakceptował(a) Twój connection request!</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;"><strong>Napisz. Krótko się przedstaw. Umówcie się na kawę lub call.</strong></p>
    </div>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">Dane kontaktowe:</h3>
        <ul style="list-style: none; padding: 0; margin: 0;">
            <li><strong>Imię:</strong> ' || r_name || '</li>
            <li><strong>Rola:</strong> ' || tb_html(COALESCE(recipient_role, 'Nie podano')) || '</li>
            ' || CASE WHEN r_link IS NOT NULL THEN '
            <li><strong>LinkedIn:</strong> <a href="' || r_link || '">' || r_link || '</a></li>
            ' WHEN recipient_linkedin IS NOT NULL THEN '
            <li><strong>LinkedIn:</strong> ' || tb_html(recipient_linkedin) || '</li>
            ' ELSE '' END || '
            <li><strong>Preferowany kontakt:</strong> ' || tb_html(COALESCE(recipient_contact, 'Nie podano')) || '</li>
        </ul>
    </div>

    ' || CASE WHEN NEW.response_message IS NOT NULL AND NEW.response_message != '' THEN '
    <div style="background: #EBF8FF; padding: 15px; border-radius: 8px; margin: 20px 0;">
        <p style="margin: 0;"><strong>Wiadomość od ' || r_name || ':</strong></p>
        <p style="margin: 10px 0 0 0; font-style: italic;">"' || tb_html(NEW.response_message) || '"</p>
    </div>
    ' ELSE '' END || '

    <h3>Sugerowana pierwsza wiadomość:</h3>
    <div style="background: #FFFAF0; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 14px;">
        Cześć ' || r_name || '!<br><br>
        Dzięki za akceptację w The Backroom.<br>
        [WSTAW: krótko czego szukasz / co oferujesz]<br><br>
        Masz czas na krótki call w tym tygodniu?<br><br>
        Pozdrawiam,<br>
        ' || s_name || '
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

        -- EMAIL 2: to the RECIPIENT (confirmation)
        IF recipient_email IS NOT NULL
           AND recipient_verified = true
           AND recipient_notifications = true
           AND tb_email_send_allowed(recipient_email, 'notification', 20, interval '24 hours', 200)
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
                    'subject', tb_subject('Zaakceptowałeś(aś) request od ' || COALESCE(sender_name, '')),
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection nawiązany!</h1>

    <p>Cześć <strong>' || r_name || '</strong>!</p>

    <p>Zaakceptowałeś(aś) connection request od <strong>' || s_name || '</strong>.</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;">' || s_name || ' otrzymał(a) Twoje dane kontaktowe i prawdopodobnie niedługo się odezwie.</p>
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
$function$;

COMMIT;
