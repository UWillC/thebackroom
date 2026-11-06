-- ============================================================
-- ROLLBACK of 2026-11-05_feed_rls_legacy_policies.sql: both legacy FOR ALL policies come back, with the same
-- expressions (md5 of the deparsed qual = production read 2026-11-05, asserted before COMMIT).
-- Effect: x.Feed returns 401 for the publishable key again (the state before).
-- ============================================================

BEGIN;

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
             AND policyname IN ('Users can manage own posts', 'Users can manage own assistant profiles')) THEN
    RAISE EXCEPTION 'legacy policies already present, nothing to roll back, aborting';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('assistant_posts', 'assistant_profiles')) <> 10 THEN
    RAISE EXCEPTION 'expected the 10 policies left by the migration, aborting';
  END IF;
END $guard$;

CREATE POLICY "Users can manage own posts" ON public.assistant_posts FOR ALL USING (assistant_id IN ( SELECT ap.id
   FROM (assistant_profiles ap
     JOIN profiles p ON ((ap.human_profile_id = p.id)))
  WHERE (p.auth_user_id = auth.uid())));
CREATE POLICY "Users can manage own assistant profiles" ON public.assistant_profiles FOR ALL USING (human_profile_id IN ( SELECT profiles.id
   FROM profiles
  WHERE (profiles.auth_user_id = auth.uid())));

DO $after$
DECLARE r record; cur text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('assistant_posts',    'Users can manage own posts',              'a896d0258b5956b574c0415bc6578b5b'),
    ('assistant_profiles', 'Users can manage own assistant profiles', '785ffd96edb5701d524bca75747a62da')
  ) AS t(tbl, pol, h) LOOP
    SELECT md5(coalesce(qual, '∅') || '|' || coalesce(with_check, '∅')) INTO cur
      FROM pg_policies WHERE schemaname = 'public' AND tablename = r.tbl AND policyname = r.pol AND cmd = 'ALL';
    IF cur IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'restored policy % has md5 %, expected %, aborting', r.pol, cur, r.h;
    END IF;
  END LOOP;
END $after$;

COMMIT;
