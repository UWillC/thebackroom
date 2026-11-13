-- READ-ONLY verification of 2026-11-12_w2_revoke_public_secdef.sql. Safe with the read-only MCP.
-- After apply: every row ok = true, last row "== ALL OK ==" = true. Any false = stop, call @cto/@ciso.
-- Before apply: run once and keep the "INFO: ACL" row (pre-state for the rollback); expected false then on the
-- "PUBLIC has no EXECUTE" rows and on W2b.
-- W2b row = @ciso query W2b (all schemas, no USAGE filter): the only SECURITY DEFINER functions PUBLIC may execute
-- are the 4 @ciso accepted by name on 2026-11-12. A function outside that list (e.g. in vault/pgbouncer) makes the row
-- false: hand the detail to @ciso for classification, do not "fix" the verify file.
-- The backup_ro row passes when the role does not exist yet (either order with backup_ro_role_fallback_2026_11_12).
WITH target(f) AS (
  VALUES ('public.verify_email_token(text,text)'),
         ('public.wc2026_reset(text)'),
         ('public.wc2026_save(text,integer,integer,integer,integer,integer,text,text)')
),
t AS (
  SELECT f, p.oid, p.proowner, p.proacl,
         EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE') AS public_exec
    FROM target LEFT JOIN pg_proc p ON p.oid = to_regprocedure(target.f)
),
accepted AS (
  SELECT to_regprocedure(x)::oid AS oid
    FROM unnest(ARRAY['public.get_my_profile_id()', 'public.is_room_member(uuid)', 'public.owns_profile(text)',
                      'public.wc2026_get_matches()']) x
   WHERE to_regprocedure(x) IS NOT NULL
),
w2b AS (
  SELECT p.oid, format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS f
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
),
bro AS (SELECT oid FROM pg_roles WHERE rolname = 'backup_ro'),
checks(check_name, ok, detail) AS (
  SELECT 'the 3 functions exist (exact signatures)', count(oid) = 3,
         coalesce(string_agg(f, ', ') FILTER (WHERE oid IS NULL), '') FROM t
  UNION ALL
  SELECT 'PUBLIC has no EXECUTE: ' || f, oid IS NOT NULL AND NOT public_exec, '' FROM t
  UNION ALL
  SELECT 'anon, authenticated, service_role can EXECUTE: ' || f,
         oid IS NOT NULL AND has_function_privilege('anon', oid, 'EXECUTE')
           AND has_function_privilege('authenticated', oid, 'EXECUTE')
           AND has_function_privilege('service_role', oid, 'EXECUTE'), '' FROM t
  UNION ALL
  SELECT 'explicit grantees (besides owner) = exactly anon, authenticated, service_role: ' || t.f,
         t.oid IS NOT NULL AND coalesce((
           SELECT array_agg(g ORDER BY g) FROM (
             SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS g
               FROM aclexplode(coalesce(t.proacl, acldefault('f', t.proowner))) a
              WHERE a.privilege_type = 'EXECUTE' AND a.grantee <> t.proowner) s), '{}')
           = ARRAY['anon', 'authenticated', 'service_role'],
         coalesce((SELECT string_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END, ',')
                     FROM aclexplode(coalesce(t.proacl, acldefault('f', t.proowner))) a
                    WHERE a.privilege_type = 'EXECUTE' AND a.grantee <> t.proowner), 'none')
    FROM t
  UNION ALL
  SELECT 'backup_ro (if it exists) cannot EXECUTE the 3',
         NOT EXISTS (SELECT 1 FROM bro, t WHERE t.oid IS NOT NULL AND has_function_privilege(bro.oid, t.oid, 'EXECUTE')),
         CASE WHEN EXISTS (SELECT 1 FROM bro) THEN 'role exists' ELSE 'role does not exist yet' END
  UNION ALL
  SELECT 'W2b: SECDEF executable by PUBLIC (all schemas) = only the 4 accepted by @ciso',
         count(*) FILTER (WHERE w2b.oid NOT IN (SELECT oid FROM accepted)) = 0,
         format('%s total, not accepted: %s', count(*),
                left(coalesce(string_agg(w2b.f, ', ' ORDER BY w2b.f) FILTER (WHERE w2b.oid NOT IN (SELECT oid FROM accepted)), ''), 600))
    FROM w2b
  UNION ALL
  SELECT 'INFO: W2b full list', true, left(coalesce(string_agg(f, ', ' ORDER BY f), ''), 800) FROM w2b
  UNION ALL
  SELECT 'INFO: ACL (owner, proacl) of the 3', true,
         string_agg(format('%s owner=%s acl=%s', f, proowner::regrole, coalesce(proacl::text, 'NULL (default)')), ' | ') FROM t
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok), format('%s of %s failed', count(*) FILTER (WHERE NOT ok), count(*)) FROM checks;
