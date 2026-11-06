-- LOCAL ONLY. assistant_profiles + assistant_posts + assistant_feed as read from production 2026-11-05
-- (read-only MCP): columns, RLS on, the 12 live policies, table grants (anon/authenticated: SELECT, INSERT,
-- UPDATE, DELETE), view with security_invoker. Runs on top of the W44 stand-in (profiles column grants).
DROP TABLE IF EXISTS public.assistant_profiles CASCADE;
CREATE TABLE public.assistant_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, slug text NOT NULL, human_profile_id text,
  bio text, personality text, avatar_emoji text DEFAULT '🤖', posts_count integer DEFAULT 0,
  followers_count integer DEFAULT 0, following_count integer DEFAULT 0, created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(), is_active boolean DEFAULT true);
CREATE TABLE public.assistant_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), assistant_id uuid, content text NOT NULL, tags text[],
  status text DEFAULT 'draft', approved_at timestamptz, published_at timestamptz, context_type text,
  context_ref text, reactions_count integer DEFAULT 0, comments_count integer DEFAULT 0,
  shares_count integer DEFAULT 0, created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
ALTER TABLE public.assistant_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assistant_posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Published posts are viewable by everyone" ON public.assistant_posts FOR SELECT USING (status = 'published'::text);
CREATE POLICY "Users can manage own posts" ON public.assistant_posts FOR ALL USING (assistant_id IN ( SELECT ap.id
   FROM (assistant_profiles ap
     JOIN profiles p ON ((ap.human_profile_id = p.id)))
  WHERE (p.auth_user_id = auth.uid())));
CREATE POLICY assistant_posts_delete ON public.assistant_posts FOR DELETE USING (EXISTS ( SELECT 1
   FROM assistant_profiles ap
  WHERE ((ap.id = assistant_posts.assistant_id) AND owns_profile(ap.human_profile_id))));
CREATE POLICY assistant_posts_insert ON public.assistant_posts FOR INSERT WITH CHECK (EXISTS ( SELECT 1
   FROM assistant_profiles ap
  WHERE ((ap.id = assistant_posts.assistant_id) AND owns_profile(ap.human_profile_id))));
CREATE POLICY assistant_posts_select_published ON public.assistant_posts FOR SELECT USING ((status = 'published'::text) OR (EXISTS ( SELECT 1
   FROM assistant_profiles ap
  WHERE ((ap.id = assistant_posts.assistant_id) AND owns_profile(ap.human_profile_id)))));
CREATE POLICY assistant_posts_update ON public.assistant_posts FOR UPDATE USING (EXISTS ( SELECT 1
   FROM assistant_profiles ap
  WHERE ((ap.id = assistant_posts.assistant_id) AND owns_profile(ap.human_profile_id))));

CREATE POLICY "Assistant profiles are viewable by everyone" ON public.assistant_profiles FOR SELECT USING (true);
CREATE POLICY "Users can manage own assistant profiles" ON public.assistant_profiles FOR ALL USING (human_profile_id IN ( SELECT profiles.id
   FROM profiles
  WHERE (profiles.auth_user_id = auth.uid())));
CREATE POLICY assistant_profiles_delete ON public.assistant_profiles FOR DELETE USING (owns_profile(human_profile_id));
CREATE POLICY assistant_profiles_insert ON public.assistant_profiles FOR INSERT WITH CHECK (owns_profile(human_profile_id));
CREATE POLICY assistant_profiles_select ON public.assistant_profiles FOR SELECT USING (true);
CREATE POLICY assistant_profiles_update ON public.assistant_profiles FOR UPDATE USING (owns_profile(human_profile_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.assistant_profiles, public.assistant_posts TO anon, authenticated;
GRANT ALL ON public.assistant_profiles, public.assistant_posts TO service_role;

CREATE VIEW public.assistant_feed WITH (security_invoker = true) AS
 SELECT p.id, p.content, p.tags, p.context_type, p.context_ref, p.reactions_count, p.comments_count, p.published_at,
    a.id AS assistant_id, a.name AS assistant_name, a.slug AS assistant_slug, a.avatar_emoji, a.bio AS assistant_bio,
    h.name AS human_name, h.location AS human_location
   FROM ((assistant_posts p
     JOIN assistant_profiles a ON ((p.assistant_id = a.id)))
     LEFT JOIN profiles h ON ((a.human_profile_id = h.id)))
  WHERE (p.status = 'published'::text)
  ORDER BY p.published_at DESC;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.assistant_feed TO anon, authenticated;

-- seed: A1 belongs to owner1, A2 to user2; P1 published (A1), P2 draft (A1), P3 draft (A2)
INSERT INTO public.assistant_profiles (id, name, slug, human_profile_id) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'A1', 'a1', 'owner1'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'A2', 'a2', 'user2');
INSERT INTO public.assistant_posts (id, assistant_id, content, status, published_at) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'published one', 'published', now()),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'draft own', 'draft', NULL),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000002', 'draft other', 'draft', NULL);

-- test helpers: run as role/uid, report the outcome, always roll the change back
CREATE FUNCTION public.t_cnt(p_role text, p_uid text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  BEGIN
    PERFORM set_config('test.uid', coalesce(p_uid, ''), true);
    PERFORM set_config('role', p_role, true);
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') s' INTO n;
    RAISE EXCEPTION 'T_RESULT:%', n;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'T_RESULT:%' THEN RETURN 'rows ' || substr(SQLERRM, 10); END IF;
    RETURN SQLSTATE;
  END;
END $$;
CREATE FUNCTION public.t_dml(p_role text, p_uid text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  BEGIN
    PERFORM set_config('test.uid', coalesce(p_uid, ''), true);
    PERFORM set_config('role', p_role, true);
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE EXCEPTION 'T_RESULT:%', n;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'T_RESULT:%' THEN RETURN 'changed ' || substr(SQLERRM, 10); END IF;
    RETURN SQLSTATE;
  END;
END $$;

-- Authorization matrix: who may read, add, change and delete posts and assistant profiles.
CREATE FUNCTION public.t_feed_matrix() RETURNS TABLE(case_name text, outcome text) LANGUAGE sql AS $$
  WITH o(u) AS (VALUES ('00000000-0000-0000-0000-00000000000a'))
  SELECT * FROM (VALUES
   ('owner reads posts',              t_cnt('authenticated', (SELECT u FROM o), 'SELECT id FROM assistant_posts')),
   ('owner reads other draft',        t_cnt('authenticated', (SELECT u FROM o), $q$SELECT id FROM assistant_posts WHERE id = 'bbbbbbbb-0000-0000-0000-000000000003'$q$)),
   ('owner adds post to own asst',    t_dml('authenticated', (SELECT u FROM o), $q$INSERT INTO assistant_posts (assistant_id, content) VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'x')$q$)),
   ('owner adds post to other asst',  t_dml('authenticated', (SELECT u FROM o), $q$INSERT INTO assistant_posts (assistant_id, content) VALUES ('aaaaaaaa-0000-0000-0000-000000000002', 'x')$q$)),
   ('owner edits own draft',          t_dml('authenticated', (SELECT u FROM o), $q$UPDATE assistant_posts SET content = 'y' WHERE id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$)),
   ('owner edits other draft',        t_dml('authenticated', (SELECT u FROM o), $q$UPDATE assistant_posts SET content = 'y' WHERE id = 'bbbbbbbb-0000-0000-0000-000000000003'$q$)),
   ('owner moves post to other asst', t_dml('authenticated', (SELECT u FROM o), $q$UPDATE assistant_posts SET assistant_id = 'aaaaaaaa-0000-0000-0000-000000000002' WHERE id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$)),
   ('owner deletes own draft',        t_dml('authenticated', (SELECT u FROM o), $q$DELETE FROM assistant_posts WHERE id = 'bbbbbbbb-0000-0000-0000-000000000002'$q$)),
   ('owner deletes other draft',      t_dml('authenticated', (SELECT u FROM o), $q$DELETE FROM assistant_posts WHERE id = 'bbbbbbbb-0000-0000-0000-000000000003'$q$)),
   ('owner reads assistants',         t_cnt('authenticated', (SELECT u FROM o), 'SELECT id FROM assistant_profiles')),
   ('owner adds own assistant',       t_dml('authenticated', (SELECT u FROM o), $q$INSERT INTO assistant_profiles (name, slug, human_profile_id) VALUES ('n', 'n', 'owner1')$q$)),
   ('owner adds assistant for other', t_dml('authenticated', (SELECT u FROM o), $q$INSERT INTO assistant_profiles (name, slug, human_profile_id) VALUES ('n', 'n', 'user2')$q$)),
   ('owner edits own assistant',      t_dml('authenticated', (SELECT u FROM o), $q$UPDATE assistant_profiles SET bio = 'b' WHERE slug = 'a1'$q$)),
   ('owner edits other assistant',    t_dml('authenticated', (SELECT u FROM o), $q$UPDATE assistant_profiles SET bio = 'b' WHERE slug = 'a2'$q$)),
   ('owner hands assistant to other', t_dml('authenticated', (SELECT u FROM o), $q$UPDATE assistant_profiles SET human_profile_id = 'user2' WHERE slug = 'a1'$q$)),
   ('owner deletes other assistant',  t_dml('authenticated', (SELECT u FROM o), $q$DELETE FROM assistant_profiles WHERE slug = 'a2'$q$)),
   ('owner deletes own assistant',    t_dml('authenticated', (SELECT u FROM o), $q$DELETE FROM assistant_profiles WHERE slug = 'a1'$q$)),
   ('anon reads posts',               t_cnt('anon', NULL, 'SELECT id FROM assistant_posts')),
   ('anon adds post',                 t_dml('anon', NULL, $q$INSERT INTO assistant_posts (assistant_id, content) VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'x')$q$)),
   ('anon edits published post',      t_dml('anon', NULL, $q$UPDATE assistant_posts SET content = 'y' WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001'$q$)),
   ('anon deletes published post',    t_dml('anon', NULL, $q$DELETE FROM assistant_posts WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001'$q$)),
   ('anon reads assistants',          t_cnt('anon', NULL, 'SELECT id FROM assistant_profiles')),
   ('anon adds assistant',            t_dml('anon', NULL, $q$INSERT INTO assistant_profiles (name, slug, human_profile_id) VALUES ('n', 'n', 'owner1')$q$)),
   ('anon edits assistant',           t_dml('anon', NULL, $q$UPDATE assistant_profiles SET bio = 'b' WHERE slug = 'a1'$q$))
  ) AS m(case_name, outcome)
$$;
