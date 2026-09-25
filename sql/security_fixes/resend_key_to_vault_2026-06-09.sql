-- ============================================================
-- APPLIED 2026-06-09 (@cto, supabase-write apply_migration `resend_key_to_vault_2026_06_09`)
-- INCIDENT: hardcoded Resend API key (re_x6tEDMHR…, "Onboarding") in 10 DB functions
--           + 7 thebackroom-sql/*.sql files (OneDrive-synced plaintext).
-- Discovered during RLS audit chain @ciso->@cto, 2026-06-09.
--
-- REMEDIATION (this migration):
--   1. New key generated in Resend by user, stored in Supabase Vault as `resend_api_key`.
--   2. Single SECURITY DEFINER helper public.get_resend_key() reads vault.decrypted_secrets.
--      EXECUTE revoked from PUBLIC/anon/authenticated (no anon can pull the key via RPC).
--   3. All 10 email functions: literal 'Bearer re_x6tEDMHR…' -> 'Bearer ' || public.get_resend_key(),
--      and switched to SECURITY DEFINER + pinned search_path (so the helper call runs as postgres,
--      and anon callers don't need EXECUTE on the helper).
--
-- POST-APPLY VERIFICATION (all passed):
--   - 0 functions still contain the literal key.
--   - get_resend_key + 10 email fns: secdef=true, uses_helper=true.
--   - get_resend_key() returns len=36, prefix 're_' (vault read works end-to-end).
--   - 7 thebackroom-sql/*.sql files scrubbed (key -> helper ref / dead placeholder).
--
-- FOLLOW-UP (user, in Resend dashboard):
--   - REVOKE old key re_x6tEDMHR… ("Onboarding") — prod now uses the new vaulted key,
--     so revoke is zero-downtime.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_resend_key()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$ SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'resend_api_key' $fn$;

REVOKE ALL ON FUNCTION public.get_resend_key() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_resend_key() TO postgres, service_role;

DO $mig$
DECLARE r record; new_def text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname <> 'get_resend_key'
      AND pg_get_functiondef(p.oid) LIKE '%re_x6tEDMHR%'
  LOOP
    -- NOTE: literal target redacted in this record (key revoked 2026-06-09).
    -- Original target was the hardcoded 'Bearer re_x6tEDMHR…' string.
    -- Re-running is a no-op now: no function still contains the literal.
    new_def := replace(
      pg_get_functiondef(r.oid),
      $k$'Bearer re_x6tEDMHR…REDACTED_REVOKED'$k$,
      $r$'Bearer ' || public.get_resend_key()$r$
    );
    EXECUTE new_def;
    EXECUTE format('ALTER FUNCTION public.%I(%s) SECURITY DEFINER', r.proname, r.args);
    EXECUTE format($f$ALTER FUNCTION public.%I(%s) SET search_path = 'public','pg_temp'$f$, r.proname, r.args);
  END LOOP;
END $mig$;
