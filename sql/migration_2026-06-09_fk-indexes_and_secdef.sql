-- ============================================================================
-- Migration: 2026-06-09  FK indexes + SECURITY DEFINER advisor remediation
-- Author: @cto  | Project: The Backroom (ifofgblilanwjhypzvdb)
-- Source: supabase get_advisors (performance: unindexed_foreign_keys x9;
--         security: anon/authenticated SECURITY DEFINER executable x3)
--
-- READ THIS FIRST:
--   PART A (FK indexes)  = SAFE. Apply now. Idempotent, non-destructive.
--   PART B (SECDEF fix)  = DO NOT RUN BLIND. The naive REVOKE breaks the app.
--                          See the long comment in PART B. Deferred by default.
-- ============================================================================


-- ============================================================================
-- PART A — FK INDEXES  (9 unindexed foreign keys)   [STATUS: READY TO APPLY]
-- ============================================================================
-- Every FK below is single-column. Tables are tiny (<100 rows today), so a
-- plain CREATE INDEX locks for milliseconds. IF NOT EXISTS = safe re-run.
--
-- Why: an FK without a covering index forces a sequential scan on the child
-- table for every DELETE/UPDATE of the parent row, and slows FK-join filters.
-- Zero downside at this scale; pure upside as row counts grow.
--
-- NOTE on apply method:
--   * supabase apply_migration / this file as-is  -> plain CREATE INDEX (fine).
--   * If you ever re-run this on a LARGE table, swap to
--       CREATE INDEX CONCURRENTLY ...   (and run it OUTSIDE a txn / migration,
--       because CONCURRENTLY cannot run inside a transaction block).

CREATE INDEX IF NOT EXISTS idx_message_recipients_assistant_profile_id
    ON public.message_recipients (assistant_profile_id);

CREATE INDEX IF NOT EXISTS idx_message_recipients_response_message_id
    ON public.message_recipients (response_message_id);

CREATE INDEX IF NOT EXISTS idx_message_templates_created_by
    ON public.message_templates (created_by);

CREATE INDEX IF NOT EXISTS idx_room_invites_created_by
    ON public.room_invites (created_by);

CREATE INDEX IF NOT EXISTS idx_room_members_assistant_profile_id
    ON public.room_members (assistant_profile_id);

CREATE INDEX IF NOT EXISTS idx_room_members_invited_by
    ON public.room_members (invited_by);

CREATE INDEX IF NOT EXISTS idx_room_members_offboarded_by
    ON public.room_members (offboarded_by);

CREATE INDEX IF NOT EXISTS idx_room_messages_from_assistant_id
    ON public.room_messages (from_assistant_id);

CREATE INDEX IF NOT EXISTS idx_room_messages_to_assistant_id
    ON public.room_messages (to_assistant_id);

-- Verify after apply:
--   SELECT relname, indexrelname FROM pg_stat_user_indexes
--   WHERE indexrelname LIKE 'idx_%' ORDER BY relname;


-- ============================================================================
-- PART B — SECURITY DEFINER advisor (3 functions)   [STATUS: DEFERRED / DANGER]
-- ============================================================================
-- Advisor flags that these are callable by anon + authenticated via REST RPC:
--     public.get_my_profile_id()
--     public.is_room_member(uuid)
--     public.owns_profile(text)
--
-- !!! DO NOT "REVOKE EXECUTE FROM anon, authenticated" ON THESE. !!!
-- These 3 functions are referenced inside 34 RLS policies across the schema
-- (owns_profile in nearly all; is_room_member in room_messages/rooms/
-- room_members; get_my_profile_id in room_members/rooms). RLS policy
-- expressions are evaluated WITH THE QUERYING ROLE'S privileges, so the role
-- MUST keep EXECUTE on these functions. Revoking EXECUTE => "permission denied
-- for function" inside every affected policy => RLS breaks for anon and
-- authenticated => the whole app (incl. SNOW Sync @ceo<->@mind) goes down.
--
-- RISK ASSESSMENT (why this is LOW severity, why we defer):
--   * All three are scoped to auth.uid() -- they only ever return data about
--     the CALLER (your own profile id / whether YOU own X / whether YOU are in
--     room R). Direct RPC calls leak NOTHING cross-tenant.
--   * search_path is already pinned ('public','pg_temp') -> the genuinely
--     dangerous SECURITY DEFINER search_path-hijack vector is already closed.
--   => The advisor WARN is technically true but benign here. Accepting it is a
--      defensible call.
--
-- THE ONLY SAFE FIX (if you want a clean advisor board): move the helpers to a
-- schema PostgREST does NOT expose (default exposed schemas: public,
-- graphql_public). A 'private' schema is unreachable via REST RPC, while
-- policies can still call private.fn() (EXECUTE stays granted, so RLS works).
--
-- This requires DROP + CREATE of all 34 policies repointed to private.fn().
-- That is a real, tested project -- NOT a blind diff -- because a single
-- mis-typed policy silently widens or breaks access. Steps:
--
--   1. CREATE SCHEMA private;
--   2. Recreate the 3 functions as private.<name> (identical bodies).
--   3. GRANT EXECUTE ON each private.<name> TO authenticated, anon, service_role;
--   4. For EACH of the 34 policies: DROP POLICY + CREATE POLICY with the same
--      USING/WITH CHECK, swapping public.fn(...) -> private.fn(...).
--      (Extract current defs first:  SELECT * FROM pg_policies WHERE schemaname='public';)
--   5. DROP the 3 public.<name> functions.
--   6. Re-run get_advisors security -> warnings cleared.
--
-- @cto recommendation: DEFER. Schedule as a standalone migration with a full
-- RLS test pass (auth as a real assistant profile, exercise room read/write)
-- BEFORE dropping the public functions. Not worth a rushed change on a live DB
-- for a benign, auth.uid()-scoped exposure.
--
-- Skeleton only (left commented -- step 4 intentionally omitted until policy
-- DDL is dumped and each one is repointed + tested):
--
-- CREATE SCHEMA IF NOT EXISTS private;
-- CREATE OR REPLACE FUNCTION private.get_my_profile_id() RETURNS text
--   LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
--   AS $$ SELECT id FROM profiles WHERE auth_user_id = auth.uid(); $$;
-- CREATE OR REPLACE FUNCTION private.is_room_member(p_room_id uuid) RETURNS boolean
--   LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
--   AS $$ SELECT EXISTS (SELECT 1 FROM room_members rm JOIN profiles p
--          ON rm.profile_id = p.id WHERE rm.room_id = p_room_id
--          AND p.auth_user_id = auth.uid() AND rm.status = 'approved'); $$;
-- CREATE OR REPLACE FUNCTION private.owns_profile(profile_id text) RETURNS boolean
--   LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
--   AS $$ SELECT EXISTS (SELECT 1 FROM profiles WHERE id = profile_id
--          AND auth_user_id = auth.uid()); $$;
-- GRANT EXECUTE ON FUNCTION private.get_my_profile_id()      TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION private.is_room_member(uuid)     TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION private.owns_profile(text)       TO anon, authenticated, service_role;
-- -- step 4: repoint 34 policies (see pg_policies dump) ...
-- -- step 5: DROP FUNCTION public.get_my_profile_id(); etc.
--
-- ============================================================================
-- END
-- ============================================================================
