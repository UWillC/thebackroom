-- Rollback for 2026-11-05_drop_room_message_trigger.sql. Re-attaches on_room_message_sent to the no-content
-- notify_room_message (md5 43370bf6...). While send_room_message adds recipients after the message, this still
-- mails nothing; the policy sentence stays true. If the send order has been fixed by then: policy first, @ciso.
-- Refuses when the trigger already exists or the function is not the no-content body.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.room_messages'::regclass AND tgname = 'on_room_message_sent') THEN
    RAISE EXCEPTION 'on_room_message_sent already exists, nothing to roll back';
  END IF;
  IF md5(pg_get_functiondef('public.notify_room_message()'::regprocedure)) IS DISTINCT FROM '43370bf649dc583d902aa655831ba951' THEN
    RAISE EXCEPTION 'notify_room_message is not the no-content body, aborting';
  END IF;
END $guard$;

CREATE TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages FOR EACH ROW WHEN (((new.message_type = ANY (ARRAY['request'::text, 'reminder'::text])) OR (new.priority = ANY (ARRAY['urgent'::text, 'high'::text])))) EXECUTE FUNCTION public.notify_room_message();

DO $check$
BEGIN
  IF (SELECT md5(pg_get_triggerdef(t.oid)) FROM pg_trigger t WHERE t.tgrelid = 'public.room_messages'::regclass
        AND t.tgname = 'on_room_message_sent') IS DISTINCT FROM '156e5d9d683c7204ee4ec09afa96fe2e' THEN
    RAISE EXCEPTION 'restored trigger differs from the 2026-11-05 production definition, aborting';
  END IF;
END $check$;

COMMIT;
