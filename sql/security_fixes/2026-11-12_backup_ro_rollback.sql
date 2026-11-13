-- ============================================================
-- ROLLBACK of 2026-11-12_backup_ro_role.sql (or its fallback variant). Removes role backup_ro with every grant
-- and default privilege it received. Touches nothing else.
-- Before running: switch the CEO script back (restore its backup copy) or accept that the weekly dump stops with
-- DB-ALARM / BRAK_SEKRETU until a new role exists; remove BACKROOM_DB_RO_URL from the vault.
-- Open sessions of backup_ro are terminated first (a running pg_dump fails; rerun later).
-- APPLY: supabase-write apply_migration, name backup_ro_rollback_2026_11_12, this file unchanged. As postgres.
-- ============================================================

BEGIN;

DO $guard$
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'backup_ro rollback: run as postgres, not as %', current_user; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backup_ro') THEN
    RAISE EXCEPTION 'backup_ro rollback: role does not exist, nothing to do';
  END IF;
END
$guard$;

DO $term$
BEGIN
  PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'backup_ro';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING 'backup_ro rollback: cannot terminate its sessions (no pg_signal_backend); DROP ROLE still runs';
END
$term$;
-- Explicit revokes, not DROP OWNED BY: since PG16 the creator (postgres) only holds ADMIN on backup_ro, without its
-- privileges, and DROP OWNED BY is refused ("Only roles with privileges of role backup_ro may drop objects owned by it",
-- reproduced in sql/tests/run_backup_ro_local.sh). Any grant left over makes DROP ROLE fail = nothing changes (loud).
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM backup_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM backup_ro;
REVOKE ALL ON ALL TABLES IN SCHEMA public, auth FROM backup_ro;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public, auth FROM backup_ro;
REVOKE ALL ON SCHEMA public, auth FROM backup_ro;
DO $fb$
BEGIN   -- fallback variant only; skip the WARNING when there is no membership
  IF EXISTS (SELECT 1 FROM pg_auth_members WHERE roleid = 'pg_read_all_data'::regrole AND member = 'backup_ro'::regrole) THEN
    REVOKE pg_read_all_data FROM backup_ro;
  END IF;
END
$fb$;
DROP ROLE backup_ro;

DO $post$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'backup_ro') THEN RAISE EXCEPTION 'rollback post-check: role still there'; END IF;
  IF EXISTS (SELECT 1 FROM pg_default_acl WHERE array_to_string(defaclacl, ',') LIKE '%backup_ro=%') THEN
    RAISE EXCEPTION 'rollback post-check: default privileges for backup_ro left';
  END IF;
END
$post$;

COMMIT;
