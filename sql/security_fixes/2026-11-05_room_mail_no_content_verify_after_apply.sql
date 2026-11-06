-- READ-ONLY verification after 2026-11-05_room_mail_no_content.sql. Safe with the read-only MCP.
-- Expected: every row ok = true. Any false = stop, call @cto/@ciso.
-- Note: 2026-10-26_w44_verify_after_apply.sql row 'md5: notify_room_message' turns false after this
-- migration, by design. That file describes the state of 2026-10-26.
WITH fn AS (
  SELECT p.oid, p.prosecdef, p.proconfig, p.proowner, pg_get_functiondef(p.oid) AS def,
         COALESCE(p.proacl, acldefault('f', p.proowner)) AS acl
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'notify_room_message'
),
checks(check_name, ok, detail) AS (
  SELECT 'md5 = reviewed body', md5(def) = '43370bf649dc583d902aa655831ba951', md5(def) FROM fn
  UNION ALL
  SELECT 'no message field in the body', def !~* 'NEW\.(subject|body|deadline|from_profile_id)|sender_name', '' FROM fn
  UNION ALL
  SELECT 'fixed sentence and link present',
         def LIKE '%You have a new message in room %' AND def LIKE '%href="https://www.thebackroom.ai"%', '' FROM fn
  UNION ALL
  SELECT 'room name escaped', def LIKE '%tb_html(COALESCE(room_name, %', '' FROM fn
  UNION ALL
  SELECT 'security definer, search_path pinned',
         prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'], COALESCE(proconfig::text, 'NULL') FROM fn
  UNION ALL
  SELECT 'no API role may execute',
         NOT EXISTS (SELECT 1 FROM fn f, aclexplode(f.acl) a WHERE a.privilege_type = 'EXECUTE'
                      AND (a.grantee = 0 OR a.grantee IN ('anon'::regrole, 'authenticated'::regrole))),
         (SELECT acl::text FROM fn)
  UNION ALL
  SELECT 'trigger present, enabled, bound to the function',
         EXISTS (SELECT 1 FROM pg_trigger t JOIN fn f ON f.oid = t.tgfoid
                  WHERE t.tgrelid = 'public.room_messages'::regclass AND t.tgname = 'on_room_message_sent'
                    AND t.tgenabled = 'O' AND NOT t.tgisinternal), ''
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok), count(*) FILTER (WHERE NOT ok) || ' failed of ' || count(*) FROM checks
ORDER BY 2, 1;
