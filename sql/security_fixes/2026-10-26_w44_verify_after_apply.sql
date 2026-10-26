-- ============================================================
-- READ-ONLY verification after 2026-10-26_w44_19_20_hardening.sql (@ciso W3, @cto 2026-10-26).
-- Reads pg_catalog (proacl / relacl / attacl / pg_policy), NOT information_schema: the
-- information_schema views show only grants visible to the current role and come back empty
-- for supabase_read_only_user. Safe to run with the read-only MCP (execute_sql).
-- Expected result: every row ok = true. Any false = stop, do not deploy code, call @cto/@ciso.
-- Note: proacl NULL means the default ACL = EXECUTE for PUBLIC, so NULL counts as "PUBLIC can".
-- ============================================================
WITH fn AS (
  SELECT p.oid, p.proname::text AS name, p.prosecdef,
         COALESCE(p.proacl, acldefault('f', p.proowner)) AS acl
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('tb_html', 'tb_subject', 'tb_safe_url', 'tb_email_send_allowed', 'tb_can_self_join',
                      'register_profile', 'get_email_status', 'join_room_with_invite', 'resend_verification_email')
),
fn_exec AS (   -- who has EXECUTE: 'PUBLIC' or role name
  SELECT f.name, CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS who
  FROM fn f, aclexplode(f.acl) a WHERE a.privilege_type = 'EXECUTE'
),
expect(name, allowed) AS (VALUES   -- API roles that SHOULD have EXECUTE (all others must not)
  ('tb_html',                   ARRAY[]::text[]),
  ('tb_subject',                ARRAY[]::text[]),
  ('tb_safe_url',               ARRAY[]::text[]),
  ('tb_email_send_allowed',     ARRAY[]::text[]),
  ('tb_can_self_join',          ARRAY['authenticated']),
  ('register_profile',          ARRAY[]::text[]),
  ('get_email_status',          ARRAY['anon', 'authenticated']),
  ('join_room_with_invite',     ARRAY['authenticated']),
  ('resend_verification_email', ARRAY[]::text[])
),
checks AS (
  -- 1. each function exists exactly once
  SELECT 'exists: ' || e.name AS check_name,
         (SELECT count(*) FROM fn WHERE fn.name = e.name) = 1 AS ok,
         (SELECT count(*) FROM fn WHERE fn.name = e.name)::text AS detail
  FROM expect e
  UNION ALL
  -- 2. API roles with EXECUTE = exactly the expected set
  SELECT 'execute: ' || e.name,
         COALESCE((SELECT array_agg(who ORDER BY who) FROM fn_exec x
                    WHERE x.name = e.name AND x.who IN ('PUBLIC', 'anon', 'authenticated')), '{}')
           = (SELECT COALESCE(array_agg(v ORDER BY v), '{}') FROM unnest(e.allowed) v),
         COALESCE((SELECT string_agg(who, ',' ORDER BY who) FROM fn_exec x WHERE x.name = e.name), '-')
  FROM expect e
  UNION ALL
  -- 3. service_role can run the RPCs the MCP server calls with the service key
  SELECT 'service_role execute: ' || n,
         EXISTS (SELECT 1 FROM fn_exec x WHERE x.name = n AND x.who = 'service_role'), ''
  FROM unnest(ARRAY['register_profile', 'resend_verification_email', 'get_email_status', 'join_room_with_invite']) n
  UNION ALL
  -- 4. SECURITY DEFINER where the design needs it
  SELECT 'security definer: ' || name, prosecdef, ''
  FROM fn WHERE name IN ('register_profile', 'get_email_status', 'join_room_with_invite',
                         'tb_email_send_allowed', 'tb_can_self_join', 'resend_verification_email')
  UNION ALL
  -- 5. email_send_log: RLS on, no policies, no API grants, service_role grant present
  SELECT 'email_send_log rls on, 0 policies',
         c.relrowsecurity AND NOT EXISTS (SELECT 1 FROM pg_policy pol WHERE pol.polrelid = c.oid),
         c.relrowsecurity::text
  FROM pg_class c WHERE c.oid = 'public.email_send_log'::regclass
  UNION ALL
  SELECT 'email_send_log no PUBLIC/anon/authenticated grant',
         NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
                      WHERE a.grantee = 0 OR a.grantee IN ('anon'::regrole, 'authenticated'::regrole)),
         COALESCE(c.relacl::text, 'NULL')
  FROM pg_class c WHERE c.oid = 'public.email_send_log'::regclass
  UNION ALL
  SELECT 'email_send_log service_role select/insert/delete',
         has_table_privilege('service_role', 'public.email_send_log', 'SELECT,INSERT,DELETE')
         AND (SELECT count(DISTINCT a.privilege_type) FROM pg_class c, aclexplode(c.relacl) a
               WHERE c.oid = 'public.email_send_log'::regclass AND a.grantee = 'service_role'::regrole
                 AND a.privilege_type IN ('SELECT', 'INSERT', 'DELETE')) = 3,
         ''
  UNION ALL
  -- 6. profiles: no table-level SELECT/INSERT/UPDATE for API roles, only DELETE for authenticated
  SELECT 'profiles table-level ACL (API roles)',
         COALESCE((SELECT array_agg(CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
                                    || ':' || a.privilege_type ORDER BY 1)
                     FROM pg_class c, aclexplode(c.relacl) a
                    WHERE c.oid = 'public.profiles'::regclass
                      AND (a.grantee = 0 OR a.grantee IN ('anon'::regrole, 'authenticated'::regrole))), '{}')
           = ARRAY['authenticated:DELETE'],
         (SELECT relacl::text FROM pg_class WHERE oid = 'public.profiles'::regclass)
  UNION ALL
  -- 7. profiles column ACLs (attacl): secret columns not readable, write columns only for authenticated
  SELECT 'profiles col ' || r || ' ' || col || ' ' || priv,
         has_column_privilege(r, 'public.profiles', col, priv) = should,
         has_column_privilege(r, 'public.profiles', col, priv)::text
  FROM (VALUES
    ('anon', 'email', 'SELECT', false), ('anon', 'auth_user_id', 'SELECT', false),
    ('anon', 'email_verification_token', 'SELECT', false),
    ('authenticated', 'email', 'SELECT', false), ('authenticated', 'auth_user_id', 'SELECT', false),
    ('authenticated', 'email_verification_token', 'SELECT', false),
    ('anon', 'name', 'SELECT', true), ('anon', 'email_verified', 'SELECT', true),
    ('anon', 'name', 'INSERT', false), ('authenticated', 'name', 'INSERT', false),
    ('anon', 'bio', 'UPDATE', false), ('authenticated', 'bio', 'UPDATE', true),
    ('authenticated', 'email_verified', 'UPDATE', false), ('authenticated', 'auth_user_id', 'UPDATE', false),
    ('authenticated', 'name', 'UPDATE', false), ('authenticated', 'email_verification_token', 'UPDATE', false)
  ) t(r, col, priv, should)
  UNION ALL
  -- 8. policies
  SELECT 'profiles: no INSERT policy',
         NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.profiles'::regclass AND polcmd = 'a'), ''
  UNION ALL
  SELECT 'room_members_insert limits self-insert',
         pg_get_expr(polwithcheck, polrelid) LIKE '%tb_can_self_join%'
         AND pg_get_expr(polwithcheck, polrelid) LIKE '%''pending''%', ''
  FROM pg_policy WHERE polrelid = 'public.room_members'::regclass AND polname = 'room_members_insert'
  UNION ALL
  SELECT 'room_members_delete blocks own offboarded row',
         pg_get_expr(polqual, polrelid) LIKE '%offboarded%', ''
  FROM pg_policy WHERE polrelid = 'public.room_members'::regclass AND polname = 'room_members_delete'
  UNION ALL
  -- 9. constraints / index
  SELECT 'profiles_id_format + profiles_email_lower_key',
         EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.profiles'::regclass AND conname = 'profiles_id_format')
         AND to_regclass('public.profiles_email_lower_key') IS NOT NULL, ''
  UNION ALL
  -- 10. the 9 trigger/service mail functions kept their ACL (no API role)
  SELECT 'mail fn no API execute: ' || p.proname,
         NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                      WHERE a.privilege_type = 'EXECUTE'
                        AND (a.grantee = 0 OR a.grantee IN ('anon'::regrole, 'authenticated'::regrole))),
         COALESCE(p.proacl::text, 'NULL')
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('send_verification_email', 'notify_new_profile', 'send_welcome_email_after_verification',
                      'notify_connection_accepted', 'notify_connection_request', 'notify_room_invite',
                      'notify_room_member_approved', 'notify_room_message', 'send_weekly_matches_email')
  UNION ALL
  -- 11. bodies = the reviewed ones (md5 measured on postgres:17 by sql/tests/run_w44_local.sh)
  SELECT 'md5: ' || p.proname, md5(pg_get_functiondef(p.oid)) = m.md5, md5(pg_get_functiondef(p.oid))
  FROM pg_proc p JOIN (VALUES
    ('send_verification_email',               '4ec5ca19f0e39f5d80af4827503d7878'),
    ('resend_verification_email',             'ef0e16b47f239198e9db8988fe10cc0c'),
    ('notify_new_profile',                    'f28cc562832f991ae089a142e39139a4'),
    ('send_welcome_email_after_verification', 'db7ab1f85b7d346118c51d4968352d7b'),
    ('notify_connection_accepted',            '5f9f831afdd47c99a9695c1c780f5ab0'),
    ('notify_connection_request',             '36739fc73168e1a322c3b2654f793ac9'),
    ('notify_room_invite',                    '4b27280d7eaf436450a888246ab41797'),
    ('notify_room_member_approved',           '33294880c050cb484830eaeca7400041'),
    ('notify_room_message',                   'ca322bde9b801dec4274ccc1738f43e2'),
    ('send_weekly_matches_email',             '0917b95d5ea952ac3eebb0a49e02a0cf'),
    ('join_room_with_invite',                 '426a064dc2a4b472fa145a9aa0d9c1ab')
  ) m(name, md5) ON m.name = p.proname
  WHERE p.pronamespace = 'public'::regnamespace
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok), count(*) FILTER (WHERE NOT ok) || ' failed of ' || count(*) FROM checks
ORDER BY 2, 1;
