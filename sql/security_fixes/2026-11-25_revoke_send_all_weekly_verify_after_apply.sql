-- READ-ONLY verification of 2026-11-25_revoke_send_all_weekly.sql. Safe with the read-only MCP. Returns no row data,
-- only catalog facts (ACL of two functions).
-- After apply: every row ok = true, last row "== ALL OK ==" = true. Any false = stop, call @cto/@ciso.
-- Before apply: run once and keep the "INFO: ACL" row (pre-state for the rollback); expected false then on the
-- three "no EXECUTE" rows.
WITH f AS (
  SELECT p.oid, p.proowner, p.proacl, p.prosecdef
    FROM pg_proc p WHERE p.oid = to_regprocedure('public.send_all_weekly_matches_emails()')
),
one AS (
  SELECT p.oid FROM pg_proc p WHERE p.oid = to_regprocedure('public.send_weekly_matches_email(text)')
),
checks(check_name, ok, detail) AS (
  SELECT 'send_all_weekly_matches_emails() exists', count(*) = 1, '' FROM f
  UNION ALL
  SELECT 'send_all is SECURITY INVOKER (unchanged)', bool_and(NOT prosecdef), '' FROM f
  UNION ALL
  SELECT 'anon has no EXECUTE on send_all', bool_and(NOT has_function_privilege('anon', oid, 'EXECUTE')), '' FROM f
  UNION ALL
  SELECT 'authenticated has no EXECUTE on send_all', bool_and(NOT has_function_privilege('authenticated', oid, 'EXECUTE')), '' FROM f
  UNION ALL
  SELECT 'PUBLIC has no EXECUTE on send_all',
         bool_and(NOT EXISTS (SELECT 1 FROM aclexplode(coalesce(f.proacl, acldefault('f', f.proowner))) a
                               WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')), '' FROM f
  UNION ALL
  SELECT 'owner keeps EXECUTE on send_all', bool_and(has_function_privilege(f.proowner, oid, 'EXECUTE')), '' FROM f
  UNION ALL
  SELECT 'send_weekly_matches_email(text): anon/authenticated still no EXECUTE, service_role yes (22.09, untouched)',
         bool_and(NOT has_function_privilege('anon', oid, 'EXECUTE')
                  AND NOT has_function_privilege('authenticated', oid, 'EXECUTE')
                  AND has_function_privilege('service_role', oid, 'EXECUTE')), '' FROM one
)
SELECT check_name, coalesce(ok, false) AS ok, detail FROM checks
UNION ALL
SELECT 'INFO: ACL', true,
       'service_role exec=' || coalesce((SELECT has_function_privilege('service_role', oid, 'EXECUTE')::text FROM f), '?')
       || ' acl=' || coalesce((SELECT coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text COLLATE "C") FROM unnest(proacl) x),
                                               'NULL (default)') FROM f), 'function missing')
UNION ALL
SELECT '== ALL OK ==', bool_and(coalesce(ok, false)), count(*) FILTER (WHERE NOT coalesce(ok, false)) || ' failed'
  FROM checks;
