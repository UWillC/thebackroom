-- ============================================================
-- NOT APPLIED. Needs @ciso GO + user "pchaj" (user 2026-11-05: "2 pchaj", @ciso proposal accepted).
-- Removes trigger on_room_message_sent. Room messages are then not mailed by any path, which is what the
-- privacy policy says ("We do not send e-mail when a message is sent to you in a room").
-- The function notify_room_message (no-content body, md5 43370bf6...) stays, so the rollback can re-attach it.
-- Guard: trigger definition and function body as read from production 2026-11-05.
-- APPLY: supabase-write apply_migration, name drop_room_message_trigger_2026_11_05, this file unchanged.
-- VERIFY: 2026-11-05_room_mail_send_paths_verify.sql (read-only), all rows true.
-- ROLLBACK: 2026-11-05_drop_room_message_trigger_rollback.sql (trigger back on the no-content function).
-- TESTED LOCALLY: sql/tests/run_room_mail_local.sh.
-- ============================================================

BEGIN;

DO $guard$
DECLARE d text;
BEGIN
  SELECT md5(pg_get_triggerdef(t.oid)) INTO d FROM pg_trigger t
   WHERE t.tgrelid = 'public.room_messages'::regclass AND t.tgname = 'on_room_message_sent';
  IF d IS DISTINCT FROM '156e5d9d683c7204ee4ec09afa96fe2e' THEN
    RAISE EXCEPTION 'on_room_message_sent is not the 2026-11-05 production trigger (md5 %), aborting', d;
  END IF;
  IF md5(pg_get_functiondef('public.notify_room_message()'::regprocedure)) IS DISTINCT FROM '43370bf649dc583d902aa655831ba951' THEN
    RAISE EXCEPTION 'notify_room_message is not the no-content body, aborting';
  END IF;
END $guard$;

DROP TRIGGER on_room_message_sent ON public.room_messages;

DO $check$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgfoid = 'public.notify_room_message()'::regprocedure) THEN
    RAISE EXCEPTION 'notify_room_message is still attached to a trigger, aborting';
  END IF;
END $check$;

COMMIT;
