-- ============================================================
-- CRITICAL #1 FIX: profiles.email_verification_token column-level REVOKE
-- ============================================================
-- Date: 2026-05-13
-- Auditor: @ciso (Bruce Schneier mode)
-- CEO decision: 2026-05-13 07:35 EDT — approved evening sprint
--
-- THREAT MODEL:
--   Pre-fix: anon role has SELECT/INSERT/UPDATE on every column of public.profiles
--   (verified in state_pre_security_2026-05-13_Q2_profiles_column_grants.csv).
--   Combined with permissive RLS USING(true) on profiles SELECT policy and
--   the Supabase anon API key being publicly distributed (Gradio JS bundles, etc.),
--   any attacker can call:
--     GET /rest/v1/profiles?select=email_verification_token,email&email_verified=eq.false
--   …and harvest live magic-link verification tokens → single API call account takeover.
--
-- FIX:
--   Remove anon + authenticated grants on email_verification_token column.
--   service_role retains all privileges (used by MCP service-side ops where needed).
--   Postgres-internal triggers (send_verification_email, send_welcome_email_after_verification)
--   run as postgres/security definer — unaffected by column-level role grants.
--
-- VERIFIED ZERO IMPACT ON MCP CODE:
--   grep -rn "email_verification_token" thebackroom/*.py → 0 matches.
--   .select("*") calls return all permitted columns; revoked column is silently excluded
--   (PostgREST column-grant semantics).
--
-- ROLLBACK (if needed):
--   GRANT SELECT, INSERT, UPDATE, REFERENCES (email_verification_token)
--     ON public.profiles TO anon, authenticated;
-- ============================================================

BEGIN;

-- Revoke SELECT (the actual attack vector)
REVOKE SELECT (email_verification_token) ON public.profiles FROM anon;
REVOKE SELECT (email_verification_token) ON public.profiles FROM authenticated;

-- Revoke INSERT/UPDATE/REFERENCES (defense-in-depth — anon should never write tokens)
REVOKE INSERT (email_verification_token) ON public.profiles FROM anon;
REVOKE INSERT (email_verification_token) ON public.profiles FROM authenticated;
REVOKE UPDATE (email_verification_token) ON public.profiles FROM anon;
REVOKE UPDATE (email_verification_token) ON public.profiles FROM authenticated;
REVOKE REFERENCES (email_verification_token) ON public.profiles FROM anon;
REVOKE REFERENCES (email_verification_token) ON public.profiles FROM authenticated;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- Run after COMMIT — expect ZERO rows (no anon/authenticated grants on column):
--
--   SELECT grantee, privilege_type
--   FROM information_schema.column_privileges
--   WHERE table_schema = 'public'
--     AND table_name = 'profiles'
--     AND column_name = 'email_verification_token'
--     AND grantee IN ('anon', 'authenticated')
--   ORDER BY grantee, privilege_type;
--
-- Expected attack-vector test (should fail with permission error):
--   curl 'https://[project].supabase.co/rest/v1/profiles?select=email_verification_token,email' \
--     -H "apikey: [anon_key]"
--   → 401/403 or column hidden from response
-- ============================================================
