-- Rollback for 2026-11-05_room_mail_no_content.sql (migration APPLIED 2026-11-05, rollback not run; see sql/README.md first).
-- RE-OPENS the hole: restores the production body of 2026-11-05 (md5 ca322bde...), message subject
-- and text go back into the mail and through Resend. Refuses to run over any other body.

BEGIN;

DO $guard$
DECLARE cur text;
BEGIN
  SELECT md5(pg_get_functiondef('public.notify_room_message()'::regprocedure)) INTO cur;
  IF cur IS DISTINCT FROM '43370bf649dc583d902aa655831ba951' THEN
    RAISE EXCEPTION 'notify_room_message is not the no-content body (md5 %), aborting', cur;
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.notify_room_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    recipient RECORD;
    sender_name TEXT;
    room_name TEXT;
    email_html TEXT;
BEGIN
    SELECT p.name INTO sender_name
    FROM profiles p WHERE p.id = NEW.from_profile_id;

    SELECT r.name INTO room_name
    FROM rooms r WHERE r.id = NEW.room_id;

    IF NEW.message_type IN ('request', 'reminder') OR NEW.priority IN ('urgent', 'high') THEN

        -- W44: verified addresses only (before: any address on the profile)
        FOR recipient IN
            SELECT p.email, p.name
            FROM message_recipients mr
            JOIN profiles p ON mr.profile_id = p.id
            WHERE mr.message_id = NEW.id
              AND p.email IS NOT NULL
              AND p.email_verified = true
              AND p.notifications_enabled = true
        LOOP
            CONTINUE WHEN NOT tb_email_send_allowed(recipient.email, 'notification', 20, interval '24 hours', 200);

            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <p style="color: #8B949E; margin: 0 0 10px 0;">Nowa wiadomosc w <strong style="color: #58A6FF;">' || tb_html(COALESCE(room_name, '')) || '</strong></p>

        <h2 style="color: #F0F6FC; margin: 0 0 20px 0;">' || tb_html(COALESCE(NEW.subject, '(brak tematu)')) || '</h2>

        <div style="background: #0D1117; padding: 15px; border-radius: 8px; border-left: 4px solid ' ||
            CASE NEW.priority
                WHEN 'urgent' THEN '#F85149'
                WHEN 'high' THEN '#F0883E'
                ELSE '#238636'
            END || ';">
            <p style="margin: 0; color: #C9D1D9;">' || tb_html(COALESCE(NEW.body, '')) || '</p>
        </div>

        <p style="margin-top: 20px; color: #8B949E;">
            Od: <strong>' || tb_html(COALESCE(sender_name, '')) || '</strong><br>
            Typ: ' || tb_html(COALESCE(NEW.message_type, '')) || '<br>
            Priorytet: <span style="color: ' ||
                CASE NEW.priority
                    WHEN 'urgent' THEN '#F85149'
                    WHEN 'high' THEN '#F0883E'
                    ELSE '#C9D1D9'
                END || ';">' || tb_html(COALESCE(NEW.priority, '')) || '</span>' ||
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
                    'subject', tb_subject('[' || COALESCE(room_name, '') || '] ' || COALESCE(NEW.subject, 'Nowa wiadomosc')),
                    'html', email_html
                )
            );
        END LOOP;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
