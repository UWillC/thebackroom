-- ============================================================
-- LOCAL ONLY (postgres:17 in docker). Never run against Supabase.
-- Minimal stand-in for the live tables and foreign keys that 2026-10-30_privacy_retention.sql
-- touches, as read 2026-10-30 with the read-only MCP (pg_constraint, pg_trigger, columns).
-- Only the audit and reaction-count triggers are reproduced (mail triggers fire on INSERT /
-- status change, which the deletion does not do).
-- ============================================================
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto SCHEMA extensions;

CREATE TABLE public.profiles (id text PRIMARY KEY, name text NOT NULL, email text, auth_user_id uuid,
  created_at timestamptz DEFAULT now());
CREATE TABLE public.profile_offers (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id text REFERENCES public.profiles(id) ON DELETE CASCADE, title text);
CREATE TABLE public.assistant_profiles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text,
  human_profile_id text REFERENCES public.profiles(id), posts_count int DEFAULT 0);
CREATE TABLE public.assistant_posts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assistant_id uuid REFERENCES public.assistant_profiles(id) ON DELETE CASCADE, content text,
  reactions_count int DEFAULT 0);
CREATE TABLE public.post_reactions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid REFERENCES public.assistant_posts(id) ON DELETE CASCADE,
  profile_id text REFERENCES public.profiles(id) ON DELETE CASCADE);
CREATE FUNCTION public.update_post_reactions_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN UPDATE assistant_posts SET reactions_count = reactions_count + 1 WHERE id = NEW.post_id; RETURN NEW;
  ELSE UPDATE assistant_posts SET reactions_count = reactions_count - 1 WHERE id = OLD.post_id; RETURN OLD; END IF;
END $$;
CREATE TRIGGER reactions_count_trigger AFTER INSERT OR DELETE ON public.post_reactions
  FOR EACH ROW EXECUTE FUNCTION public.update_post_reactions_count();

CREATE TABLE public.connection_requests (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user text NOT NULL REFERENCES public.profiles(id), to_user text NOT NULL REFERENCES public.profiles(id),
  message text, status text DEFAULT 'pending');
CREATE TABLE public.connection_metrics (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.connection_requests(id) ON DELETE CASCADE, metadata jsonb);

CREATE TABLE public.rooms (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL,
  owner_id text NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT);
CREATE TABLE public.room_members (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  profile_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  assistant_profile_id uuid REFERENCES public.assistant_profiles(id) ON DELETE CASCADE,
  status text DEFAULT 'approved',
  invited_by text REFERENCES public.profiles(id), offboarded_by text REFERENCES public.profiles(id));
CREATE TABLE public.room_invites (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  created_by text NOT NULL REFERENCES public.profiles(id), email text);
CREATE TABLE public.room_audit_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  actor_id text NOT NULL REFERENCES public.profiles(id), action text,
  target_id text, details jsonb DEFAULT '{}');
CREATE TABLE public.room_messages (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  from_profile_id text NOT NULL REFERENCES public.profiles(id),
  from_assistant_id uuid REFERENCES public.assistant_profiles(id),
  to_profile_id text REFERENCES public.profiles(id),
  to_assistant_id uuid REFERENCES public.assistant_profiles(id),
  in_reply_to uuid REFERENCES public.room_messages(id), subject text, body text);
CREATE TABLE public.message_recipients (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.room_messages(id) ON DELETE CASCADE,
  profile_id text NOT NULL REFERENCES public.profiles(id),
  assistant_profile_id uuid REFERENCES public.assistant_profiles(id),
  response_message_id uuid REFERENCES public.room_messages(id));
CREATE TABLE public.message_templates (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  created_by text REFERENCES public.profiles(id));

CREATE TABLE public.profile_stats (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, stat_type text,
  viewer_id text, context text, created_at timestamptz DEFAULT now());
CREATE TABLE public.search_logs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), query text NOT NULL,
  results_count int DEFAULT 0, user_id text, created_at timestamptz DEFAULT now());
CREATE TABLE public.rate_limits (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id text NOT NULL,
  action_type text NOT NULL, created_at timestamptz DEFAULT now());
CREATE TABLE public.mcp_client_sessions (client_key_hash text, kind text, email text, user_id uuid,
  session jsonb, created_at timestamptz DEFAULT now());
CREATE TABLE public.mcp_sessions (email text PRIMARY KEY, session jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.email_send_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), recipient_hash text,
  kind text, created_at timestamptz DEFAULT now());
CREATE TABLE public.audit_logs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id text,
  user_email text, action text NOT NULL, table_name text NOT NULL, record_id text, old_data jsonb,
  new_data jsonb, changes jsonb, created_at timestamptz DEFAULT now());
-- API roles: insert-only on the log tables, like live RLS (no DELETE for them)
ALTER TABLE public.search_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow insert" ON public.search_logs FOR INSERT WITH CHECK (true);
GRANT INSERT ON public.search_logs TO anon;

CREATE FUNCTION public.audit_trigger_func() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO audit_logs (user_id, action, table_name, record_id, old_data, new_data)
  VALUES (CASE WHEN TG_OP = 'DELETE' THEN OLD.id::text ELSE NEW.id::text END, TG_OP, TG_TABLE_NAME,
          CASE WHEN TG_OP = 'DELETE' THEN OLD.id::text ELSE NEW.id::text END,
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
CREATE TRIGGER audit_profiles AFTER INSERT OR UPDATE OR DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_connection_requests AFTER INSERT OR UPDATE OR DELETE ON public.connection_requests FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_rooms AFTER INSERT OR UPDATE OR DELETE ON public.rooms FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_room_members AFTER INSERT OR UPDATE OR DELETE ON public.room_members FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
