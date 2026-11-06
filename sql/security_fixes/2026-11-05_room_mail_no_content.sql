-- ============================================================
-- APPLIED 2026-11-05 as room_mail_no_content_2026_11_05 (version 20261105124355). @ciso GO, "pchaj" relayed by @ceo.
-- Room message notification mails stop carrying message content.
-- Why: Resend adds Turbopuffer as sub-processor (objection deadline 2026-11-14, scope of data not
-- disclosed). User: no objection, but message content leaves Resend by 2026-11-13.
-- Before: mail had NEW.subject and NEW.body, sender, type, priority, deadline, message id.
-- After: "You have a new message in room X" + link, in both the mail subject and the HTML.
-- Unchanged: trigger, recipient query, notification setting, verified-only, send limit,
-- tb_html on the room name, tb_subject, owner and ACL (CREATE OR REPLACE keeps them).
-- Guard: md5 of the body read from production 2026-11-05 through the read-only MCP.
-- APPLY: supabase-write apply_migration, name room_mail_no_content_2026_11_05, this file unchanged.
-- VERIFY: 2026-11-05_room_mail_no_content_verify_after_apply.sql (read-only).
-- ROLLBACK: 2026-11-05_room_mail_no_content_rollback.sql (content goes back into the mail).
-- TESTED LOCALLY: sql/tests/run_room_mail_local.sh (postgres:17, stubs for pg_net/auth).
-- ============================================================

BEGIN;

DO $guard$
DECLARE cur text;
BEGIN
  SELECT md5(pg_get_functiondef('public.notify_room_message()'::regprocedure)) INTO cur;
  IF cur IS DISTINCT FROM 'ca322bde9b801dec4274ccc1738f43e2' THEN
    RAISE EXCEPTION 'notify_room_message is not the 2026-11-05 production body (md5 %), aborting', cur;
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
    room_name TEXT;
    email_html TEXT;
BEGIN
    SELECT r.name INTO room_name
    FROM rooms r WHERE r.id = NEW.room_id;

    IF NEW.message_type IN ('request', 'reminder') OR NEW.priority IN ('urgent', 'high') THEN

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

            -- Fixed text + room name + link only. No message field may go into this mail
            -- (Resend sub-processor change, deadline 2026-11-14).
            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <p style="margin: 0 0 20px 0; color: #C9D1D9;">You have a new message in room <strong style="color: #58A6FF;">' || tb_html(COALESCE(room_name, '')) || '</strong></p>

        <p style="margin: 0;"><a href="https://www.thebackroom.ai" style="color: #58A6FF;">Open The Backroom</a></p>
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
                    'subject', tb_subject('You have a new message in room ' || COALESCE(room_name, '')),
                    'html', email_html
                )
            );
        END LOOP;
    END IF;

    RETURN NEW;
END;
$function$;

COMMIT;
