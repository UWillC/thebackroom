-- ============================================================
-- ROLLBACK of 2026-11-12_w2_revoke_public_secdef.sql. Gives EXECUTE back to PUBLIC on the 3 functions.
-- Effective privileges = pre-state (PUBLIC + owner + anon/authenticated/service_role can execute).
-- The explicit GRANTs to anon/authenticated/service_role stay: on production verify_email_token already had them
-- before W2 (live ACL 2026-11-05), and with PUBLIC back they change nothing for any role. Compare with the
-- "INFO: ACL" row saved before apply if an exact proacl match is needed.
-- WARNING: re-opens condition W2. Do not run while backup_ro has a password: first remove BACKROOM_DB_RO_URL from
-- the vault and run 2026-11-12_backup_ro_rollback.sql (or ALTER ROLE backup_ro PASSWORD NULL).
-- Guard: run as postgres, the 3 functions exist, PUBLIC has no EXECUTE on any of them (W2 applied).
-- APPLY: supabase-write apply_migration, name revoke_public_secdef_w2_rollback_2026_11_12, this file unchanged.
-- TESTED LOCALLY: sql/tests/run_w2_revoke_local.sh.
-- ============================================================

BEGIN;

DO $guard$
DECLARE
  f text;
  p regprocedure;
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'W2 rollback: run as postgres, not as %', current_user; END IF;
  FOREACH f IN ARRAY ARRAY[
    'public.verify_email_token(text,text)',
    'public.wc2026_reset(text)',
    'public.wc2026_save(text,integer,integer,integer,integer,integer,text,text)'] LOOP
    p := to_regprocedure(f);
    IF p IS NULL THEN RAISE EXCEPTION 'W2 rollback: function % not found, nothing changed', f; END IF;
    IF EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                WHERE pr.oid = p AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      RAISE EXCEPTION 'W2 rollback: PUBLIC already has EXECUTE on % (W2 not applied?), nothing changed', f;
    END IF;
  END LOOP;
END
$guard$;

GRANT EXECUTE ON FUNCTION public.verify_email_token(text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.wc2026_reset(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.wc2026_save(text, integer, integer, integer, integer, integer, text, text) TO PUBLIC;

DO $post$
DECLARE
  f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.verify_email_token(text,text)',
    'public.wc2026_reset(text)',
    'public.wc2026_save(text,integer,integer,integer,integer,integer,text,text)'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                    WHERE pr.oid = to_regprocedure(f) AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      RAISE EXCEPTION 'W2 rollback post-check: PUBLIC has no EXECUTE on %, rolled back', f;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
