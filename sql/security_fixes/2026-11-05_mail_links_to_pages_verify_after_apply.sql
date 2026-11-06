-- READ-ONLY verification after 2026-11-05_mail_links_to_pages.sql. Safe with the read-only MCP.
-- Expected: every row ok = true. Any false = stop, call @cto/@ciso.
-- Note: md5 rows of earlier verify files for these 9 functions (w44, connection_mail_no_text) turn false
-- after this migration, by design.
WITH fn AS (
  SELECT p.oid, p.proname::text AS name, p.prosecdef, p.proconfig, pg_get_functiondef(p.oid) AS def,
         COALESCE(p.proacl, acldefault('f', p.proowner)) AS acl
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN (
    'send_verification_email', 'resend_verification_email', 'notify_connection_accepted', 'notify_connection_request',
    'notify_new_profile', 'notify_room_invite', 'notify_room_member_approved', 'send_weekly_matches_email',
    'send_welcome_email_after_verification')
),
expect(name, md5_ok, is_verify) AS (VALUES
  ('send_verification_email', '2c1bf8f8e967d9011c58c1be2be46aa1', 1),
  ('resend_verification_email', '87912d665262670628a5cee78884bb10', 1),
  ('notify_connection_accepted', '4325336202ced3c3bb4278735efe8c7e', 0),
  ('notify_connection_request', '91d94cc35ab9b92c2bdbe2cc3e88743e', 0),
  ('notify_new_profile', 'f3d6ec8daee76088a5339647a15d69f4', 0),
  ('notify_room_invite', '13f80c0304dcefb54d8d4432bf765a24', 0),
  ('notify_room_member_approved', 'de14ce75e626101cb8e967729a1f9bd1', 0),
  ('send_weekly_matches_email', '71d35a3bf79ee3a4e3527f9203e0be07', 0),
  ('send_welcome_email_after_verification', '855954fbe5dc9b6e45abe4e8441c81eb', 0)
),
checks(check_name, ok, detail) AS (
  SELECT 'all 9 functions exist once', count(*) = 9 AND count(DISTINCT name) = 9, count(*)::text FROM fn
  UNION ALL
  SELECT 'md5: ' || f.name, md5(f.def) = e.md5_ok, md5(f.def) FROM fn f JOIN expect e USING (name)
  UNION ALL
  SELECT 'no public function mentions huggingface', count(*) = 0, count(*)::text
    FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND prosrc ILIKE '%huggingface%'
  UNION ALL
  SELECT 'verify link uses the fragment: ' || f.name,
         f.def LIKE '%''https://www.thebackroom.ai/app/#verify='' || %' AND f.def NOT LIKE '%?verify=%', ''
    FROM fn f JOIN expect e USING (name) WHERE e.is_verify = 1
  UNION ALL
  SELECT 'footer link points at /app/: ' || f.name, f.def LIKE '%href="https://www.thebackroom.ai/app/"%', ''
    FROM fn f JOIN expect e USING (name) WHERE e.is_verify = 0
  UNION ALL
  SELECT 'security definer, search_path pinned: ' || name,
         prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'], COALESCE(proconfig::text, 'NULL') FROM fn
  UNION ALL
  SELECT 'no API role may execute: ' || f.name,
         NOT EXISTS (SELECT 1 FROM aclexplode(f.acl) a WHERE a.privilege_type = 'EXECUTE'
                      AND (a.grantee = 0 OR a.grantee IN ('anon'::regrole, 'authenticated'::regrole))), f.acl::text FROM fn f
  UNION ALL
  SELECT 'trigger enabled: ' || t.tgname, t.tgenabled = 'O', t.tgenabled::text
    FROM pg_trigger t JOIN fn f ON f.oid = t.tgfoid WHERE NOT t.tgisinternal
  UNION ALL
  SELECT '6 triggers bound to these functions', count(*) = 6, count(*)::text
    FROM pg_trigger t JOIN fn f ON f.oid = t.tgfoid WHERE NOT t.tgisinternal
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok), count(*) FILTER (WHERE NOT ok) || ' failed of ' || count(*) FROM checks
ORDER BY 2, 1;
