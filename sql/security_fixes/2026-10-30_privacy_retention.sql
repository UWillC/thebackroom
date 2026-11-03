-- ============================================================
-- APPLIED 2026-11-02 as migration privacy_retention_2026_10_30, after the fresh backup + row counts (21 rows
-- deleted) + user "pchaj". @ciso review 2026-11-02: GO with conditions, W1-W3 fixed here.
--
-- Privacy policy (docs/privacy.html), @ciso review 2026-10-30, decision B + W4 + W6.
-- Author @cto 2026-10-30. Live catalog read 2026-10-30 with the read-only MCP (FKs, triggers,
-- columns, extensions; no user data): no triggers on search_logs / profile_stats / audit_logs /
-- rate_limits, no pg_cron (only pg_net), so cleanup_old_rate_limits() never runs.
--
-- WHAT WAS WRONG (live 2026-10-30):
--   a) audit_logs keeps a full copy of every profile (incl. e-mail) before/after each change,
--      also after the profile is deleted, with no expiry.
--   b) search_logs, profile_stats (search text + viewer), rate_limits: no deletion at all.
--   c) "We delete your whole account on request" had no procedure: DELETE on profiles is blocked
--      by FKs without cascade (connection_requests, rooms RESTRICT, room_messages,
--      message_recipients, room_invites, room_audit_log, message_templates, assistant_profiles),
--      and a successful delete writes one more full copy into audit_logs.
--
-- WHAT THIS DOES:
--   1. Guard: aborts if already applied or if a table it relies on is missing.
--   2. tb_retention_cleanup(): statement-level AFTER INSERT trigger on the 4 tables. Same idea as
--      email_send_log (old rows are deleted when new ones are written), no pg_cron, no new service.
--        audit_logs     90 days
--        search_logs    12 months
--        profile_stats  12 months
--        rate_limits     7 days (matches cleanup_old_rate_limits(), which stays as is)
--      SECURITY DEFINER, so the delete works whatever role inserted the row (RLS on these tables
--      does not give API roles DELETE). Not callable over the API (trigger function, EXECUTE revoked).
--   3. One-time cleanup of rows already older than these periods (part of the same transaction).
--   4. tb_delete_account(p_profile_id): deletes one account and everything tied to it in one
--      transaction (order below), then the audit_logs rows that are about it (per field, never a
--      text search on the profile id, which also hits JSON keys and values). Decided by @ceo 2026-11-01:
--      messages the person SENT in shared rooms are deleted; messages others sent TO them stay, without
--      the link to the deleted profile. Decided 2026-11-02: deleting a room owner deletes their rooms
--      with everything in them, also other people's messages.
--      EXECUTE: nobody but the owner (postgres). Run by hand in the SQL editor, see
--      sql/README.md "Account deletion runbook". Returns counts + auth_user_id for step 2 of the
--      runbook (Supabase Auth user is deleted in the dashboard, not here).
--
-- Rollback: 2026-10-30_privacy_retention_rollback.sql (drops triggers + both functions; rows
-- already deleted are not restored). Checks: 2026-10-30_privacy_retention_verify_after_apply.sql.
-- Local proof: sql/tests/run_privacy_local.sh (postgres:17 in docker).
-- ============================================================

BEGIN;

DO $guard$
BEGIN
  IF to_regprocedure('public.tb_retention_cleanup()') IS NOT NULL
     OR to_regprocedure('public.tb_delete_account(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'privacy_retention already applied (functions exist), aborting';
  END IF;
  IF to_regclass('public.audit_logs') IS NULL OR to_regclass('public.search_logs') IS NULL
     OR to_regclass('public.profile_stats') IS NULL OR to_regclass('public.rate_limits') IS NULL
     OR to_regclass('public.mcp_client_sessions') IS NULL OR to_regclass('public.mcp_sessions') IS NULL
     OR to_regclass('public.email_send_log') IS NULL THEN
    RAISE EXCEPTION 'privacy_retention: expected table missing, aborting';
  END IF;
END
$guard$;

-- ------------------------------------------------------------
-- 2. Retention trigger
-- ------------------------------------------------------------
CREATE FUNCTION public.tb_retention_cleanup()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  CASE TG_TABLE_NAME
    WHEN 'audit_logs'    THEN DELETE FROM public.audit_logs    WHERE created_at < now() - interval '90 days';
    WHEN 'search_logs'   THEN DELETE FROM public.search_logs   WHERE created_at < now() - interval '12 months';
    WHEN 'profile_stats' THEN DELETE FROM public.profile_stats WHERE created_at < now() - interval '12 months';
    WHEN 'rate_limits'   THEN DELETE FROM public.rate_limits   WHERE created_at < now() - interval '7 days';
  END CASE;
  RETURN NULL;
END $$;

REVOKE ALL ON FUNCTION public.tb_retention_cleanup() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER tb_retention AFTER INSERT ON public.audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION public.tb_retention_cleanup();
CREATE TRIGGER tb_retention AFTER INSERT ON public.search_logs
  FOR EACH STATEMENT EXECUTE FUNCTION public.tb_retention_cleanup();
CREATE TRIGGER tb_retention AFTER INSERT ON public.profile_stats
  FOR EACH STATEMENT EXECUTE FUNCTION public.tb_retention_cleanup();
CREATE TRIGGER tb_retention AFTER INSERT ON public.rate_limits
  FOR EACH STATEMENT EXECUTE FUNCTION public.tb_retention_cleanup();

-- ------------------------------------------------------------
-- 3. One-time cleanup of what is already past the period
-- ------------------------------------------------------------
DELETE FROM public.audit_logs    WHERE created_at < now() - interval '90 days';
DELETE FROM public.search_logs   WHERE created_at < now() - interval '12 months';
DELETE FROM public.profile_stats WHERE created_at < now() - interval '12 months';
DELETE FROM public.rate_limits   WHERE created_at < now() - interval '7 days';

-- ------------------------------------------------------------
-- 4. Account deletion (runbook, owner-only)
-- ------------------------------------------------------------
CREATE FUNCTION public.tb_delete_account(p_profile_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_email text;
  v_auth  uuid;
  v_assistants uuid[];
  v_msgs uuid[];
  v_rooms uuid[];
  v_hash text;
  n int;
  r jsonb := '{}'::jsonb;
BEGIN
  IF p_profile_id IS NULL OR p_profile_id !~ '^[a-z0-9_()]{1,100}$' THEN
    RAISE EXCEPTION 'tb_delete_account: invalid profile id';
  END IF;
  SELECT email, auth_user_id INTO v_email, v_auth FROM profiles WHERE id = p_profile_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tb_delete_account: profile % not found', p_profile_id;
  END IF;

  v_assistants := ARRAY(SELECT id FROM assistant_profiles WHERE human_profile_id = p_profile_id);
  v_rooms      := ARRAY(SELECT id FROM rooms WHERE owner_id = p_profile_id);
  -- messages written by the person (or their assistants) + all messages in rooms they own
  v_msgs := ARRAY(SELECT id FROM room_messages
                   WHERE from_profile_id = p_profile_id
                      OR from_assistant_id = ANY(v_assistants)
                      OR room_id = ANY(v_rooms));

  -- references into the messages that go away
  UPDATE room_messages SET in_reply_to = NULL
   WHERE in_reply_to = ANY(v_msgs) AND NOT (id = ANY(v_msgs));
  UPDATE message_recipients SET response_message_id = NULL
   WHERE response_message_id = ANY(v_msgs) AND NOT (message_id = ANY(v_msgs));
  DELETE FROM room_messages WHERE id = ANY(v_msgs);            -- message_recipients cascade
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('room_messages_sent', n);

  -- messages others sent TO the person stay, without the link
  UPDATE room_messages SET to_profile_id = NULL WHERE to_profile_id = p_profile_id;
  UPDATE room_messages SET to_assistant_id = NULL WHERE to_assistant_id = ANY(v_assistants);
  DELETE FROM message_recipients WHERE profile_id = p_profile_id;
  UPDATE message_recipients SET assistant_profile_id = NULL WHERE assistant_profile_id = ANY(v_assistants);

  DELETE FROM message_templates WHERE created_by = p_profile_id;
  DELETE FROM rooms WHERE id = ANY(v_rooms);                   -- members, invites, messages, room log cascade
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('rooms_owned', n);
  DELETE FROM room_invites   WHERE created_by = p_profile_id OR (v_email IS NOT NULL AND lower(email) = lower(v_email));
  DELETE FROM room_audit_log WHERE actor_id   = p_profile_id;
  -- entries of other actors in other rooms stay, without the person. log_room_action writes role,
  -- room_type (fixed vocabulary, a profile named "member" must not match), reason, note, max_uses
  -- and, for invite_created, the invited e-mail.
  UPDATE room_audit_log SET target_id = NULL WHERE target_id = p_profile_id;
  UPDATE room_audit_log SET details = '{}'::jsonb
   WHERE details IS NOT NULL
     AND (jsonb_path_exists(CASE WHEN jsonb_typeof(details) = 'object' THEN details - 'role' - 'room_type' ELSE details END,
                            '$.** ? (@ == $v)', jsonb_build_object('v', p_profile_id))
          OR (v_email IS NOT NULL AND strpos(lower(details::text), '"' || lower(v_email) || '"') > 0));
  UPDATE room_members SET invited_by    = NULL WHERE invited_by    = p_profile_id;
  UPDATE room_members SET offboarded_by = NULL WHERE offboarded_by = p_profile_id;

  DELETE FROM connection_requests WHERE from_user = p_profile_id OR to_user = p_profile_id;  -- connection_metrics cascade
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('connection_requests', n);

  DELETE FROM post_reactions WHERE post_id IN (SELECT id FROM assistant_posts WHERE assistant_id = ANY(v_assistants));
  DELETE FROM assistant_profiles WHERE id = ANY(v_assistants);  -- posts cascade
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('assistant_profiles', n);

  UPDATE profile_stats SET viewer_id = NULL WHERE viewer_id = p_profile_id;
  UPDATE search_logs   SET user_id   = NULL WHERE user_id   = p_profile_id;
  DELETE FROM rate_limits WHERE user_id = p_profile_id OR (v_email IS NOT NULL AND lower(user_id) = lower(v_email));

  DELETE FROM mcp_client_sessions
   WHERE (v_email IS NOT NULL AND lower(email) = lower(v_email)) OR (v_auth IS NOT NULL AND user_id = v_auth);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('mcp_sessions', n);
  IF v_email IS NOT NULL THEN
    DELETE FROM mcp_sessions WHERE lower(email) = lower(v_email);  -- old table, the code no longer uses it
    v_hash := encode(extensions.digest(lower(trim(v_email)), 'sha256'), 'hex');
    DELETE FROM email_send_log WHERE recipient_hash = v_hash;
  END IF;

  DELETE FROM profiles WHERE id = p_profile_id;               -- offers, stats, reactions, memberships cascade

  -- last: change history about the person (incl. the copy the delete above just wrote). Per field, for
  -- the 4 tables with audit_trigger_func on live (pg_trigger 2026-11-02), so that a profile named "id"
  -- or "approved" does not take unrelated rows with it. An e-mail cannot collide, so that one stays a search.
  DELETE FROM audit_logs a
   WHERE (a.table_name = 'profiles' AND a.record_id = p_profile_id)
      OR (a.table_name = 'connection_requests' AND p_profile_id IN
            (a.old_data->>'from_user', a.old_data->>'to_user', a.new_data->>'from_user', a.new_data->>'to_user'))
      OR (a.table_name = 'rooms' AND p_profile_id IN (a.old_data->>'owner_id', a.new_data->>'owner_id'))
      OR (a.table_name = 'room_members' AND (p_profile_id IN
            (a.old_data->>'profile_id', a.old_data->>'invited_by', a.old_data->>'offboarded_by',
             a.new_data->>'profile_id', a.new_data->>'invited_by', a.new_data->>'offboarded_by')
          OR a.old_data->>'assistant_profile_id' = ANY(v_assistants::text[])
          OR a.new_data->>'assistant_profile_id' = ANY(v_assistants::text[])))
      OR (v_email IS NOT NULL AND (lower(a.user_email) = lower(v_email)
          OR strpos(lower(coalesce(a.old_data::text, '') || coalesce(a.new_data::text, '')), '"' || lower(v_email) || '"') > 0));
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('audit_logs', n);

  RETURN r || jsonb_build_object('profile', p_profile_id, 'auth_user_id', v_auth,
    'next', 'delete the Supabase Auth user (auth_user_id) in the dashboard and add the profile id to the deleted-accounts list');
END $$;

REVOKE ALL ON FUNCTION public.tb_delete_account(text) FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
