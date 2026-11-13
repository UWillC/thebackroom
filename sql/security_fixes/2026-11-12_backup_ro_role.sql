-- ============================================================
-- NOT APPLIED. Needs @ciso review + user "pchaj" (user 2026-11-12: "backup_ro ok po przeglądzie").
-- Read-only role `backup_ro` for the weekly pg_dump (CEO repo scripts/backup-ai-first.sh, step 7), replacing the
-- `postgres` URI in the vault (@ciso 2026-10-29 q.2, 2026-11-02 finding 5: the postgres credential can also run
-- tb_delete_account and any DDL). Variant A, least privilege: explicit grants on exactly the two schemas the dump
-- reads (public, auth), nothing in vault/storage/realtime/graphql/extensions.
--
-- What the dump needs, proven locally (sql/tests/run_backup_ro_local.sh, postgres:17):
--   * SELECT on EVERY table it dumps the definition of, also the 8 token/session tables whose DATA is excluded
--     (--exclude-table-data). pg_dump takes LOCK TABLE ... IN ACCESS SHARE MODE on every such table first, and
--     that lock needs SELECT: without it the run stops with "permission denied for table sessions" at the LOCK.
--     Dropping the 8 tables from the dump entirely (-T) would lose their schema and break FKs that point at them
--     (e.g. auth.saml_relay_states -> auth.flow_state), so SELECT stays and the data exclusion + the
--     `pg_restore -l` ALARM in the script remain the control. Residual risk: a stolen backup_ro URI can read live
--     refresh tokens/sessions (as the postgres URI can today) - written into the @cto report for @ciso.
--   * BYPASSRLS: pg_dump sets row_security = off and aborts with "query would be affected by row-level security
--     policy" on any RLS table it cannot read in full (all public tables and auth.users have RLS). A partial copy
--     is worse than none, so BYPASSRLS is required for a complete backup.
--   * SELECT (not USAGE) on sequences: pg_dump reads last_value. USAGE would allow nextval(), i.e. a write.
--   * No CREATE anywhere, no membership in any role (no pg_read_all_data: that would also open vault/storage).
--   * default_transaction_read_only = on: a second layer only (a client can SET it off; privileges are the barrier).
--   * CONNECTION LIMIT 3: the script needs 2 sequential connections (pg_dump, row counts).
-- Password: NOT in this file. Set by the user afterwards with psql `\password backup_ro` (sends a SCRAM hash,
--   never the plain password, nothing in SQL editor history or server logs). Until then the role cannot log in.
-- Default privileges: only for tables/sequences that `postgres` creates in `public` (all our migrations). New
--   tables in `auth` are created by supabase_auth_admin (GoTrue upgrades); we cannot set defaults for that role,
--   so after such an upgrade the dump fails loudly at LOCK (script: DB-ALARM, pg_dump error) - fix: re-run the two
--   `GRANT ... IN SCHEMA auth` lines below. Fails closed, never a silent partial dump.
-- Guard: runs as postgres only; aborts if the role already exists; aborts if postgres lacks GRANT OPTION on any
--   relation/sequence in public or auth (GRANT would only WARN there and leave a silent gap). In that case use
--   2026-11-12_backup_ro_role_fallback_pg_read_all_data.sql (@ciso 29.10 variant), after @ciso says which.
-- PRECHECK (read-only MCP, before "pchaj"): 2026-11-12_backup_ro_precheck.sql -> which variant applies.
-- APPLY: supabase-write apply_migration, name backup_ro_role_2026_11_12, this file unchanged (own BEGIN/COMMIT).
-- VERIFY: 2026-11-12_backup_ro_verify_after_apply.sql (read-only), `== ALL OK ==` must be true.
-- ROLLBACK: 2026-11-12_backup_ro_rollback.sql (drops the role and its grants/default privileges; both variants).
-- TESTED LOCALLY: sql/tests/run_backup_ro_local.sh (postgres:17, non-superuser "postgres" like on Supabase).
-- ============================================================

BEGIN;

DO $guard$
DECLARE n int; sample text;
BEGIN
  IF current_user <> 'postgres' THEN
    RAISE EXCEPTION 'backup_ro: run as postgres (default privileges are set FOR ROLE postgres), not as %', current_user;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backup_ro') THEN
    RAISE EXCEPTION 'backup_ro: role already exists, nothing changed (rollback file first if you want to recreate it)';
  END IF;
  SELECT count(*), string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY n.nspname, c.relname)
    INTO n, sample
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('public', 'auth') AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
     AND NOT has_table_privilege(current_user, c.oid, 'SELECT WITH GRANT OPTION');
  IF n > 0 THEN
    RAISE EXCEPTION 'backup_ro: postgres has no GRANT OPTION on % relation(s) in public/auth (%); nothing changed. Use the fallback file (pg_read_all_data) after @ciso review.', n, left(sample, 400);
  END IF;
  IF NOT (has_schema_privilege(current_user, 'public', 'USAGE WITH GRANT OPTION')
          AND has_schema_privilege(current_user, 'auth', 'USAGE WITH GRANT OPTION')) THEN
    RAISE EXCEPTION 'backup_ro: postgres cannot grant USAGE on schema public/auth; nothing changed. Use the fallback file.';
  END IF;
END
$guard$;

CREATE ROLE backup_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS INHERIT
  CONNECTION LIMIT 3 PASSWORD NULL;
COMMENT ON ROLE backup_ro IS 'Read-only weekly pg_dump (CEO scripts/backup-ai-first.sh). Migration 2026-11-12_backup_ro_role.sql';
ALTER ROLE backup_ro SET default_transaction_read_only = on;

GRANT USAGE ON SCHEMA public, auth TO backup_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_ro;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA auth TO backup_ro;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA auth TO backup_ro;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON TABLES TO backup_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT ON SEQUENCES TO backup_ro;

-- post-check inside the transaction: any gap = nothing stays
DO $post$
DECLARE n int; sample text;
BEGIN
  SELECT count(*), string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    INTO n, sample
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname IN ('public', 'auth') AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
     AND NOT has_table_privilege('backup_ro', c.oid, 'SELECT');
  IF n > 0 THEN RAISE EXCEPTION 'backup_ro post-check: no SELECT on % relation(s): %', n, left(sample, 400); END IF;
  IF EXISTS (SELECT 1 FROM pg_auth_members WHERE member = 'backup_ro'::regrole) THEN
    RAISE EXCEPTION 'backup_ro post-check: role is a member of another role';
  END IF;
  IF has_schema_privilege('backup_ro', 'public', 'CREATE') OR has_schema_privilege('backup_ro', 'auth', 'CREATE') THEN
    RAISE EXCEPTION 'backup_ro post-check: CREATE on schema public/auth';
  END IF;
END
$post$;

COMMIT;
