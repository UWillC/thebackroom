-- READ-ONLY (@ciso W4/N1, after drop_room_message_trigger_2026_11_05). The policy says room messages are not sent
-- by e-mail. That holds by construction while these rows are true. Any false = the policy may be untrue:
-- stop, call @cto/@ciso before changing anything. ok = NULL counts as a failure.
WITH mailers AS (   -- functions that can send mail
  SELECT p.oid, p.proname::text AS name, pg_get_functiondef(p.oid) AS def
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.prokind IN ('f', 'p')
    AND (pg_get_functiondef(p.oid) ILIKE '%api.resend.com%' OR pg_get_functiondef(p.oid) ILIKE '%http_post%')
),
checks(check_name, ok, detail) AS (
  SELECT 'no trigger on room_messages or message_recipients',
         NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE NOT t.tgisinternal
                      AND t.tgrelid IN ('public.room_messages'::regclass, 'public.message_recipients'::regclass)),
         COALESCE((SELECT string_agg(t.tgname, ', ') FROM pg_trigger t WHERE NOT t.tgisinternal
                     AND t.tgrelid IN ('public.room_messages'::regclass, 'public.message_recipients'::regclass)), '')
  UNION ALL
  SELECT 'notify_room_message attached to no trigger',
         NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgfoid = to_regprocedure('public.notify_room_message()')), ''
  UNION ALL
  SELECT 'notify_room_message is the no-content body',
         COALESCE(md5(pg_get_functiondef(to_regprocedure('public.notify_room_message()'))) = '43370bf649dc583d902aa655831ba951', false), ''
  UNION ALL
  SELECT 'no other mailing function reads room messages',
         NOT EXISTS (SELECT 1 FROM mailers m WHERE m.name <> 'notify_room_message'
                      AND (m.def ILIKE '%room_messages%' OR m.def ILIKE '%message_recipients%')),
         COALESCE((SELECT string_agg(m.name, ', ') FROM mailers m WHERE m.name <> 'notify_room_message'
                     AND (m.def ILIKE '%room_messages%' OR m.def ILIKE '%message_recipients%')), '')
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(COALESCE(ok, false)), count(*) FILTER (WHERE ok IS NOT TRUE) || ' failed of ' || count(*) FROM checks
ORDER BY 2, 1;
