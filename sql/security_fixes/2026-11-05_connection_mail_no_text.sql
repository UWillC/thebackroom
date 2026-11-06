-- ============================================================
-- NOT APPLIED. Needs @ciso review of this diff + user "pchaj". The "pchaj" of 2026-11-05 did NOT cover this.
-- Connection mails stop carrying text written by the user (user decision 2026-11-05, Resend sub-processor change).
-- notify_connection_request: without NEW.message. notify_connection_accepted: without NEW.response_message.
-- Stay, by user decision: LinkedIn and preferred contact. Stay unchanged: names, roles, recipients,
-- verified-only, notification setting, send limit, tb_html, triggers, owner, ACL.
-- Guard: md5 of both bodies read from production 2026-11-05 through the read-only MCP.
-- APPLY: supabase-write apply_migration, name connection_mail_no_text_2026_11_05, this file unchanged.
-- VERIFY: 2026-11-05_connection_mail_no_text_verify_after_apply.sql (read-only).
-- ROLLBACK: 2026-11-05_connection_mail_no_text_rollback.sql (text goes back into the mails).
-- TESTED LOCALLY: sql/tests/run_connection_mail_local.sh (postgres:17, stubs for pg_net/auth).
-- ============================================================

BEGIN;

DO $guard$
DECLARE r record; cur text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('notify_connection_request', '36739fc73168e1a322c3b2654f793ac9'),
    ('notify_connection_accepted', '5f9f831afdd47c99a9695c1c780f5ab0')
  ) AS t(fname, md5_ok) LOOP
    SELECT md5(pg_get_functiondef(to_regprocedure('public.' || r.fname || '()'))) INTO cur;
    IF cur IS DISTINCT FROM r.md5_ok THEN
      RAISE EXCEPTION '% is not the 2026-11-05 production body (md5 %), aborting', r.fname, cur;
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
