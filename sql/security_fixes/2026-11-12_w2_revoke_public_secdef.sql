-- ============================================================
-- NOT APPLIED. Needs user "pchaj" (separate from the backup_ro role migration). @ciso condition W2,
-- CEO repo raporty/zespol/2026-11-12_ciso-backup-ro_review.md, section "Precheck produkcji 12.11".
-- Closes the PUBLIC path to 3 writing SECURITY DEFINER functions found by the production precheck 2026-11-12:
--   public.verify_email_token(text, text)                                   marks an e-mail as verified
--   public.wc2026_reset(text)                                               writes World Cup tables
--   public.wc2026_save(text, integer, integer, integer, integer, integer, text, text)   writes World Cup tables
-- Why: any role that logs in directly (backup_ro after its password step) inherits EXECUTE through PUBLIC and can
-- set request.jwt.claims itself; the function then writes with its owner's rights.
-- What changes: REVOKE ALL ... FROM PUBLIC + explicit GRANT EXECUTE to anon, authenticated, service_role (pattern
-- W44 2026-10-26 and 2026-10-30). Callers in code (checked 2026-11-12): verify_email_token = anon (docs/app/app.js,
-- MCP verify_email via the anon client); wc2026_save/wc2026_reset = no caller (Edge Function wc2026 writes the
-- tables directly over SUPABASE_DB_URL), grants kept as @ciso asked, see the CTO report for the recommendation.
-- Function bodies and owners are not touched. The owner keeps EXECUTE.
-- Guard: run as postgres, the 3 exact signatures exist, are SECURITY DEFINER, PUBLIC can still execute at least one
-- (re-apply aborts). Post-check in the same transaction: PUBLIC has no EXECUTE on any of the 3, anon/authenticated/
-- service_role do. Any failure = ROLLBACK, nothing changed.
-- Independent of backup_ro_role_fallback_2026_11_12 (either order). Must be DONE before the backup_ro password step.
-- BEFORE APPLY (read-only MCP): run the verify file once and keep its "INFO: ACL" row = pre-state for the rollback.
-- APPLY: supabase-write apply_migration, name revoke_public_secdef_w2_2026_11_12, this file unchanged.
-- VERIFY: 2026-11-12_w2_revoke_public_secdef_verify_after_apply.sql (read-only), all rows true.
-- ROLLBACK: 2026-11-12_w2_revoke_public_secdef_rollback.sql.
-- TESTED LOCALLY: sql/tests/run_w2_revoke_local.sh.
-- ============================================================

BEGIN;

DO $guard$
DECLARE
  f text;
  p regprocedure;
  public_exec int := 0;
BEGIN
  IF current_user <> 'postgres' THEN RAISE EXCEPTION 'W2: run as postgres, not as %', current_user; END IF;
  FOREACH f IN ARRAY ARRAY[
    'public.verify_email_token(text,text)',
    'public.wc2026_reset(text)',
    'public.wc2026_save(text,integer,integer,integer,integer,integer,text,text)'] LOOP
    p := to_regprocedure(f);
    IF p IS NULL THEN RAISE EXCEPTION 'W2: function % not found (signature changed?), nothing changed', f; END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = p) THEN
      RAISE EXCEPTION 'W2: % is not SECURITY DEFINER any more, review before applying', f;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                WHERE pr.oid = p AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      public_exec := public_exec + 1;
    END IF;
  END LOOP;
  IF public_exec = 0 THEN RAISE EXCEPTION 'W2: PUBLIC already has no EXECUTE on the 3 functions, nothing to do'; END IF;
END
$guard$;

REVOKE ALL ON FUNCTION public.verify_email_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.wc2026_reset(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.wc2026_save(text, integer, integer, integer, integer, integer, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.verify_email_token(text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.wc2026_reset(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.wc2026_save(text, integer, integer, integer, integer, integer, text, text)
  TO anon, authenticated, service_role;

DO $post$
DECLARE
  f text;
  p regprocedure;
  r text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.verify_email_token(text,text)',
    'public.wc2026_reset(text)',
    'public.wc2026_save(text,integer,integer,integer,integer,integer,text,text)'] LOOP
    p := to_regprocedure(f);
    -- A REVOKE by a non-owner only warns ("no privileges could be revoked"); this check turns that into an abort.
    IF EXISTS (SELECT 1 FROM pg_proc pr, aclexplode(coalesce(pr.proacl, acldefault('f', pr.proowner))) a
                WHERE pr.oid = p AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      RAISE EXCEPTION 'W2 post-check: PUBLIC still has EXECUTE on % (owner is not postgres?), rolled back', f;
    END IF;
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
      IF NOT has_function_privilege(r, p, 'EXECUTE') THEN
        RAISE EXCEPTION 'W2 post-check: % lost EXECUTE on %, rolled back', r, f;
      END IF;
    END LOOP;
  END LOOP;
END
$post$;

COMMIT;
