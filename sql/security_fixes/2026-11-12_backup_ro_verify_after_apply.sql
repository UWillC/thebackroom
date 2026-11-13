-- READ-ONLY verification after 2026-11-12_backup_ro_role.sql. Safe with the read-only MCP.
-- Expected: every row ok = true. Any false = stop, call @cto/@ciso. If the role does not exist the query stops with
-- ERROR role "backup_ro" does not exist (has_*_privilege needs the role): that counts as a fail too.
-- Fallback variant (pg_read_all_data): rows tagged [A] are expected false, all others true.
-- Can be re-run any time (e.g. after a Supabase auth upgrade: row "SELECT on every relation" false = re-run the two
-- GRANT ... IN SCHEMA auth lines of the migration, otherwise the weekly dump stops at LOCK with DB-ALARM).
WITH r AS (SELECT * FROM pg_roles WHERE rolname = 'backup_ro'),
rel AS (
  SELECT n.nspname, c.relname, c.relkind, c.oid
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('public', 'auth') AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
),
checks(check_name, ok, detail) AS (
  SELECT 'role exists', count(*) = 1, count(*)::text FROM r
  UNION ALL
  SELECT 'login, no superuser/createdb/createrole/replication',
         coalesce(bool_and(rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication), false),
         coalesce(string_agg(format('login=%s super=%s createdb=%s createrole=%s repl=%s', rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication), ''), 'missing') FROM r
  UNION ALL
  SELECT 'BYPASSRLS (pg_dump needs it)', coalesce(bool_and(rolbypassrls), false), coalesce(string_agg(rolbypassrls::text, ''), 'missing') FROM r
  UNION ALL
  SELECT 'connection limit 3', coalesce(bool_and(rolconnlimit = 3), false), coalesce(string_agg(rolconnlimit::text, ''), 'missing') FROM r
  UNION ALL
  SELECT 'default_transaction_read_only=on', coalesce(bool_or('default_transaction_read_only=on' = ANY (s.setconfig)), false),
         coalesce(string_agg(array_to_string(s.setconfig, ','), ';'), 'none')
    FROM pg_db_role_setting s WHERE s.setrole = (SELECT oid FROM r)
  UNION ALL
  SELECT '[A] member of no role (no pg_read_all_data)', count(*) = 0,
         coalesce(string_agg(m.roleid::regrole::text, ','), '') FROM pg_auth_members m WHERE m.member = (SELECT oid FROM r)
  UNION ALL
  SELECT 'member of nothing except pg_read_all_data', count(*) = 0,
         coalesce(string_agg(m.roleid::regrole::text, ','), '') FROM pg_auth_members m
   WHERE m.member = (SELECT oid FROM r) AND m.roleid <> 'pg_read_all_data'::regrole
  UNION ALL
  SELECT 'nobody can act as backup_ro (only the PG16+ automatic ADMIN grant to its creator, no INHERIT/SET)', count(*) = 0,
         coalesce(string_agg(m.member::regrole::text, ','), '') FROM pg_auth_members m
   WHERE m.roleid = (SELECT oid FROM r) AND (m.inherit_option OR m.set_option)
  UNION ALL
  SELECT 'SELECT on every relation in public/auth (dump needs it, incl. 8 token tables for LOCK)',
         count(*) FILTER (WHERE NOT has_table_privilege('backup_ro', oid, 'SELECT')) = 0 AND EXISTS (SELECT 1 FROM r),
         format('%s relations, missing: %s', count(*), left(coalesce(string_agg(nspname || '.' || relname, ', ')
                FILTER (WHERE NOT has_table_privilege('backup_ro', oid, 'SELECT')), ''), 300))
    FROM rel
  UNION ALL
  SELECT 'no write/DDL-ish privilege on any table in public/auth', count(*) = 0 AND EXISTS (SELECT 1 FROM r),
         left(coalesce(string_agg(nspname || '.' || relname, ', '), ''), 300) FROM rel
   WHERE EXISTS (SELECT 1 FROM r)
     AND CASE WHEN relkind <> 'S' THEN has_table_privilege('backup_ro', oid, 'INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN') ELSE false END
  UNION ALL
  SELECT 'sequences: no USAGE/UPDATE (nextval/setval)', count(*) = 0 AND EXISTS (SELECT 1 FROM r),
         left(coalesce(string_agg(nspname || '.' || relname, ', '), ''), 300) FROM rel
   WHERE EXISTS (SELECT 1 FROM r) AND CASE WHEN relkind = 'S' THEN has_sequence_privilege('backup_ro', oid, 'USAGE, UPDATE') ELSE false END
  UNION ALL
  SELECT 'no CREATE on schema public/auth', EXISTS (SELECT 1 FROM r)
         AND NOT has_schema_privilege('backup_ro', 'public', 'CREATE') AND NOT has_schema_privilege('backup_ro', 'auth', 'CREATE'), ''
  UNION ALL
  SELECT 'no CREATE on database', EXISTS (SELECT 1 FROM r) AND NOT has_database_privilege('backup_ro', current_database(), 'CREATE'), ''
  UNION ALL
  SELECT 'CONNECT on database', EXISTS (SELECT 1 FROM r) AND has_database_privilege('backup_ro', current_database(), 'CONNECT'), ''
  UNION ALL
  SELECT '[A] no SELECT on any relation outside public/auth (vault, storage, ...)', count(*) = 0 AND EXISTS (SELECT 1 FROM r),
         format('%s: %s', count(*), left(coalesce(string_agg(n.nspname || '.' || c.relname, ', '), ''), 300))
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE EXISTS (SELECT 1 FROM r) AND n.nspname NOT IN ('public', 'auth', 'pg_catalog', 'information_schema', 'pg_toast')
     AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_table_privilege('backup_ro', c.oid, 'SELECT')
     AND NOT EXISTS (SELECT 1 FROM aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                      WHERE a.grantee = 0 AND a.privilege_type = 'SELECT')   -- tables readable by PUBLIC anyway are not ours to fix
  UNION ALL
  SELECT 'tb_delete_account not executable', NOT EXISTS (SELECT 1 FROM r) OR NOT EXISTS (
           SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'tb_delete_account' AND has_function_privilege('backup_ro', p.oid, 'EXECUTE')), ''
  UNION ALL
  SELECT '[A] default privileges: new postgres tables+sequences in public readable', count(*) = 2,
         coalesce(string_agg(d.defaclobjtype::text || ':' || array_to_string(d.defaclacl, ','), ' '), 'none')
    FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace
   WHERE d.defaclrole = 'postgres'::regrole AND n.nspname = 'public' AND d.defaclobjtype IN ('r', 'S')
     AND array_to_string(d.defaclacl, ',') ~ '(^|,)backup_ro=r/'
  UNION ALL
  SELECT 'INFO: SECURITY DEFINER functions in public/auth executable by backup_ro (via PUBLIC)', true,
         format('%s: %s', count(*), left(coalesce(string_agg(format('%I.%I', n.nspname, p.proname), ', ' ORDER BY n.nspname, p.proname), ''), 600))
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('public', 'auth') AND p.prosecdef AND EXISTS (SELECT 1 FROM r)
     AND has_function_privilege('backup_ro', p.oid, 'EXECUTE')
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok) AND count(*) > 0, count(*) FILTER (WHERE NOT ok) || ' of ' || count(*) || ' failed' FROM checks;
