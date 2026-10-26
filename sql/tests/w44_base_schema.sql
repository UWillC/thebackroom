-- ============================================================
-- LOCAL ONLY (postgres:17 in docker). Never run against Supabase.
-- Minimal stand-in for the live Backroom schema as read 2026-10-26 (read-only MCP):
-- the columns, policies and grants that 2026-10-26_w44_19_20_hardening.sql touches.
-- Stubs: auth.uid() reads the GUC test.uid, net.http_post() records mails in
-- test_outbox, get_resend_key() returns a dummy, find_profile_matches() returns one row.
-- ============================================================
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;

CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto SCHEMA extensions;
CREATE SCHEMA auth;
CREATE SCHEMA net;
GRANT USAGE ON SCHEMA public, auth, extensions TO anon, authenticated, service_role;

CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('test.uid', true), '')::uuid $$;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

CREATE TABLE public.test_outbox (n serial, payload jsonb);
CREATE FUNCTION net.http_post(url text, headers jsonb, body jsonb) RETURNS bigint
LANGUAGE sql AS $$ INSERT INTO public.test_outbox(payload) VALUES (body) RETURNING n::bigint $$;

CREATE FUNCTION public.get_resend_key() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO '' AS $$ SELECT 're_dummy'::text $$;
REVOKE ALL ON FUNCTION public.get_resend_key() FROM PUBLIC;

-- profiles: same columns and order as live
CREATE TABLE public.profiles (
  id text PRIMARY KEY, name text NOT NULL, email text, role text, industry text[], skills text[],
  offers text[], seeks text[], assistant_endpoint text, preferences jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now(), location text,
  bio text, tags text[], offer_free text, offer_condition text, preferred_contact text,
  linkedin_url text, quality_score integer DEFAULT 0, quality_feedback text,
  quality_checked_at timestamptz, email_verified boolean DEFAULT false,
  email_verification_token text, email_verification_sent_at timestamptz,
  notifications_enabled boolean DEFAULT true, auth_user_id uuid
);
CREATE TABLE public.rooms (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL,
  slug text, room_type text DEFAULT 'enterprise', owner_id text REFERENCES public.profiles(id));
CREATE TABLE public.room_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  profile_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role text DEFAULT 'member' CHECK (role = ANY (ARRAY['owner','admin','member'])),
  status text DEFAULT 'pending' CHECK (status = ANY (ARRAY['pending','approved','suspended','offboarded'])),
  invited_by text REFERENCES public.profiles(id), invite_token text UNIQUE, joined_at timestamptz,
  offboarded_at timestamptz, offboarded_by text, offboard_reason text,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now(),
  assistant_profile_id uuid,
  UNIQUE (room_id, profile_id, assistant_profile_id));
CREATE UNIQUE INDEX idx_room_members_enterprise_unique ON public.room_members (room_id, profile_id)
  WHERE assistant_profile_id IS NULL;
CREATE TABLE public.room_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  created_by text NOT NULL REFERENCES public.profiles(id),
  token text NOT NULL UNIQUE DEFAULT encode(extensions.gen_random_bytes(16), 'hex'),
  max_uses integer DEFAULT 1, uses integer DEFAULT 0,
  expires_at timestamptz DEFAULT (now() + interval '7 days'), note text,
  is_active boolean DEFAULT true, created_at timestamptz DEFAULT now(), email text);
CREATE TABLE public.connection_requests (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user text REFERENCES public.profiles(id), to_user text REFERENCES public.profiles(id),
  status text DEFAULT 'pending', message text, response_message text);
CREATE TABLE public.room_messages (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), room_id uuid,
  from_profile_id text, message_type text, priority text DEFAULT 'normal', subject text, body text,
  deadline timestamptz);
CREATE TABLE public.message_recipients (message_id uuid, profile_id text);
CREATE TABLE public.profile_stats (profile_id text, stat_type text, context text);

CREATE FUNCTION public.find_profile_matches(p_profile_id text, p_limit int)
RETURNS TABLE(matched_name text, matched_role text, matched_location text, match_type text)
LANGUAGE sql AS $$ SELECT name, role, location, 'collaboration'::text FROM public.profiles
  WHERE id <> p_profile_id ORDER BY id LIMIT p_limit $$;

-- helpers as live (bodies simplified, same semantics)
CREATE FUNCTION public.get_my_profile_id() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp' AS $$ SELECT id FROM profiles WHERE auth_user_id = auth.uid() $$;
CREATE FUNCTION public.owns_profile(profile_id text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp' AS $$ SELECT EXISTS (SELECT 1 FROM profiles
  WHERE id = profile_id AND auth_user_id = auth.uid()) $$;
CREATE FUNCTION public.is_room_member(p_room_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp' AS $$ SELECT EXISTS (SELECT 1 FROM room_members rm
  JOIN profiles p ON rm.profile_id = p.id WHERE rm.room_id = p_room_id
  AND p.auth_user_id = auth.uid() AND rm.status = 'approved') $$;

-- live grants: table-level ALL (minus TRUNCATE) for anon/authenticated, as read 2026-10-26
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles, public.rooms, public.room_members,
  public.room_invites, public.connection_requests TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- live RLS + policies
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connection_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can create profile" ON public.profiles FOR INSERT WITH CHECK (true);
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth_user_id = auth.uid());
CREATE POLICY profiles_delete ON public.profiles FOR DELETE USING (auth_user_id = auth.uid());
CREATE POLICY profiles_insert ON public.profiles FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY profiles_select ON public.profiles FOR SELECT USING (true);
CREATE POLICY profiles_update ON public.profiles FOR UPDATE USING (auth_user_id = auth.uid());
CREATE POLICY rooms_insert ON public.rooms FOR INSERT WITH CHECK (owns_profile(owner_id));
CREATE POLICY rooms_select ON public.rooms FOR SELECT USING (is_room_member(id) OR owner_id = get_my_profile_id());
CREATE POLICY room_invites_insert ON public.room_invites FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM rooms r
  WHERE r.id = room_invites.room_id AND owns_profile(r.owner_id)));
CREATE POLICY room_invites_select ON public.room_invites FOR SELECT USING (EXISTS (SELECT 1 FROM rooms r
  WHERE r.id = room_invites.room_id AND owns_profile(r.owner_id)));
CREATE POLICY room_members_insert ON public.room_members FOR INSERT WITH CHECK (
  (EXISTS (SELECT 1 FROM rooms r WHERE r.id = room_members.room_id AND owns_profile(r.owner_id)))
  OR (profile_id = get_my_profile_id()));
CREATE POLICY room_members_select ON public.room_members FOR SELECT USING (is_room_member(room_id)
  OR (EXISTS (SELECT 1 FROM rooms r WHERE r.id = room_members.room_id AND owns_profile(r.owner_id))));
CREATE POLICY room_members_update ON public.room_members FOR UPDATE USING (EXISTS (SELECT 1 FROM rooms r
  WHERE r.id = room_members.room_id AND owns_profile(r.owner_id)));
CREATE POLICY connection_requests_insert ON public.connection_requests FOR INSERT WITH CHECK (owns_profile(from_user));
CREATE POLICY connection_requests_select ON public.connection_requests FOR SELECT USING (owns_profile(from_user) OR owns_profile(to_user));
CREATE POLICY connection_requests_update ON public.connection_requests FOR UPDATE USING (owns_profile(to_user));

CREATE TABLE public.room_audit_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  actor_id text NOT NULL REFERENCES public.profiles(id), action text NOT NULL CHECK (action = ANY (ARRAY[
  'room_created','room_updated','room_deleted','member_invited','member_joined','member_approved',
  'member_rejected','member_suspended','member_offboarded','member_role_changed','invite_created',
  'invite_revoked','settings_changed'])), target_id text, details jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now());
GRANT ALL ON public.room_audit_log TO service_role;

-- added after @ciso review 2026-10-26: live room_members_delete + assistant_profiles (SELECT true)
CREATE POLICY room_members_delete ON public.room_members FOR DELETE USING (
  (EXISTS (SELECT 1 FROM rooms r WHERE r.id = room_members.room_id AND owns_profile(r.owner_id)))
  OR owns_profile(profile_id));
CREATE TABLE public.assistant_profiles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL,
  slug text NOT NULL, human_profile_id text, is_active boolean DEFAULT true);
ALTER TABLE public.assistant_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY assistant_profiles_select ON public.assistant_profiles FOR SELECT USING (true);
GRANT SELECT ON public.assistant_profiles TO anon, authenticated;
GRANT ALL ON public.assistant_profiles TO service_role;
-- live ACL of profiles 2026-10-26 is arwd (no REFERENCES/TRIGGER); the GRANT above already matches
