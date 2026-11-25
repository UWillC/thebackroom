-- ============================================================
-- NOT APPLIED — czeka na @ciso GO (waiting for @ciso GO), then user "pchaj". Do not apply before both.
-- Takes EXECUTE on public.send_all_weekly_matches_emails() away from anon, authenticated and PUBLIC.
-- Why: the only caller was the GitHub Actions workflow weekly-matches-email.yml (anon key over PostgREST), removed
-- 2026-11-25 (user chose variant A, CEO repo raporty/zespol/2026-11-25_cto-backroom-weekly-matches_raport.md).
-- The MCP tool's dead "send to everyone" branch was removed in the same PR. No other caller in code or SQL
-- (checked 2026-11-25: grep over the repo; pg_cron is not used, the cron.schedule in weekly_matches_email.sql is
-- commented out). The function is SECURITY INVOKER, so today anon only gets 42501, but a client role should not be
-- able to start a mail-to-everyone loop at all if table grants ever change.
-- What changes: REVOKE EXECUTE ... FROM anon, authenticated, PUBLIC. Nothing else. Function body, owner,
-- send_weekly_matches_email(text) and every other function stay as they are. The owner keeps EXECUTE.
-- service_role keeps EXECUTE only if it has its own explicit grant (Supabase default privileges); nothing calls
-- the function with service_role either, so this is not asserted.
-- Expected pre-state (Supabase default privileges on functions, like verify_email_token's live ACL of 2026-11-05):
--   {=X/postgres, postgres=X/postgres, anon=X/postgres, authenticated=X/postgres, service_role=X/postgres}
--   [VERIFY: read the "INFO: ACL" row of the verify file once BEFORE apply and keep it as the rollback pre-state]
-- Guard: run as postgres, the exact signature exists, at least one of anon/authenticated/PUBLIC can still execute
-- it (re-apply aborts). Post-check in the same transaction: none of the three can. Any failure = ROLLBACK.
-- BEFORE APPLY (read-only MCP): run the verify file once, keep its "INFO: ACL" row.
-- APPLY: supabase-write apply_migration, name revoke_send_all_weekly_2026_11_25, this file unchanged.
-- VERIFY: 2026-11-25_revoke_send_all_weekly_verify_after_apply.sql (read-only), all rows true.
-- ROLLBACK: 2026-11-25_revoke_send_all_weekly_rollback.sql.
-- TESTED LOCALLY: sql/tests/run_revoke_send_all_local.sh (postgres:17, --network none).
-- ============================================================

BEGIN;

DO $guard$
DECLARE
  p regprocedure := to_regprocedure('public.send_all_weekly_matches_emails()');
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'revoke_send_all: run as postgres, not as %', current_user; END IF;
  IF p IS NULL THEN RAISE EXCEPTION 'revoke_send_all: public.send_all_weekly_matches_emails() not found, nothing changed'; END IF;
  IF NOT (has_function_privilege('anon', p, 'EXECUTE') OR has_function_privilege('authenticated', p, 'EXECUTE')
          OR EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                      WHERE pr.oid = p AND a.grantee = 0 AND a.privilege_type = 'EXECUTE')) THEN
    RAISE EXCEPTION 'revoke_send_all: anon, authenticated and PUBLIC already have no EXECUTE, nothing to do';
  END IF;
END
$guard$;

REVOKE EXECUTE ON FUNCTION public.send_all_weekly_matches_emails() FROM anon, authenticated, public;

DO $post$
DECLARE
  p regprocedure := to_regprocedure('public.send_all_weekly_matches_emails()');
BEGIN
  -- A REVOKE by a non-owner only warns ("no privileges could be revoked"); this check turns that into an abort.
  IF has_function_privilege('anon', p, 'EXECUTE') OR has_function_privilege('authenticated', p, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                 WHERE pr.oid = p AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
    RAISE EXCEPTION 'revoke_send_all post-check: a client role or PUBLIC can still execute (owner is not postgres?), rolled back';
  END IF;
  IF NOT has_function_privilege('postgres', p, 'EXECUTE') THEN
    RAISE EXCEPTION 'revoke_send_all post-check: owner lost EXECUTE, rolled back';
  END IF;
END
$post$;

COMMIT;
