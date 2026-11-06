-- READ-ONLY verification after 2026-11-05_feed_rls_legacy_policies.sql. Safe with the read-only MCP.
-- Expected: every row ok = true. Any false = stop, call @cto/@ciso.
-- The HTTP check (assistant_feed 200, hidden profile columns still refused) is the curl list in the @cto report.
WITH pol AS (
  SELECT tablename, policyname, cmd, md5(coalesce(qual, '∅') || '|' || coalesce(with_check, '∅')) AS h
  FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('assistant_posts', 'assistant_profiles')
),
expect(tablename, policyname, cmd, h) AS (VALUES
  ('assistant_posts',    'Published posts are viewable by everyone',    'SELECT', '9fab48479668a99290fea091b87c89c0'),
  ('assistant_posts',    'assistant_posts_delete',                      'DELETE', '8bdd3076f8d2c9b15bc407f145a1b1d4'),
  ('assistant_posts',    'assistant_posts_insert',                      'INSERT', '86977bce7aa8908a8aabd08cb48541dd'),
  ('assistant_posts',    'assistant_posts_select_published',            'SELECT', '0b237a8df8cb60484cd3969e2536d25a'),
  ('assistant_posts',    'assistant_posts_update',                      'UPDATE', '8bdd3076f8d2c9b15bc407f145a1b1d4'),
  ('assistant_profiles', 'Assistant profiles are viewable by everyone', 'SELECT', 'b93851f87859716f0709b05a44651227'),
  ('assistant_profiles', 'assistant_profiles_delete',                   'DELETE', '43c0f4ec0f1e0d5983eaf44fcb977081'),
  ('assistant_profiles', 'assistant_profiles_insert',                   'INSERT', 'ee8bbea7b0b030121a7ff2a8b4d37127'),
  ('assistant_profiles', 'assistant_profiles_select',                   'SELECT', 'b93851f87859716f0709b05a44651227'),
  ('assistant_profiles', 'assistant_profiles_update',                   'UPDATE', '43c0f4ec0f1e0d5983eaf44fcb977081')
),
checks(check_name, ok, detail) AS (
  SELECT 'legacy policies gone', count(*) = 0, count(*)::text FROM pol
   WHERE policyname IN ('Users can manage own posts', 'Users can manage own assistant profiles')
  UNION ALL
  SELECT 'exactly 10 policies on both tables', count(*) = 10, count(*)::text FROM pol
  UNION ALL
  SELECT 'unchanged: ' || e.tablename || '.' || e.policyname, p.h IS NOT DISTINCT FROM e.h AND p.cmd = e.cmd, coalesce(p.h, 'missing')
    FROM expect e LEFT JOIN pol p USING (tablename, policyname)
  UNION ALL
  SELECT 'no policy outside profiles reads auth_user_id', count(*) = 0, count(*)::text FROM pg_policies
   WHERE schemaname = 'public' AND tablename <> 'profiles' AND (qual ILIKE '%auth_user_id%' OR with_check ILIKE '%auth_user_id%')
  UNION ALL
  SELECT 'RLS on: ' || relname, relrowsecurity, '' FROM pg_class
   WHERE oid IN ('public.assistant_posts'::regclass, 'public.assistant_profiles'::regclass)
  UNION ALL
  SELECT 'assistant_feed is security_invoker', reloptions @> ARRAY['security_invoker=true'], coalesce(reloptions::text, '')
    FROM pg_class WHERE oid = 'public.assistant_feed'::regclass
  UNION ALL
  SELECT 'anon still has no ' || c || ' on profiles', NOT has_column_privilege('anon', 'public.profiles', c, 'SELECT'), ''
    FROM unnest(ARRAY['auth_user_id', 'email', 'email_verification_token']) c
  UNION ALL
  SELECT 'authenticated still has no ' || c || ' on profiles', NOT has_column_privilege('authenticated', 'public.profiles', c, 'SELECT'), ''
    FROM unnest(ARRAY['auth_user_id', 'email', 'email_verification_token']) c
  UNION ALL
  SELECT 'anon may read the feed columns of profiles', bool_and(has_column_privilege('anon', 'public.profiles', c, 'SELECT')), ''
    FROM unnest(ARRAY['id', 'name', 'location']) c
)
SELECT check_name, ok, detail FROM checks
UNION ALL
SELECT '== ALL OK ==', bool_and(ok), count(*) FILTER (WHERE NOT ok) || ' failed of ' || count(*) FROM checks
ORDER BY 2, 1;
