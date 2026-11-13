-- READ-ONLY precheck before 2026-11-12_backup_ro_role.sql. Safe with the read-only MCP (any role can evaluate
-- has_*_privilege for 'postgres'). Decides the variant before "pchaj":
--   row "variant A possible" = true  -> apply 2026-11-12_backup_ro_role.sql (explicit grants, least privilege)
--   row "variant A possible" = false -> @ciso picks: fallback file (pg_read_all_data) or stop
-- Also lists what @ciso needs for the residual-risk note: SECURITY DEFINER functions in public/auth that PUBLIC
-- may execute (backup_ro would inherit EXECUTE on them through PUBLIC; privileges, not the read-only setting,
-- are the barrier, and a client can SET default_transaction_read_only off).
WITH rel AS (
  SELECT n.nspname, c.relname, c.relkind,
         has_table_privilege('postgres', c.oid, 'SELECT WITH GRANT OPTION') AS can_grant
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('public', 'auth') AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
),
secdef AS (
  SELECT format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS f
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'auth') AND p.prosecdef
     AND EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
)
SELECT 'role backup_ro absent' AS check_name, NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backup_ro') AS ok, '' AS detail
UNION ALL
SELECT 'postgres can create it (CREATEROLE + BYPASSRLS)', rolcreaterole AND rolbypassrls, format('createrole=%s bypassrls=%s', rolcreaterole, rolbypassrls)
  FROM pg_roles WHERE rolname = 'postgres'
UNION ALL
SELECT 'variant A possible (GRANT OPTION on every relation in public/auth + schema USAGE)',
       bool_and(can_grant) AND has_schema_privilege('postgres', 'public', 'USAGE WITH GRANT OPTION')
                           AND has_schema_privilege('postgres', 'auth', 'USAGE WITH GRANT OPTION'),
       format('relations=%s without_grant_option=%s: %s', count(*), count(*) FILTER (WHERE NOT can_grant),
              left(coalesce(string_agg(nspname || '.' || relname, ', ') FILTER (WHERE NOT can_grant), ''), 300))
  FROM rel
UNION ALL
SELECT 'fallback possible (postgres has pg_read_all_data WITH ADMIN OPTION)',
       EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.roleid = 'pg_read_all_data'::regrole
                  AND m.member = 'postgres'::regrole AND m.admin_option), ''
UNION ALL
SELECT 'INFO: SECURITY DEFINER functions in public/auth executable by PUBLIC', true,
       format('%s: %s', count(*), left(coalesce(string_agg(f, ', ' ORDER BY f), ''), 600))
  FROM secdef;
