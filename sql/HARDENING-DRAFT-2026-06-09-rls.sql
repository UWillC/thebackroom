-- ============================================================================
-- HARDENING DRAFT — The Backroom RLS/grants   2026-06-09
-- Author: @ciso (audit)  ->  Executor: @cto on supabase-write, with user OK
-- Full analysis: projects/thebackroom/SECURITY-AUDIT-2026-06-09-rls.md
--
-- !!! DO NOT APPLY BLIND !!!
-- Connection model = app uses the ANON key as its primary identity, and
-- check_and_log_rate_limit() is SECURITY INVOKER. Several USING(true) policies
-- are LOAD-BEARING. A naive "flip 8 policies to false" = self-inflicted outage
-- (rate limiting writes as anon; search_logs insert as anon; self-profile read
-- of email as anon). Apply ONLY tier by tier, each behind its gate, with an
-- RLS smoke test as a real authenticated profile BEFORE dropping anything.
-- ============================================================================


-- ============================================================================
-- TIER A — RESOLVED 2026-06-09: column-revoke REJECTED, shipped hash-at-rest instead.
-- ============================================================================
-- GATE A tested empirically on live PostgREST with the anon key:
--   * Column restriction blocks the token for anon, BUT `select=*` then returns
--     42501 permission denied (BREAKS). App uses select("*") everywhere -> not viable.
--   * Bonus finding: REVOKE SELECT(col) is a NO-OP while the role holds table-level
--     SELECT. The 2026-05-13 fix would have been ineffective regardless.
--   => P0 (token) closed via HASH-AT-REST instead (no app change, no select=* break):
--      see security_fixes/email_token_hash_at_rest_2026-06-09.sql (APPLIED + e2e verified).
--   Token column now stores SHA-256(token); anon reading it gets a useless hash.
--   RESIDUAL (separate, lower sev): email / auth_user_id / preferences still readable
--   by anon via select=*. Closing those needs the app to move self-reads to an
--   authenticated session (TIER D) — column-revoke can't help while select(*) is used.
-- ============================================================================
-- ----- original BLOCKED analysis retained below for the record -----
-- GATE A RESULT: the app reads profiles via SELECT * over the ANON key in ~8
-- call sites -- utils/supabase.py:47 (load_profiles: ALL rows, ALL cols, NO
-- filter), core/search.py:150, core/profiles/quality.py:43, core/profiles/
-- crud.py:48 & 373, core/connections.py:312, app.py:25 (select=*). Plus
-- core/profiles/email.py:130 reads email_verification_sent_at via anon.
--
-- => Column-level REVOKE breaks every SELECT * (permission denied for column)
--    and the email.py status read. The token leaks because SELECT * pulls it
--    over the wire, NOT because code names the column. Column-revoke is
--    therefore NOT a safe pure-SQL fix. TIER A is effectively TIER D (app change).
--
-- CORRECT PATH (pick one, both are app-first):
--   (a) Refactor the ~8 anon SELECT * on profiles -> explicit safe-column lists,
--       THEN apply the column REVOKE below.
--   (b) Create a `profiles_public` VIEW (safe columns only), repoint discovery/
--       search/load_profiles at it; keep SELECT * for authenticated self-reads.
-- Until (a) or (b) ships, P0 token/PII exposure stands. Track as app work.
--
-- ----- ORIGINAL DRAFT BELOW (kept for reference; superseded — DO NOT RUN) -----
-- app.py:391 selects email,email_verified,notifications_enabled via anon.

-- Column-level: revoke broad SELECT, re-grant only non-sensitive columns.
REVOKE SELECT ON public.profiles FROM anon, authenticated;
GRANT  SELECT (
    id, name, role, industry, skills, offers, seeks, assistant_endpoint,
    created_at, updated_at, location, bio, tags, offer_free, offer_condition,
    preferred_contact, linkedin_url, quality_score, quality_checked_at,
    email, email_verified, notifications_enabled   -- kept: app.py:391 reads via anon
) ON public.profiles TO anon, authenticated;
-- EXCLUDED (no anon read path -> now unreachable by anon key):
--   email_verification_token  <-- P0: auth credential, stops token harvest
--   auth_user_id, preferences, quality_feedback, email_verification_sent_at
--
-- NOTE: email itself stays anon-readable (app constraint). Full P0-email close
-- = TIER D (app moves self-read to an authenticated session). Tracked separately.

-- Strip privileges no client should ever hold:
REVOKE TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public
    FROM anon, authenticated;


-- ============================================================================
-- TIER B — PAIRED (rate_limits)   [must do BOTH, in this order]
-- ============================================================================
-- check_and_log_rate_limit() is SECURITY INVOKER -> writes rate_limits AS anon,
-- relying on the ALL(true) policy. Step 1 makes it write as owner; ONLY THEN is
-- it safe to cut anon's direct table access (step 2/3). Doing 2/3 alone breaks
-- rate limiting; doing 1 alone leaves the attacker direct-table reset path open.
--
-- GATE B: confirm the function body only touches rate_limits (no side tables
-- that would then need definer too). Review pg_get_functiondef('check_and_log_rate_limit').

-- Step 1 — make the enforcer write as owner (pin search_path = secure secdef):
-- ALTER FUNCTION public.check_and_log_rate_limit(text,text,integer,integer)
--     SECURITY DEFINER SET search_path = 'public','pg_temp';

-- Step 2 — drop the wide-open table policy:
-- DROP POLICY "Allow all for rate_limits" ON public.rate_limits;

-- Step 3 — remove direct anon/authenticated table access (RPC still works via definer):
-- REVOKE ALL ON public.rate_limits FROM anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.check_and_log_rate_limit(text,text,integer,integer)
--     TO anon, authenticated;   -- ensure RPC still callable

-- (Left commented: apply after GATE B + a rate-limit smoke test.)


-- ============================================================================
-- TIER C — GATED (audit/stats/metrics/templates write-lock)
-- ============================================================================
-- No triggers populate these (verified: information_schema.triggers = empty for
-- these tables) and no anon insert path found in app code -> writes presumed
-- service_role. Lock writes to false, BUT confirm the writer first.
--
-- GATE C (per table): identify what writes it.
--   - If service_role only  -> safe to set policy to false (service bypasses RLS).
--   - If any anon/authenticated path exists -> DO NOT lock; scope instead.

-- room_audit_log: audit trails must be system-append-only (mirror audit_logs,
-- which is correctly sealed with INSERT check=false).
-- DROP POLICY room_audit_log_insert ON public.room_audit_log;
-- CREATE POLICY room_audit_log_insert ON public.room_audit_log
--     FOR INSERT TO public WITH CHECK (false);

-- profile_stats: writes service-side only.
-- DROP POLICY profile_stats_insert ON public.profile_stats;
-- CREATE POLICY profile_stats_insert ON public.profile_stats
--     FOR INSERT TO public WITH CHECK (false);
-- DROP POLICY profile_stats_update ON public.profile_stats;
-- CREATE POLICY profile_stats_update ON public.profile_stats
--     FOR UPDATE TO public USING (false);

-- connection_metrics: writes service-side only.
-- DROP POLICY connection_metrics_insert ON public.connection_metrics;
-- CREATE POLICY connection_metrics_insert ON public.connection_metrics
--     FOR INSERT TO public WITH CHECK (false);

-- message_templates: lock full CRUD (0 rows, no code refs).
-- DROP POLICY message_templates_all ON public.message_templates;
-- CREATE POLICY message_templates_read ON public.message_templates
--     FOR SELECT TO public USING (true);   -- keep read if templates are public-read; else drop entirely


-- ============================================================================
-- TIER D — APP CHANGE (not pure SQL — flagged to @cto/@pm)
-- ============================================================================
-- D1. P0-email full close: move self-profile read (app.py:391) from the anon
--     key to an authenticated session so RLS owns_profile() can scope email to
--     the owner. Then tighten profiles SELECT policy off USING(true) for
--     sensitive columns.
-- D2. profiles "Anyone can create profile" (INSERT true): DO NOT DROP until the
--     registration flow is verified. If signup inserts the profile pre-auth via
--     anon (auth.uid() IS NULL), dropping it breaks signup (profiles_insert
--     requires auth.uid() IS NOT NULL). Verify auth/magic_link.py + register
--     path first, then either drop or replace with a scoped check.


-- ============================================================================
-- TIER E — CONSOLIDATION (perf + security; clears 55x multiple_permissive_policies)
-- ============================================================================
-- Duplicate legacy policies OR with newer scoped ones; the looser legacy
-- (USING true) wins and undermines the stricter policy. De-dup, keeping the
-- stricter. Candidates (drop legacy, keep granular):
--   profiles: "Profiles are viewable by everyone", "Users can update own profile" (dups of profiles_select/update)
--   assistant_profiles: "Assistant profiles are viewable by everyone" (dup of assistant_profiles_select)
--   assistant_posts: "Users can manage own posts", "Published posts are viewable by everyone" (dups)
-- Apply only after confirming the kept policy is behaviorally >= the dropped one.

-- ============================================================================
-- ROLLBACK NOTE: TIER A column-grant is reversible via
--   GRANT SELECT ON public.profiles TO anon, authenticated;
-- Keep a note of pre-change policy defs (pg_policies dump) before TIER B/C/E.
-- ============================================================================
