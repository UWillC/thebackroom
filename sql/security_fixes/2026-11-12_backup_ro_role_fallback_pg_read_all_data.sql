-- ============================================================
-- NOT APPLIED. FALLBACK ONLY: use instead of 2026-11-12_backup_ro_role.sql when that file's guard (or the precheck
-- 2026-11-12_backup_ro_precheck.sql) shows postgres has no GRANT OPTION on tables in auth/public, and only after
-- @ciso says so. This is the variant @ciso confirmed on 2026-10-29 (postgres holds pg_read_all_data WITH ADMIN
-- OPTION, CREATEROLE, BYPASSRLS; Supabase's own supabase_read_only_user has the same shape).
-- Difference to variant A (why it is the fallback, not the default): pg_read_all_data reads EVERY schema, also
-- vault (encrypted secrets; whether vault.decrypted_secrets is readable depends on EXECUTE of the decrypt
-- functions, check with the verify file) and storage, and covers future tables in auth automatically.
-- Still: no write, no DDL, no tb_delete_account (EXECUTE revoked from PUBLIC 2026-10-30).
-- Same rules as variant A: BYPASSRLS required by pg_dump, password set afterwards with psql \password.
-- APPLY: supabase-write apply_migration, name backup_ro_role_fallback_2026_11_12, this file unchanged.
-- VERIFY: 2026-11-12_backup_ro_verify_after_apply.sql, rows tagged [A] are expected false for this variant
--   (membership, vault); every other row must be true.
-- ROLLBACK: 2026-11-12_backup_ro_rollback.sql.
-- TESTED LOCALLY: sql/tests/run_backup_ro_local.sh.
-- ============================================================

BEGIN;

DO $guard$
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'backup_ro: run as postgres, not as %', current_user; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backup_ro') THEN
    RAISE EXCEPTION 'backup_ro: role already exists, nothing changed';
  END IF;
END
$guard$;

CREATE ROLE backup_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS INHERIT
  CONNECTION LIMIT 3 PASSWORD NULL;
COMMENT ON ROLE backup_ro IS 'Read-only weekly pg_dump (CEO scripts/backup-ai-first.sh). Fallback pg_read_all_data 2026-11-12';
ALTER ROLE backup_ro SET default_transaction_read_only = on;
GRANT pg_read_all_data TO backup_ro;

DO $post$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
   WHERE s.nspname IN ('public', 'auth') AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
     AND NOT has_table_privilege('backup_ro', c.oid, 'SELECT');
  IF n > 0 THEN RAISE EXCEPTION 'backup_ro post-check: no SELECT on % relation(s)', n; END IF;
  IF has_schema_privilege('backup_ro', 'public', 'CREATE') OR has_schema_privilege('backup_ro', 'auth', 'CREATE') THEN
    RAISE EXCEPTION 'backup_ro post-check: CREATE on schema public/auth';
  END IF;
END
$post$;

COMMIT;
