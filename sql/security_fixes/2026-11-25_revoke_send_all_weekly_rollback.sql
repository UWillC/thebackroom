-- ============================================================
-- ROLLBACK of 2026-11-25_revoke_send_all_weekly.sql. Gives EXECUTE back to anon, authenticated and PUBLIC.
-- Effective privileges = expected pre-state (Supabase default: PUBLIC + owner + anon/authenticated/service_role).
-- If the "INFO: ACL" row saved before apply differs (e.g. acl=NULL, or no explicit anon/authenticated), match it:
-- acl=NULL before -> GRANT ... TO public only gives the same effective rights; compare with that row.
-- Only needed if the weekly mail is brought back in its old form, which the 25.11 diagnosis advises against
-- (variant B = server-side job, not the anon key).
-- Guard: run as postgres, the function exists, none of anon/authenticated/PUBLIC can execute it (revoke applied).
-- APPLY: supabase-write apply_migration, name revoke_send_all_weekly_rollback_2026_11_25, this file unchanged.
-- TESTED LOCALLY: sql/tests/run_revoke_send_all_local.sh.
-- ============================================================

BEGIN;

DO $guard$
DECLARE
  p regprocedure := to_regprocedure('public.send_all_weekly_matches_emails()');
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'revoke_send_all rollback: run as postgres, not as %', current_user; END IF;
  IF p IS NULL THEN RAISE EXCEPTION 'revoke_send_all rollback: function not found, nothing changed'; END IF;
  IF has_function_privilege('anon', p, 'EXECUTE') OR has_function_privilege('authenticated', p, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                 WHERE pr.oid = p AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'revoke_send_all rollback: a client role or PUBLIC can already execute (revoke not applied?), nothing changed';
  END IF;
END
$guard$;

GRANT EXECUTE ON FUNCTION public.send_all_weekly_matches_emails() TO public, anon, authenticated;

COMMIT;
