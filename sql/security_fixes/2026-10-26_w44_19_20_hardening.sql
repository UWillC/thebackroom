-- ============================================================
-- NOT APPLIED. Apply only after @ciso review PASS + user "pchaj".
-- Apply together with the code on branch fix/w44-19-20 (deploy the code in the same window:
-- the old code inserts profiles as anon and reads `select *`, which this file blocks).
--
-- ROADMAP #19 (rest, slot W44) + #20, S2 audit 2026-10-23 leads 1, 2, 3 + D9 (#3a) + @ciso
-- findings 2026-10-25 (1)-(3) + @cto finding 2026-10-25 (8 other mail functions).
-- Author @cto 2026-10-26. Live state read 2026-10-26 with the read-only MCP; the bodies it
-- replaces are in 2026-10-26_w44_live_snapshot.sql (md5 verified byte-identical on postgres:17).
--
-- WHAT WAS WRONG (live 2026-10-26):
--   a) profiles: policy "Anyone can create profile" WITH CHECK (true) + table-level INSERT,
--      UPDATE, SELECT for anon/authenticated on ALL columns. Anyone with the public key:
--      creates a profile with any e-mail (= mail from hello@ to any address), writes
--      email_verified=true / auth_user_id, reads email + auth_user_id of every profile.
--      Note: the 2026-05-13 column REVOKE on email_verification_token was a no-op, because a
--      column REVOKE does nothing while the table-level grant exists (live check 26.10: anon
--      still has SELECT on that column). This file revokes at table level and re-grants columns.
--   b) resend_verification_email: EXECUTE for PUBLIC/anon, no per-recipient limit (only
--      5 min per profile), returns the profile's e-mail address to any caller.
--   c) 9 other mail functions paste user values raw into HTML (names, role, location,
--      message bodies, subjects, room names, invite token, LinkedIn URL inside href=).
--      notify_room_message and notify_room_member_approved mail unverified addresses.
--      Changing the e-mail of a verified profile kept email_verified=true (no re-verification).
--   d) room_members_insert: self-insert with any status/role, no invitation, re-entry after
--      offboarding possible (#20). Joiners cannot read room_invites (owner-only RLS), so the
--      only working self-join was the unrestricted INSERT.
--
-- WHAT THIS DOES:
--   1. Guard: aborts unless the 10 mail functions still have the md5 read on 2026-10-26.
--   2. New table public.email_send_log (recipient = sha256 of lower(email), no address stored),
--      Data API variant A (service_role only, explicit GRANT: Supabase 2026-10-30 change).
--   3. Helpers (not callable over the API): tb_html, tb_subject, tb_safe_url,
--      tb_email_send_allowed (per-recipient + global limit), tb_can_self_join.
--   4. register_profile(...) SECURITY DEFINER: validation (id regex + reserved ids, name charset
--      and length, field lengths, list sizes, e-mail format, LinkedIn https only), 1 profile per
--      e-mail, global cap 30 new profiles/hour. EXECUTE service_role only (MCP calls it with the
--      service client). email_verified always false, auth_user_id never set by the caller.
--   5. profiles: drop both INSERT policies; REVOKE INSERT/UPDATE/SELECT/DELETE at table level
--      from PUBLIC/anon/authenticated; re-GRANT SELECT on all columns except email,
--      auth_user_id, email_verification_token (anon + authenticated) and UPDATE on the
--      user-editable columns (authenticated only; not name, id, email_verified, token,
--      sent_at, auth_user_id, created_at). DELETE back to authenticated only (policy owner-only).
--      CHECK id format, unique index on lower(email).
--   6. get_email_status(p_profile_id) SECURITY DEFINER: has_email / verified / notifications,
--      no address (replaces the e-mail reads in the MCP tool and the HF Space).
--   7. All 10 mail functions rewritten: every user value through tb_html (subjects through
--      tb_subject), href only for https URLs, id regex before building the link, per-recipient
--      limits, verified-only recipients for room mails, re-verification on e-mail change.
--      resend_verification_email: EXECUTE service_role only (REVOKE from PUBLIC, anon,
--      authenticated), id regex, shared limit with the signup mail, no address in the reply.
--   8. #20: room_members_insert = owner of the room, or self-insert only with status 'pending',
--      role 'member', no offboarding fields, and a valid invitation (tb_can_self_join: token of
--      this room, active, not expired, uses < max_uses, no offboarded/suspended row).
--      join_room_with_invite(...) SECURITY DEFINER for the MCP join flow (authenticated only).
--
-- LIMITS (tune here; scale 2026-10-26 = 1 profile):
--   verification mails (signup + resend + e-mail change): 3 per recipient / 24 h, 30 global / 1 h
--   room invite mails: 3 per recipient / 24 h, 50 global / 1 h (over the limit: invite is
--     created, mail is skipped)
--   other notifications: 20 per recipient / 24 h, 200 global / 1 h (over: mail skipped)
--   new profiles: 30 / 1 h globally
--
-- APPLY ORDER: see sql/README.md "W44" or the @cto report 2026-10-26. This file is one unit.
--   TRANSACTION (@ciso W2): the file has its own BEGIN ... COMMIT, so it is atomic however it
--   is sent (one simple query, statement by statement, or inside an outer transaction of the
--   tool, where BEGIN only warns). Any error before COMMIT = nothing changed. Tested locally in
--   all three modes, plus a forced failure just before COMMIT (sql/tests/run_w44_local.sh).
--   Apply path: supabase-write apply_migration name `w44_19_20_hardening_2026_10_26` with this
--   file's body (or the SQL editor of project ifofgblilanwjhypzvdb, same file as is).
-- VERIFY: 2026-10-26_w44_verify_after_apply.sql (read-only, pg_catalog ACLs) right after.
-- ROLLBACK: 2026-10-26_w44_19_20_hardening_rollback.sql (re-opens every hole above).
-- VERIFIED LOCALLY: sql/tests/run_w44_local.sh (postgres:17, live bodies, stubs for pg_net/auth).
-- @ciso review 2026-10-26 (GO z warunkami): W1 assistant ownership in join_room_with_invite,
--   W6 room_members_delete (no delete of an own offboarded/suspended row), W2 BEGIN/COMMIT.
-- ============================================================

BEGIN;

-- ---------- 1. guard: no drift since the read on 2026-10-26 ----------
DO $guard$
DECLARE r record; cur text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('send_verification_email',               '',                  '02869da99eb42c68ff5a90ec9944ab7e'),
    ('resend_verification_email',             'p_profile_id text', '9b56025c125f7bfe3d4c8d43a8e433ba'),
    ('notify_new_profile',                    '',                  '21618b1f78e7919576ad4081f7c8aed4'),
    ('send_welcome_email_after_verification', '',                  '9ab25e322520397c6843e7771e37de90'),
    ('notify_connection_accepted',            '',                  '39d4ec3bb792565bb4f9ae64fa43b78b'),
    ('notify_connection_request',             '',                  '4622942237534148b90fa4f17dfb1b72'),
    ('notify_room_invite',                    '',                  '6ebef3c7460d1b3e9c07a571190c9403'),
    ('notify_room_member_approved',           '',                  'b495378b3e0111c27aec5d173bb650b7'),
    ('notify_room_message',                   '',                  'a9a305f9d8972bd98495424f358bf027'),
    ('send_weekly_matches_email',             'p_profile_id text', '59a9cd310e543c3bf42c4e2ebfa8ecf5')
  ) AS t(fname, args, md5_before) LOOP
    SELECT md5(pg_get_functiondef(p.oid)) INTO cur FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = r.fname
       AND pg_get_function_identity_arguments(p.oid) = r.args;
    IF cur IS NULL THEN RAISE EXCEPTION 'function %(%) not found', r.fname, r.args; END IF;
    IF cur <> r.md5_before THEN
      RAISE EXCEPTION '% changed since 2026-10-26 (md5 %), aborting: re-read and re-review', r.fname, cur;
    END IF;
  END LOOP;
  IF to_regclass('public.email_send_log') IS NOT NULL
     OR to_regprocedure('public.register_profile(text,text,text,text[],text[],text[],text,text,text[],text,text,text,text,text,text[])') IS NOT NULL THEN
    RAISE EXCEPTION 'w44 objects already exist: migration applied before?';
  END IF;
END $guard$;

-- ---------- 2. send log (Data API variant A: service_role only) ----------
CREATE TABLE public.email_send_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_hash text NOT NULL,          -- sha256(lower(trim(email))), never the address
  kind text NOT NULL CHECK (kind IN ('verification', 'room_invite', 'notification')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX email_send_log_recipient_idx ON public.email_send_log (recipient_hash, kind, created_at);
CREATE INDEX email_send_log_kind_idx ON public.email_send_log (kind, created_at);
ALTER TABLE public.email_send_log ENABLE ROW LEVEL SECURITY;   -- zero policies = deny-all for API roles
REVOKE ALL ON public.email_send_log FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.email_send_log TO service_role;

-- ---------- 3. helpers (internal; EXECUTE revoked from API roles below) ----------
CREATE FUNCTION public.tb_html(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
AS $$ SELECT replace(replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;') $$;

CREATE FUNCTION public.tb_subject(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
AS $$ SELECT left(regexp_replace(coalesce(p, ''), '[[:cntrl:]]+', ' ', 'g'), 150) $$;

-- https only, no quotes/brackets/whitespace; anything else -> NULL (rendered as text, no link)
CREATE FUNCTION public.tb_safe_url(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
AS $$ SELECT CASE WHEN length(p) <= 500 AND p ~ '^https://[^[:space:][:cntrl:]<>"''`]+$' THEN p END $$;

CREATE FUNCTION public.tb_email_send_allowed(p_email text, p_kind text, p_max int,
                                             p_window interval, p_global_per_hour int)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE h text;
BEGIN
  IF p_email IS NULL THEN RETURN false; END IF;
  h := encode(extensions.digest(lower(trim(p_email)), 'sha256'), 'hex');
  -- serialize per recipient so two parallel calls cannot both pass the count
  PERFORM pg_advisory_xact_lock(hashtextextended('tb_mail:' || h, 0));
  DELETE FROM email_send_log WHERE created_at < now() - interval '30 days';
  IF (SELECT count(*) FROM email_send_log
       WHERE recipient_hash = h AND kind = p_kind AND created_at > now() - p_window) >= p_max THEN
    RETURN false;
  END IF;
  IF (SELECT count(*) FROM email_send_log
       WHERE kind = p_kind AND created_at > now() - interval '1 hour') >= p_global_per_hour THEN
    RETURN false;
  END IF;
  INSERT INTO email_send_log (recipient_hash, kind) VALUES (h, p_kind);
  RETURN true;
END $$;

-- #20: may the caller self-insert into p_room_id with this invitation?
CREATE FUNCTION public.tb_can_self_join(p_room_id uuid, p_token text, p_invited_by text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT p_token IS NOT NULL
     AND EXISTS (SELECT 1 FROM room_invites i
                  WHERE i.token = p_token AND i.room_id = p_room_id
                    AND COALESCE(i.is_active, true)
                    AND (i.expires_at IS NULL OR i.expires_at > now())
                    AND COALESCE(i.uses, 0) < COALESCE(i.max_uses, 1)
                    AND (p_invited_by IS NULL OR p_invited_by = i.created_by))
     AND NOT EXISTS (SELECT 1 FROM room_members m
                      WHERE m.room_id = p_room_id AND m.profile_id = get_my_profile_id()
                        AND m.status IN ('offboarded', 'suspended'))
$$;

REVOKE ALL ON FUNCTION public.tb_html(text), public.tb_subject(text), public.tb_safe_url(text),
  public.tb_email_send_allowed(text, text, int, interval, int)
  FROM PUBLIC, anon, authenticated;
-- tb_can_self_join is evaluated inside the room_members policy as the calling role
REVOKE ALL ON FUNCTION public.tb_can_self_join(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tb_can_self_join(uuid, text, text) TO authenticated, service_role;

-- ---------- 4. profiles: constraints, privileges, policies ----------
ALTER TABLE public.profiles ADD CONSTRAINT profiles_id_format CHECK (id ~ '^[a-z0-9_()]{1,100}$');
CREATE UNIQUE INDEX profiles_email_lower_key ON public.profiles (lower(email)) WHERE email IS NOT NULL;

DROP POLICY "Anyone can create profile" ON public.profiles;
DROP POLICY profiles_insert ON public.profiles;   -- inserts only via register_profile / service_role

REVOKE INSERT, UPDATE, SELECT, DELETE, REFERENCES, TRIGGER ON public.profiles FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, name, role, industry, skills, offers, seeks, assistant_endpoint, preferences,
              created_at, updated_at, location, bio, tags, offer_free, offer_condition,
              preferred_contact, linkedin_url, quality_score, quality_feedback, quality_checked_at,
              email_verified, email_verification_sent_at, notifications_enabled)
  ON public.profiles TO anon, authenticated;
GRANT UPDATE (role, industry, skills, offers, seeks, assistant_endpoint, preferences, updated_at,
              location, bio, tags, offer_free, offer_condition, preferred_contact, linkedin_url,
              quality_score, quality_feedback, quality_checked_at, notifications_enabled, email)
  ON public.profiles TO authenticated;
GRANT DELETE ON public.profiles TO authenticated;          -- policy profiles_delete = owner only
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO service_role;

-- ---------- 5. register_profile ----------
CREATE FUNCTION public.register_profile(
  p_id text, p_name text, p_role text, p_skills text[], p_offers text[], p_seeks text[],
  p_location text DEFAULT NULL, p_bio text DEFAULT NULL, p_tags text[] DEFAULT NULL,
  p_offer_free text DEFAULT NULL, p_offer_condition text DEFAULT NULL, p_email text DEFAULT NULL,
  p_linkedin_url text DEFAULT NULL, p_preferred_contact text DEFAULT NULL, p_industry text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_email text := nullif(lower(trim(p_email)), '');
  v_reserved text[] := ARRAY['admin','administrator','root','system','support','help','security',
    'staff','moderator','mod','official','api','null','undefined','backroom','thebackroom','the_backroom'];
  v_item text;
BEGIN
  -- id: same rule as utils/validation.py (validate_profile_id + reserved ids)
  IF p_id IS NULL OR p_id !~ '^[a-z0-9_()]{1,100}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid profile id (a-z, 0-9, _ and () only, max 100).');
  END IF;
  IF btrim(p_id, '_()') = ANY (v_reserved) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This profile id is reserved.');
  END IF;
  -- name: letters, digits, space, - _ ( ) ; no markup, no URLs, no @ (it goes into mails)
  IF p_name IS NULL OR btrim(p_name) = '' OR p_name !~ '^[[:alpha:][:digit:] _()-]{1,100}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid name (letters, digits, spaces, - _ ( ) only, max 100).');
  END IF;
  IF p_role IS NULL OR btrim(p_role) = '' OR length(p_role) > 150 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Role is required (max 150).');
  END IF;
  IF length(p_location) > 200 OR length(p_bio) > 1000 OR length(p_offer_free) > 500
     OR length(p_offer_condition) > 500 OR length(p_preferred_contact) > 200 THEN
    RETURN jsonb_build_object('success', false, 'error', 'A text field is too long.');
  END IF;
  IF coalesce(array_length(p_skills, 1), 0) > 30 OR coalesce(array_length(p_offers, 1), 0) > 20
     OR coalesce(array_length(p_seeks, 1), 0) > 30 OR coalesce(array_length(p_tags, 1), 0) > 20
     OR coalesce(array_length(p_industry, 1), 0) > 20 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Too many list items.');
  END IF;
  FOREACH v_item IN ARRAY coalesce(p_skills, '{}') || coalesce(p_offers, '{}') || coalesce(p_seeks, '{}')
                          || coalesce(p_tags, '{}') || coalesce(p_industry, '{}') LOOP
    IF length(v_item) > 200 THEN
      RETURN jsonb_build_object('success', false, 'error', 'A list item is too long (max 200).');
    END IF;
  END LOOP;
  IF v_email IS NOT NULL AND (length(v_email) > 254 OR v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid e-mail format.');
  END IF;
  IF p_linkedin_url IS NOT NULL AND p_linkedin_url <> '' AND tb_safe_url(p_linkedin_url) IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'LinkedIn URL must be an https:// link.');
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE id = p_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Profile id already exists.');
  END IF;
  IF v_email IS NOT NULL AND EXISTS (SELECT 1 FROM profiles WHERE lower(email) = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'This e-mail already has a profile.');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('tb_register', 0));
  IF (SELECT count(*) FROM profiles WHERE created_at > now() - interval '1 hour') >= 30 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Too many new profiles right now, try again later.');
  END IF;

  BEGIN
    INSERT INTO profiles (id, name, role, skills, offers, seeks, location, bio, tags, offer_free,
                          offer_condition, email, linkedin_url, preferred_contact, industry,
                          email_verified, auth_user_id)
    VALUES (p_id, btrim(p_name), p_role, coalesce(p_skills, '{}'), coalesce(p_offers, '{}'),
            coalesce(p_seeks, '{}'), nullif(p_location, ''), nullif(p_bio, ''), p_tags,
            nullif(p_offer_free, ''), nullif(p_offer_condition, ''), v_email,
            nullif(p_linkedin_url, ''), nullif(p_preferred_contact, ''), p_industry,
            false, NULL);
  EXCEPTION
    WHEN SQLSTATE 'TB429' THEN
      RETURN jsonb_build_object('success', false, 'error', 'Verification e-mail limit reached for this address. Try again tomorrow.');
    WHEN unique_violation THEN
      RETURN jsonb_build_object('success', false, 'error', 'Profile id or e-mail already exists.');
  END;
  RETURN jsonb_build_object('success', true, 'profile_id', p_id, 'verification_sent', v_email IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public.register_profile(text,text,text,text[],text[],text[],text,text,text[],text,text,text,text,text,text[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_profile(text,text,text,text[],text[],text[],text,text,text[],text,text,text,text,text,text[])
  TO service_role;

-- ---------- 6. get_email_status (no address) ----------
CREATE FUNCTION public.get_email_status(p_profile_id text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('found', true, 'profile_id', id, 'name', name,
                               'has_email', email IS NOT NULL,
                               'email_verified', COALESCE(email_verified, false),
                               'notifications_enabled', COALESCE(notifications_enabled, true),
                               'verification_sent', email_verification_sent_at IS NOT NULL)
       FROM profiles WHERE id = p_profile_id),
    jsonb_build_object('found', false))
$$;
REVOKE ALL ON FUNCTION public.get_email_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_email_status(text) TO anon, authenticated, service_role;

-- ---------- 7. mail functions ----------
CREATE OR REPLACE FUNCTION public.send_verification_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    verification_token TEXT;
    verification_link TEXT;
BEGIN
    -- W44: a changed address always needs a new verification
    IF TG_OP = 'UPDATE' AND OLD.email IS DISTINCT FROM NEW.email THEN
        NEW.email_verified := false;
        NEW.email_verification_token := NULL;
    END IF;

    IF NEW.email IS NOT NULL
       AND (NEW.email_verified IS NULL OR NEW.email_verified = false)
       AND (TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.email IS DISTINCT FROM NEW.email))
    THEN
        IF length(NEW.email) > 254 OR NEW.email !~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN
            RAISE EXCEPTION 'Invalid e-mail format' USING ERRCODE = '22023';
        END IF;
        IF NEW.id !~ '^[a-z0-9_()]{1,100}$' THEN
            RAISE EXCEPTION 'Invalid profile id format' USING ERRCODE = '22023';
        END IF;
        IF NOT tb_email_send_allowed(NEW.email, 'verification', 3, interval '24 hours', 30) THEN
            RAISE EXCEPTION 'Verification e-mail limit reached for this address' USING ERRCODE = 'TB429';
        END IF;

        verification_token := gen_random_uuid()::TEXT;
        NEW.email_verification_token := encode(extensions.digest(verification_token, 'sha256'), 'hex');
        NEW.email_verification_sent_at := NOW();
        NEW.email_verified := false;

        verification_link := 'https://huggingface.co/spaces/UWillC/thebackroom?verify=' || verification_token || '&profile=' || NEW.id;

        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', 'Zweryfikuj swój email - The Backroom',
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🔐 Potwierdź swój adres email</h1>

    <p>Cześć <strong>' || tb_html(NEW.name) || '</strong>!</p>

    <p>Aby aktywować powiadomienia email w The Backroom, potwierdź swój adres.</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="margin: 0 0 15px 0;"><strong>Twój kod weryfikacyjny:</strong></p>
        <p style="font-size: 24px; font-family: monospace; background: #EDF2F7; padding: 15px; border-radius: 4px; margin: 0;">
            ' || verification_token || '
        </p>
    </div>

    <p>Lub kliknij link poniżej:</p>
    <p><a href="' || tb_html(verification_link) || '" style="display: inline-block; background: #6B46C1; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Zweryfikuj email</a></p>

    <p style="color: #718096; font-size: 14px;">Link ważny przez 48 godzin.</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        Nie prosiłeś o ten email? Możesz go zignorować.
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resend_verification_email(p_profile_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    profile_record RECORD;
    new_token TEXT;
    verification_link TEXT;
BEGIN
    IF p_profile_id IS NULL OR p_profile_id !~ '^[a-z0-9_()]{1,100}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid profile id');
    END IF;

    SELECT id, name, email, email_verified, email_verification_sent_at
    INTO profile_record
    FROM profiles
    WHERE id = p_profile_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Profile not found');
    END IF;
    IF profile_record.email IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No email address on profile');
    END IF;
    IF profile_record.email_verified = true THEN
        RETURN jsonb_build_object('success', false, 'error', 'Email already verified');
    END IF;
    IF profile_record.email_verification_sent_at IS NOT NULL
       AND NOW() - profile_record.email_verification_sent_at < INTERVAL '5 minutes' THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Please wait 5 minutes before requesting another verification email');
    END IF;
    IF NOT tb_email_send_allowed(profile_record.email, 'verification', 3, interval '24 hours', 30) THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Verification e-mail limit reached for this address. Try again tomorrow.');
    END IF;

    new_token := gen_random_uuid()::TEXT;
    verification_link := 'https://huggingface.co/spaces/UWillC/thebackroom?verify=' || new_token || '&profile=' || p_profile_id;

    UPDATE profiles
    SET email_verification_token = encode(extensions.digest(new_token, 'sha256'), 'hex'),
        email_verification_sent_at = NOW()
    WHERE id = p_profile_id;

    PERFORM net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || public.get_resend_key(),
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
            'from', 'The Backroom <hello@thebackroom.ai>',
            'to', profile_record.email,
            'subject', 'Nowy kod weryfikacyjny - The Backroom',
            'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🔐 Nowy kod weryfikacyjny</h1>

    <p>Cześć <strong>' || tb_html(profile_record.name) || '</strong>!</p>

    <p>Oto Twój nowy kod weryfikacyjny:</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="font-size: 24px; font-family: monospace; background: #EDF2F7; padding: 15px; border-radius: 4px; margin: 0;">
            ' || new_token || '
        </p>
    </div>

    <p><a href="' || tb_html(verification_link) || '" style="display: inline-block; background: #6B46C1; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px;">Zweryfikuj email</a></p>

    <p style="color: #718096; font-size: 14px;">Link ważny przez 48 godzin.</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans
    </p>
</div>
'
        )
    );

    -- W44: no address in the reply (the caller is not necessarily the owner)
    RETURN jsonb_build_object('success', true, 'message', 'Verification email sent to the address on the profile');
END;
$function$;
REVOKE ALL ON FUNCTION public.resend_verification_email(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resend_verification_email(text) TO service_role;

-- not attached to any trigger on 2026-10-26; kept escaped in case it is re-attached
CREATE OR REPLACE FUNCTION public.notify_new_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.email IS NOT NULL AND COALESCE(NEW.email_verified, false) = true
       AND tb_email_send_allowed(NEW.email, 'notification', 20, interval '24 hours', 200) THEN
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', tb_subject('Witaj w The Backroom, ' || NEW.name || '!'),
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
    <h1 style="color: #6B46C1;">🚪 Witaj w The Backroom!</h1>

    <p>Cześć <strong>' || tb_html(NEW.name) || '</strong>!</p>

    <p>Twój profil jest aktywny. Inni członkowie sieci mogą Cię teraz znaleźć.</p>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">📋 Twój profil:</h3>
        <ul style="list-style: none; padding: 0;">
            <li><strong>ID:</strong> ' || tb_html(NEW.id) || '</li>
            <li><strong>Rola:</strong> ' || tb_html(COALESCE(NEW.role, 'Nie podano')) || '</li>
            <li><strong>Lokalizacja:</strong> ' || tb_html(COALESCE(NEW.location, 'Nie podano')) || '</li>
        </ul>
    </div>

    <h3>🚀 Co możesz teraz zrobić?</h3>
    <ol>
        <li><strong>Szukaj:</strong> "Znajdź kogoś kto zna marketing"</li>
        <li><strong>Łącz się:</strong> "Wyślij request do [osoba]"</li>
        <li><strong>Sprawdzaj:</strong> "Moje requesty"</li>
        <li><strong>Dodaj oferty:</strong> "Dodaj ofertę: 15-min call"</li>
    </ol>

    <p>Potrzebujesz pomocy? Powiedz: <code>"Pomoc The Backroom"</code></p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom">GitHub</a>
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.send_welcome_email_after_verification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.email_verified = false
       AND NEW.email_verified = true
       AND COALESCE(NEW.notifications_enabled, true) = true
       AND NEW.email IS NOT NULL
       AND tb_email_send_allowed(NEW.email, 'notification', 20, interval '24 hours', 200)
    THEN
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', tb_subject('Email zweryfikowany - Witaj w The Backroom, ' || NEW.name || '!'),
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
    <h1 style="color: #6B46C1;">✅ Email zweryfikowany!</h1>

    <p>Cześć <strong>' || tb_html(NEW.name) || '</strong>!</p>

    <p>Twój email został zweryfikowany. Będziesz teraz otrzymywać powiadomienia o:</p>
    <ul>
        <li>Nowych connection requests</li>
        <li>Odpowiedziach na Twoje requesty</li>
        <li>Matchach znalezionych przez AI</li>
    </ul>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">📋 Twój profil:</h3>
        <ul style="list-style: none; padding: 0;">
            <li><strong>ID:</strong> ' || tb_html(NEW.id) || '</li>
            <li><strong>Rola:</strong> ' || tb_html(COALESCE(NEW.role, 'Nie podano')) || '</li>
            <li><strong>Lokalizacja:</strong> ' || tb_html(COALESCE(NEW.location, 'Nie podano')) || '</li>
        </ul>
    </div>

    <h3>🚀 Co możesz teraz zrobić?</h3>
    <ol>
        <li><strong>Szukaj:</strong> "Znajdź kogoś kto zna marketing"</li>
        <li><strong>Łącz się:</strong> "Wyślij request do [osoba]"</li>
        <li><strong>Sprawdzaj:</strong> "Moje requesty"</li>
    </ol>

    <p>Potrzebujesz pomocy? Powiedz: <code>"Pomoc The Backroom"</code></p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom">GitHub</a>
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_connection_accepted()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    sender_email TEXT;
    sender_name TEXT;
    sender_verified BOOLEAN;
    sender_notifications BOOLEAN;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_role TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
    recipient_linkedin TEXT;
    recipient_contact TEXT;
    s_name TEXT;   -- escaped copies
    r_name TEXT;
    r_link TEXT;
BEGIN
    IF OLD.status != 'accepted' AND NEW.status = 'accepted' THEN

        SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
        INTO sender_email, sender_name, sender_verified, sender_notifications
        FROM profiles WHERE id = NEW.from_user;

        SELECT email, name, role, email_verified, COALESCE(notifications_enabled, true),
               linkedin_url, preferred_contact
        INTO recipient_email, recipient_name, recipient_role, recipient_verified,
             recipient_notifications, recipient_linkedin, recipient_contact
        FROM profiles WHERE id = NEW.to_user;

        s_name := tb_html(COALESCE(sender_name, ''));
        r_name := tb_html(COALESCE(recipient_name, ''));
        r_link := tb_html(tb_safe_url(recipient_linkedin));

        -- EMAIL 1: to the SENDER (their request was accepted)
        IF sender_email IS NOT NULL
           AND sender_verified = true
           AND sender_notifications = true
           AND tb_email_send_allowed(sender_email, 'notification', 20, interval '24 hours', 200)
        THEN
            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', sender_email,
                    'subject', tb_subject(COALESCE(recipient_name, '') || ' zaakceptował(a) Twój request!'),
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection Accepted!</h1>

    <p>Cześć <strong>' || s_name || '</strong>!</p>

    <p>Świetna wiadomość - <strong>' || r_name || '</strong> zaakceptował(a) Twój connection request!</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;"><strong>Napisz. Krótko się przedstaw. Umówcie się na kawę lub call.</strong></p>
    </div>

    <div style="background: #F7FAFC; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h3 style="margin-top: 0;">Dane kontaktowe:</h3>
        <ul style="list-style: none; padding: 0; margin: 0;">
            <li><strong>Imię:</strong> ' || r_name || '</li>
            <li><strong>Rola:</strong> ' || tb_html(COALESCE(recipient_role, 'Nie podano')) || '</li>
            ' || CASE WHEN r_link IS NOT NULL THEN '
            <li><strong>LinkedIn:</strong> <a href="' || r_link || '">' || r_link || '</a></li>
            ' WHEN recipient_linkedin IS NOT NULL THEN '
            <li><strong>LinkedIn:</strong> ' || tb_html(recipient_linkedin) || '</li>
            ' ELSE '' END || '
            <li><strong>Preferowany kontakt:</strong> ' || tb_html(COALESCE(recipient_contact, 'Nie podano')) || '</li>
        </ul>
    </div>

    ' || CASE WHEN NEW.response_message IS NOT NULL AND NEW.response_message != '' THEN '
    <div style="background: #EBF8FF; padding: 15px; border-radius: 8px; margin: 20px 0;">
        <p style="margin: 0;"><strong>Wiadomość od ' || r_name || ':</strong></p>
        <p style="margin: 10px 0 0 0; font-style: italic;">"' || tb_html(NEW.response_message) || '"</p>
    </div>
    ' ELSE '' END || '

    <h3>Sugerowana pierwsza wiadomość:</h3>
    <div style="background: #FFFAF0; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 14px;">
        Cześć ' || r_name || '!<br><br>
        Dzięki za akceptację w The Backroom.<br>
        [WSTAW: krótko czego szukasz / co oferujesz]<br><br>
        Masz czas na krótki call w tym tygodniu?<br><br>
        Pozdrawiam,<br>
        ' || s_name || '
    </div>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>
</div>
'
                )
            );
        END IF;

        -- EMAIL 2: to the RECIPIENT (confirmation)
        IF recipient_email IS NOT NULL
           AND recipient_verified = true
           AND recipient_notifications = true
           AND tb_email_send_allowed(recipient_email, 'notification', 20, interval '24 hours', 200)
        THEN
            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', recipient_email,
                    'subject', tb_subject('Zaakceptowałeś(aś) request od ' || COALESCE(sender_name, '')),
                    'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #38A169;">Connection nawiązany!</h1>

    <p>Cześć <strong>' || r_name || '</strong>!</p>

    <p>Zaakceptowałeś(aś) connection request od <strong>' || s_name || '</strong>.</p>

    <div style="background: #F0FFF4; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #38A169;">
        <h3 style="margin-top: 0; color: #276749;">Co teraz?</h3>
        <p style="margin-bottom: 0;">' || s_name || ' otrzymał(a) Twoje dane kontaktowe i prawdopodobnie niedługo się odezwie.</p>
    </div>

    <p style="color: #718096;">Jeśli chcesz, możesz też sam(a) napisać pierwszą wiadomość!</p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans
    </p>
</div>
'
                )
            );
        END IF;

    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_connection_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    sender_name TEXT;
    sender_role TEXT;
    recipient_email TEXT;
    recipient_name TEXT;
    recipient_verified BOOLEAN;
    recipient_notifications BOOLEAN;
    s_name TEXT;
BEGIN
    SELECT name, role INTO sender_name, sender_role
    FROM profiles WHERE id = NEW.from_user;

    SELECT email, name, email_verified, COALESCE(notifications_enabled, true)
    INTO recipient_email, recipient_name, recipient_verified, recipient_notifications
    FROM profiles WHERE id = NEW.to_user;

    s_name := tb_html(COALESCE(sender_name, ''));

    IF recipient_email IS NOT NULL
       AND recipient_verified = true
       AND recipient_notifications = true
       AND tb_email_send_allowed(recipient_email, 'notification', 20, interval '24 hours', 200)
    THEN
        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', recipient_email,
                'subject', tb_subject(COALESCE(sender_name, '') || ' chce się z Tobą połączyć!'),
                'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🤝 Nowy Connection Request!</h1>

    <p>Cześć <strong>' || tb_html(COALESCE(recipient_name, '')) || '</strong>!</p>

    <p><strong>' || s_name || '</strong> (' || tb_html(COALESCE(sender_role, 'Członek sieci')) || ') chce się z Tobą połączyć w The Backroom.</p>

    ' || CASE WHEN NEW.message IS NOT NULL AND NEW.message != '' THEN '
    <div style="background: #F7FAFC; padding: 15px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #6B46C1;">
        <p style="margin: 0; font-style: italic;">"' || tb_html(NEW.message) || '"</p>
    </div>
    ' ELSE '' END || '

    <p>Aby odpowiedzieć, powiedz swojemu asystentowi AI:</p>
    <ul>
        <li><code>"Sprawdź moje requesty w The Backroom"</code></li>
        <li><code>"Odpowiedz na request od ' || s_name || '"</code></li>
    </ul>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>

    <p style="color: #A0AEC0; font-size: 12px;">
        Nie chcesz otrzymywać powiadomień? Powiedz: "Wyłącz notyfikacje The Backroom"
    </p>
</div>
'
            )
        );
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_room_invite()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    inviter_name TEXT;
    inviter_email TEXT;
    room_name TEXT;
    room_type TEXT;
    email_html TEXT;
    tok TEXT;
BEGIN
    SELECT r.name, r.room_type INTO room_name, room_type
    FROM rooms r WHERE r.id = NEW.room_id;

    SELECT p.name, p.email INTO inviter_name, inviter_email
    FROM profiles p WHERE p.id = NEW.created_by;

    -- W44: per-recipient limit; over the limit the invite exists but no mail goes out
    IF NEW.email IS NOT NULL
       AND length(NEW.email) <= 254 AND NEW.email ~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'
       AND tb_email_send_allowed(NEW.email, 'room_invite', 3, interval '24 hours', 50)
    THEN
        tok := tb_html(NEW.token);

        email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
        <p style="color: #8B949E; margin-top: 5px;">Where AI assistants connect their humans</p>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <h2 style="color: #F0F6FC; margin-top: 0;">Zaproszenie do pokoju</h2>

        <p><strong style="color: #58A6FF;">' || tb_html(COALESCE(inviter_name, '')) || '</strong> zaprasza Cie do dolaczenia do pokoju:</p>

        <div style="background: #0D1117; padding: 20px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #238636;">
            <h3 style="color: #58A6FF; margin: 0 0 10px 0;">' || tb_html(COALESCE(room_name, '')) || '</h3>
            <p style="color: #8B949E; margin: 0;">Typ: ' ||
                CASE room_type
                    WHEN 'enterprise' THEN 'Enterprise Room (firma)'
                    WHEN 'personal' THEN 'Personal Room (sync asystentow)'
                    ELSE tb_html(COALESCE(room_type, ''))
                END || '</p>
        </div>

        <h3 style="color: #F0F6FC;">Jak dolaczyc?</h3>
        <ol style="color: #C9D1D9; line-height: 1.8;">
            <li>Skopiuj token: <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px; color: #79C0FF;">' || tok || '</code></li>
            <li>Powiedz swojemu asystentowi AI: <em>"Dolacz do pokoju, token: ' || tok || '"</em></li>
            <li>Lub uzyj komendy: <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px;">join_room(token="' || tok || '")</code></li>
        </ol>

        <p style="color: #F85149; font-size: 14px;">Token wazny przez 7 dni (do ' || COALESCE(to_char(NEW.expires_at, 'YYYY-MM-DD HH24:MI'), '-') || ' UTC)</p>
    </div>

    <hr style="border: none; border-top: 1px solid #30363D; margin: 30px 0;">

    <p style="color: #8B949E; font-size: 14px; text-align: center;">
        <a href="https://www.thebackroom.ai" style="color: #58A6FF;">thebackroom.ai</a> |
        <a href="https://huggingface.co/spaces/UWillC/thebackroom" style="color: #58A6FF;">Web UI</a> |
        <a href="https://github.com/UWillC/thebackroom" style="color: #58A6FF;">GitHub</a>
    </p>
</div>';

        PERFORM net.http_post(
            url := 'https://api.resend.com/emails',
            headers := jsonb_build_object(
                'Authorization', 'Bearer ' || public.get_resend_key(),
                'Content-Type', 'application/json'
            ),
            body := jsonb_build_object(
                'from', 'The Backroom <hello@thebackroom.ai>',
                'to', NEW.email,
                'subject', tb_subject('Zaproszenie do ' || COALESCE(room_name, '') || ' - The Backroom'),
                'html', email_html
            )
        );
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_room_member_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    member_email TEXT;
    member_name TEXT;
    member_verified BOOLEAN;
    member_notifications BOOLEAN;
    room_name TEXT;
    room_type TEXT;
    room_slug TEXT;
    email_html TEXT;
BEGIN
    IF OLD.status != 'approved' AND NEW.status = 'approved' THEN

        SELECT p.email, p.name, p.email_verified, COALESCE(p.notifications_enabled, true)
          INTO member_email, member_name, member_verified, member_notifications
        FROM profiles p WHERE p.id = NEW.profile_id;

        SELECT r.name, r.room_type, r.slug INTO room_name, room_type, room_slug
        FROM rooms r WHERE r.id = NEW.room_id;

        -- W44: verified addresses only (before: any address on the profile)
        IF member_email IS NOT NULL AND member_verified = true AND member_notifications = true
           AND tb_email_send_allowed(member_email, 'notification', 20, interval '24 hours', 200) THEN

            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
        <p style="color: #8B949E; margin-top: 5px;">Where AI assistants connect their humans</p>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <div style="text-align: center; margin-bottom: 20px;">
            <span style="font-size: 48px;">&#10004;&#65039;</span>
        </div>

        <h2 style="color: #238636; margin-top: 0; text-align: center;">Gratulacje, ' || tb_html(COALESCE(member_name, '')) || '!</h2>

        <p style="text-align: center;">Twoje czlonkostwo w pokoju <strong style="color: #58A6FF;">' || tb_html(COALESCE(room_name, '')) || '</strong> zostalo zatwierdzone.</p>

        <div style="background: #0D1117; padding: 20px; border-radius: 8px; margin: 20px 0;">
            <h3 style="color: #F0F6FC; margin-top: 0;">Co mozesz teraz robic?</h3>
            <ul style="color: #C9D1D9; line-height: 1.8;">
                <li><strong>Przegladaj czlonkow:</strong> <code>search_in_room(room_slug="' || tb_html(COALESCE(room_slug, '')) || '")</code></li>
                <li><strong>Sprawdz wiadomosci:</strong> <code>check_room_inbox()</code></li>
                <li><strong>Wyslij wiadomosc:</strong> <code>send_room_message(...)</code></li>
            </ul>
        </div>

        <h3 style="color: #F0F6FC;">Checklista na start:</h3>
        <div style="background: #0D1117; padding: 15px; border-radius: 8px;">
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Sprawdz kto jest w pokoju
            </label>
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Przeczytaj wiadomosci powitalne
            </label>
            <label style="display: block; margin: 8px 0; cursor: pointer;">
                <input type="checkbox" disabled> Przedstaw sie zespolowi
            </label>
        </div>
    </div>

    <hr style="border: none; border-top: 1px solid #30363D; margin: 30px 0;">

    <p style="color: #8B949E; font-size: 14px; text-align: center;">
        <a href="https://www.thebackroom.ai" style="color: #58A6FF;">thebackroom.ai</a> |
        <a href="https://huggingface.co/spaces/UWillC/thebackroom" style="color: #58A6FF;">Web UI</a>
    </p>
</div>';

            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', member_email,
                    'subject', tb_subject('Witamy w ' || COALESCE(room_name, '') || '! - The Backroom'),
                    'html', email_html
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_room_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    recipient RECORD;
    sender_name TEXT;
    room_name TEXT;
    email_html TEXT;
BEGIN
    SELECT p.name INTO sender_name
    FROM profiles p WHERE p.id = NEW.from_profile_id;

    SELECT r.name INTO room_name
    FROM rooms r WHERE r.id = NEW.room_id;

    IF NEW.message_type IN ('request', 'reminder') OR NEW.priority IN ('urgent', 'high') THEN

        -- W44: verified addresses only (before: any address on the profile)
        FOR recipient IN
            SELECT p.email, p.name
            FROM message_recipients mr
            JOIN profiles p ON mr.profile_id = p.id
            WHERE mr.message_id = NEW.id
              AND p.email IS NOT NULL
              AND p.email_verified = true
              AND p.notifications_enabled = true
        LOOP
            CONTINUE WHEN NOT tb_email_send_allowed(recipient.email, 'notification', 20, interval '24 hours', 200);

            email_html := '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; background: #0D1117; color: #C9D1D9; padding: 40px; border-radius: 12px;">
    <div style="text-align: center; margin-bottom: 30px;">
        <h1 style="color: #58A6FF; margin: 0;">The Backroom</h1>
    </div>

    <div style="background: #161B22; padding: 30px; border-radius: 8px; border: 1px solid #30363D;">
        <p style="color: #8B949E; margin: 0 0 10px 0;">Nowa wiadomosc w <strong style="color: #58A6FF;">' || tb_html(COALESCE(room_name, '')) || '</strong></p>

        <h2 style="color: #F0F6FC; margin: 0 0 20px 0;">' || tb_html(COALESCE(NEW.subject, '(brak tematu)')) || '</h2>

        <div style="background: #0D1117; padding: 15px; border-radius: 8px; border-left: 4px solid ' ||
            CASE NEW.priority
                WHEN 'urgent' THEN '#F85149'
                WHEN 'high' THEN '#F0883E'
                ELSE '#238636'
            END || ';">
            <p style="margin: 0; color: #C9D1D9;">' || tb_html(COALESCE(NEW.body, '')) || '</p>
        </div>

        <p style="margin-top: 20px; color: #8B949E;">
            Od: <strong>' || tb_html(COALESCE(sender_name, '')) || '</strong><br>
            Typ: ' || tb_html(COALESCE(NEW.message_type, '')) || '<br>
            Priorytet: <span style="color: ' ||
                CASE NEW.priority
                    WHEN 'urgent' THEN '#F85149'
                    WHEN 'high' THEN '#F0883E'
                    ELSE '#C9D1D9'
                END || ';">' || tb_html(COALESCE(NEW.priority, '')) || '</span>' ||
            CASE WHEN NEW.deadline IS NOT NULL
                THEN '<br>Deadline: <strong style="color: #F85149;">' || to_char(NEW.deadline, 'YYYY-MM-DD HH24:MI') || '</strong>'
                ELSE ''
            END || '
        </p>

        <p style="margin-top: 20px;">
            <strong>Odpowiedz:</strong> <code style="background: #0D1117; padding: 4px 8px; border-radius: 4px;">respond_to_room_message(message_id="' || NEW.id || '")</code>
        </p>
    </div>
</div>';

            PERFORM net.http_post(
                url := 'https://api.resend.com/emails',
                headers := jsonb_build_object(
                    'Authorization', 'Bearer ' || public.get_resend_key(),
                    'Content-Type', 'application/json'
                ),
                body := jsonb_build_object(
                    'from', 'The Backroom <hello@thebackroom.ai>',
                    'to', recipient.email,
                    'subject', tb_subject('[' || COALESCE(room_name, '') || '] ' || COALESCE(NEW.subject, 'Nowa wiadomosc')),
                    'html', email_html
                )
            );
        END LOOP;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.send_weekly_matches_email(p_profile_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    profile_record RECORD;
    matches_html TEXT := '';
    match_record RECORD;
    match_count INT := 0;
BEGIN
    SELECT id, name, email, email_verified, COALESCE(notifications_enabled, true) as notifications_enabled
    INTO profile_record
    FROM profiles
    WHERE id = p_profile_id;

    IF profile_record.email IS NULL THEN
        RETURN jsonb_build_object('success', false, 'reason', 'no_email');
    END IF;
    IF NOT COALESCE(profile_record.email_verified, false) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'email_not_verified');
    END IF;
    IF NOT profile_record.notifications_enabled THEN
        RETURN jsonb_build_object('success', false, 'reason', 'notifications_disabled');
    END IF;

    FOR match_record IN
        SELECT * FROM find_profile_matches(p_profile_id, 5)
    LOOP
        match_count := match_count + 1;
        matches_html := matches_html || '
        <div style="background: #F7FAFC; padding: 15px; border-radius: 8px; margin: 10px 0; border-left: 4px solid ' ||
            CASE match_record.match_type
                WHEN 'collaboration' THEN '#38A169'
                WHEN 'can_help_you' THEN '#3182CE'
                WHEN 'you_can_help' THEN '#D69E2E'
                ELSE '#718096'
            END || ';">
            <h3 style="margin: 0 0 5px 0;">' ||
                CASE match_record.match_type
                    WHEN 'collaboration' THEN '🤝 '
                    WHEN 'can_help_you' THEN '🎯 '
                    WHEN 'you_can_help' THEN '💡 '
                    ELSE '🔗 '
                END || tb_html(COALESCE(match_record.matched_name, '')) || '</h3>
            <p style="margin: 0; color: #4A5568;">' || tb_html(COALESCE(match_record.matched_role, '')) || '</p>
            <p style="margin: 5px 0 0 0; color: #718096; font-size: 14px;">📍 ' || tb_html(COALESCE(match_record.matched_location, 'Nie podano')) || '</p>
        </div>';
    END LOOP;

    IF match_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'no_matches', 'profile_id', p_profile_id);
    END IF;
    IF NOT tb_email_send_allowed(profile_record.email, 'notification', 20, interval '24 hours', 200) THEN
        RETURN jsonb_build_object('success', false, 'reason', 'rate_limited', 'profile_id', p_profile_id);
    END IF;

    PERFORM net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || public.get_resend_key(),
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
            'from', 'The Backroom <hello@thebackroom.ai>',
            'to', profile_record.email,
            'subject', '🎯 Znaleźliśmy ' || match_count || ' osób dla Ciebie!',
            'html', '
<div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
    <h1 style="color: #6B46C1;">🎯 Twoje tygodniowe dopasowania!</h1>

    <p>Cześć <strong>' || tb_html(profile_record.name) || '</strong>!</p>

    <p>Przeanalizowaliśmy profile w sieci i znaleźliśmy <strong>' || match_count || ' osób</strong>, które mogą Cię zainteresować:</p>

    ' || matches_html || '

    <div style="background: #EBF8FF; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
        <p style="margin: 0 0 10px 0;"><strong>Chcesz się połączyć?</strong></p>
        <p style="margin: 0;">Powiedz swojemu asystentowi AI:<br>
        <code style="background: #fff; padding: 5px 10px; border-radius: 4px;">"Wyślij request do [imię] w The Backroom"</code></p>
    </div>

    <p style="color: #718096; font-size: 14px;">
        <strong>Legenda:</strong><br>
        🤝 Współpraca (obopólna korzyść)<br>
        🎯 Może Ci pomóc (oferuje co szukasz)<br>
        💡 Możesz pomóc (szuka co oferujesz)
    </p>

    <hr style="border: none; border-top: 1px solid #E2E8F0; margin: 30px 0;">

    <p style="color: #718096; font-size: 14px;">
        <strong>The Backroom</strong> - Where AI assistants connect their humans<br>
        <a href="https://huggingface.co/spaces/UWillC/thebackroom">Otwórz The Backroom</a>
    </p>

    <p style="color: #A0AEC0; font-size: 12px;">
        Nie chcesz otrzymywać tych emaili? Powiedz: "Wyłącz notyfikacje The Backroom"
    </p>
</div>
'
        )
    );

    INSERT INTO profile_stats (profile_id, stat_type, context)
    VALUES (p_profile_id, 'weekly_email_sent', 'matches: ' || match_count);

    RETURN jsonb_build_object(
        'success', true,
        'profile_id', p_profile_id,
        'matches_sent', match_count
    );
END;
$function$;

-- CREATE OR REPLACE keeps the ACL of the nine trigger/service functions (postgres, service_role)

-- ---------- 8. #20 room_members_insert + join_room_with_invite ----------
DROP POLICY room_members_insert ON public.room_members;
CREATE POLICY room_members_insert ON public.room_members FOR INSERT WITH CHECK (
  (EXISTS (SELECT 1 FROM rooms r WHERE r.id = room_members.room_id AND owns_profile(r.owner_id)))
  OR (    profile_id = get_my_profile_id()
      AND status = 'pending'
      AND role = 'member'
      AND joined_at IS NULL AND offboarded_at IS NULL AND offboarded_by IS NULL
      AND offboard_reason IS NULL
      AND tb_can_self_join(room_id, invite_token, invited_by))
);

CREATE FUNCTION public.join_room_with_invite(p_invite_token text, p_profile_id text,
                                             p_assistant_profile_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  inv record; rm record; rm_room record; v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;
  IF p_profile_id IS NULL OR NOT owns_profile(p_profile_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You can only join with your own profile');
  END IF;

  SELECT * INTO inv FROM room_invites
   WHERE token = p_invite_token AND COALESCE(is_active, true)
     AND (expires_at IS NULL OR expires_at > now())
   FOR UPDATE;
  IF NOT FOUND OR COALESCE(inv.uses, 0) >= COALESCE(inv.max_uses, 1) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid or expired invitation token');
  END IF;

  SELECT status INTO v_status FROM room_members
   WHERE room_id = inv.room_id AND profile_id = p_profile_id
   ORDER BY CASE status WHEN 'offboarded' THEN 0 WHEN 'suspended' THEN 1
                        WHEN 'approved' THEN 2 ELSE 3 END
   LIMIT 1;
  IF v_status IN ('offboarded', 'suspended') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Re-joining this room needs the room admin');
  ELSIF v_status = 'approved' THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already a member of this room');
  ELSIF v_status = 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Your join request is pending approval');
  END IF;

  SELECT id, name, room_type INTO rm_room FROM rooms WHERE id = inv.room_id;
  IF p_assistant_profile_id IS NOT NULL AND rm_room.room_type IS DISTINCT FROM 'personal' THEN
    p_assistant_profile_id := NULL;
  END IF;
  -- @ciso W1: assistant uuids are public (assistant_profiles SELECT true); only your own one
  IF p_assistant_profile_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM assistant_profiles a
        WHERE a.id = p_assistant_profile_id AND a.human_profile_id = p_profile_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Assistant profile does not belong to you');
  END IF;

  -- invite_token stays NULL: room_members.invite_token is UNIQUE, a multi-use invite would fail
  INSERT INTO room_members (room_id, profile_id, status, role, invited_by, assistant_profile_id)
  VALUES (inv.room_id, p_profile_id, 'pending', 'member', inv.created_by, p_assistant_profile_id);

  UPDATE room_invites SET uses = COALESCE(uses, 0) + 1 WHERE id = inv.id;

  INSERT INTO room_audit_log (room_id, actor_id, action, details)
  VALUES (inv.room_id, p_profile_id, 'member_joined',
          jsonb_build_object('via_invite', left(p_invite_token, 8) || '...', 'invite_id', inv.id));

  RETURN jsonb_build_object('success', true, 'status', 'pending', 'room_id', rm_room.id,
                            'room_name', rm_room.name, 'room_type', rm_room.room_type);
END $$;
REVOKE ALL ON FUNCTION public.join_room_with_invite(text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_room_with_invite(text, text, uuid) TO authenticated, service_role;

-- @ciso W6: a member could delete the own offboarded/suspended row and re-join through an
-- invitation. Owner keeps full delete; a member may delete (leave) only an active/pending row.
DROP POLICY room_members_delete ON public.room_members;
CREATE POLICY room_members_delete ON public.room_members FOR DELETE USING (
  (EXISTS (SELECT 1 FROM rooms r WHERE r.id = room_members.room_id AND owns_profile(r.owner_id)))
  OR (owns_profile(profile_id) AND status NOT IN ('offboarded', 'suspended')));

COMMIT;
