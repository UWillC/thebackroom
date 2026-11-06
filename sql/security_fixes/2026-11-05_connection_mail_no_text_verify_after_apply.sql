-- READ-ONLY verification after 2026-11-05_connection_mail_no_text.sql. Safe with the read-only MCP.
-- Expected: every row ok = true. Any false = stop, call @cto/@ciso.
-- Note: rows 'md5: notify_connection_request' and 'md5: notify_connection_accepted' of
-- 2026-10-26_w44_verify_after_apply.sql turn false after this migration, by design.
WITH fn AS (
  SELECT p.oid, p.proname::text AS name, p.prosecdef, p.proconfig, pg_get_functiondef(p.oid) AS def,
         COALESCE(p.proacl, acldefault('f', p.proowner)) AS acl
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('notify_connection_request', 'notify_connection_accepted')
),
expect(name, md5_ok, trg) AS (VALUES
  ('notify_connection_request', 'afe33640be139e29d07808cf2217d125', 'on_new_connection_request'),
  ('notify_connection_accepted', '25f44f42b3d607e865200104045354c0', 'on_connection_accepted')
),
checks(check_name, ok, detail) AS (
  SELECT 'both functions exist', count(*) = 2, count(*)::text FROM fn
  UNION ALL
  SELECT 'md5: ' || f.name, md5(f.def) = e.md5_ok, md5(f.def) FROM fn f JOIN expect e USING (name)
  UNION ALL
  SELECT 'no free text: ' || name, def !~* 'NEW\.(message|response_message)\M', '' FROM fn
  UNION ALL
  SELECT 'LinkedIn and preferred contact stay', def LIKE '%recipient_linkedin%' AND def LIKE '%recipient_contact%', ''
    FROM fn WHERE name = 'notify_connection_accepted'
  UNION ALL
  SELECT 'security definer, search_path pinned: ' || name,
         prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'], COALESCE(proconfig::text, 'NULL') FROM fn
  UNION ALL
  SELECT 'no API role may execute: ' || f.name,
         NOT EXISTS (SELECT 1 FROM aclexplode(f.acl) a WHERE a.privilege_type = 'EXECUTE'
                      AND (a.grantee = 0 OR a.grantee IN ('anon'::regrole, 'authenticated'::regrole))), f.acl::text FROM fn f
  UNION ALL
  SELECT 'trigger enabled and bound: ' || e.trg,
         EXISTS (SELECT 1 FROM pg_trigger t JOIN fn f ON f.oid = t.tgfoid
                  WHERE t.tgrelid = 'public.connection_requests'::regclass AND t.tgname = e.trg
                    AND f.name = e.name AND t.tgenabled = 'O'), '' FROM expect e
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok), count(*) FILTER (WHERE NOT ok) || ' failed of ' || count(*) FROM checks
ORDER BY 2, 1;
