-- LOCAL ONLY. Live ACLs + triggers of 2026-10-26 on top of the snapshot bodies.
REVOKE ALL ON FUNCTION public.send_verification_email(), public.notify_new_profile(),
  public.send_welcome_email_after_verification(), public.notify_connection_accepted(),
  public.notify_connection_request(), public.notify_room_invite(), public.notify_room_member_approved(),
  public.notify_room_message(), public.send_weekly_matches_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_verification_email(), public.notify_new_profile(),
  public.send_welcome_email_after_verification(), public.notify_connection_accepted(),
  public.notify_connection_request(), public.notify_room_invite(), public.notify_room_member_approved(),
  public.notify_room_message(), public.send_weekly_matches_email(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.resend_verification_email(text) TO anon, authenticated, service_role;

CREATE TRIGGER on_profile_email_change BEFORE INSERT OR UPDATE OF email ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION send_verification_email();
CREATE TRIGGER on_email_verified AFTER UPDATE OF email_verified ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION send_welcome_email_after_verification();
CREATE TRIGGER on_room_invite_created AFTER INSERT ON public.room_invites
  FOR EACH ROW WHEN (new.email IS NOT NULL) EXECUTE FUNCTION notify_room_invite();
CREATE TRIGGER on_room_member_approved AFTER UPDATE ON public.room_members FOR EACH ROW
  WHEN ((old.status IS DISTINCT FROM new.status) AND (new.status = 'approved')) EXECUTE FUNCTION notify_room_member_approved();
CREATE TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages FOR EACH ROW
  WHEN ((new.message_type = ANY (ARRAY['request','reminder'])) OR (new.priority = ANY (ARRAY['urgent','high'])))
  EXECUTE FUNCTION notify_room_message();
CREATE TRIGGER on_new_connection_request AFTER INSERT ON public.connection_requests
  FOR EACH ROW EXECUTE FUNCTION notify_connection_request();
CREATE TRIGGER on_connection_accepted AFTER UPDATE OF status ON public.connection_requests
  FOR EACH ROW EXECUTE FUNCTION notify_connection_accepted();

-- test runner: run p_sql as p_role with auth.uid() = p_uid, return 'OK' or 'SQLSTATE: message'
CREATE FUNCTION public.t_run(p_role text, p_uid text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM set_config('test.uid', coalesce(p_uid, ''), true);
    PERFORM set_config('role', p_role, true);
    EXECUTE p_sql;
    PERFORM set_config('role', 'postgres', true);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
  END;
END $$;
CREATE FUNCTION public.t_assert(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN RAISE NOTICE 'PASS %', p_label; ELSE RAISE EXCEPTION 'FAIL %', p_label; END IF;
END $$;
