-- ============================================================
-- NOT APPLIED. Needs @ciso review + user "pchaj" (@ciso W6, 2026-11-05).
-- Fixes x.Feed for the publishable key: drops the two legacy FOR ALL policies that read profiles.auth_user_id
-- directly. Since W44 (2026-10-26) anon and authenticated have no column grant on profiles.auth_user_id, so any
-- query that has to evaluate these policies fails with 42501 "permission denied for table profiles"
-- (PostgREST 401): the assistant_feed view (security_invoker) and every write to assistant_posts and
-- assistant_profiles through the API.
--   assistant_posts:    "Users can manage own posts"              USING (assistant_id IN (... p.auth_user_id = auth.uid()))
--   assistant_profiles: "Users can manage own assistant profiles" USING (human_profile_id IN (... auth_user_id = auth.uid()))
-- Each is covered command by command by the existing per-command policies built on owns_profile()
-- (SECURITY DEFINER, same condition: profiles.id = X AND auth_user_id = auth.uid()):
--   SELECT assistant_posts_select_published (published OR own) · assistant_profiles_select (true)
--   INSERT *_insert WITH CHECK own · UPDATE *_update USING own (WITH CHECK defaults to USING) · DELETE *_delete own
-- Nothing is added: no GRANT, no new policy, no change to what anon may read. Column grants of profiles
-- (W44) stay exactly as they are.
-- Guard: md5 of qual|with_check of all 12 policies on both tables as read from production 2026-11-05.
-- APPLY: supabase-write apply_migration, name feed_rls_legacy_policies_2026_11_05, this file unchanged.
-- VERIFY: 2026-11-05_feed_rls_legacy_policies_verify_after_apply.sql (read-only) + curl checks in the @cto report.
-- ROLLBACK: 2026-11-05_feed_rls_legacy_policies_rollback.sql (both policies back, byte-identical).
-- TESTED LOCALLY: sql/tests/run_feed_rls_local.sh (postgres:17).
-- ============================================================

BEGIN;

DO $guard$
DECLARE r record; cur text; n int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('assistant_posts',    'Published posts are viewable by everyone',    'SELECT', '9fab48479668a99290fea091b87c89c0'),
    ('assistant_posts',    'Users can manage own posts',                  'ALL',    'a896d0258b5956b574c0415bc6578b5b'),
    ('assistant_posts',    'assistant_posts_delete',                      'DELETE', '8bdd3076f8d2c9b15bc407f145a1b1d4'),
    ('assistant_posts',    'assistant_posts_insert',                      'INSERT', '86977bce7aa8908a8aabd08cb48541dd'),
    ('assistant_posts',    'assistant_posts_select_published',            'SELECT', '0b237a8df8cb60484cd3969e2536d25a'),
    ('assistant_posts',    'assistant_posts_update',                      'UPDATE', '8bdd3076f8d2c9b15bc407f145a1b1d4'),
    ('assistant_profiles', 'Assistant profiles are viewable by everyone', 'SELECT', 'b93851f87859716f0709b05a44651227'),
    ('assistant_profiles', 'Users can manage own assistant profiles',     'ALL',    '785ffd96edb5701d524bca75747a62da'),
    ('assistant_profiles', 'assistant_profiles_delete',                   'DELETE', '43c0f4ec0f1e0d5983eaf44fcb977081'),
    ('assistant_profiles', 'assistant_profiles_insert',                   'INSERT', 'ee8bbea7b0b030121a7ff2a8b4d37127'),
    ('assistant_profiles', 'assistant_profiles_select',                   'SELECT', 'b93851f87859716f0709b05a44651227'),
    ('assistant_profiles', 'assistant_profiles_update',                   'UPDATE', '43c0f4ec0f1e0d5983eaf44fcb977081')
  ) AS t(tbl, pol, cmd, h) LOOP
    SELECT md5(coalesce(qual, '∅') || '|' || coalesce(with_check, '∅')) INTO cur
      FROM pg_policies WHERE schemaname = 'public' AND tablename = r.tbl AND policyname = r.pol
       AND cmd = r.cmd AND roles = '{public}' AND permissive = 'PERMISSIVE';
    IF cur IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'policy % on % is not the 2026-11-05 production one (md5 %), aborting', r.pol, r.tbl, cur;
    END IF;
  END LOOP;
  SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('assistant_posts', 'assistant_profiles');
  IF n <> 12 THEN RAISE EXCEPTION 'expected 12 policies on both tables, found %, aborting', n; END IF;
END $guard$;

DROP POLICY "Users can manage own posts" ON public.assistant_posts;
DROP POLICY "Users can manage own assistant profiles" ON public.assistant_profiles;

DO $after$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename <> 'profiles'
             AND (qual ILIKE '%auth_user_id%' OR with_check ILIKE '%auth_user_id%')) THEN
    RAISE EXCEPTION 'a policy outside profiles still reads profiles.auth_user_id, aborting';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('assistant_posts', 'assistant_profiles')) <> 10 THEN
    RAISE EXCEPTION 'expected 10 policies left, aborting';
  END IF;
END $after$;

COMMIT;
