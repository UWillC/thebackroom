-- LOCAL ONLY. Assertions AFTER 2026-10-26_w44_19_20_hardening.sql. Every line must print PASS.
\set QUIET on
\set A '''00000000-0000-0000-0000-00000000000a'''
\set B '''00000000-0000-0000-0000-00000000000b'''
\set C '''00000000-0000-0000-0000-00000000000c'''

-- ===== #19 profiles: INSERT / SELECT / UPDATE =====
SELECT t_assert(t_run('anon', NULL,
  $$INSERT INTO profiles (id, name, email, email_verified) VALUES ('evil', 'Evil', 'v@example.com', true)$$) LIKE '42501%',
  'anon INSERT profile with email_verified=true -> 42501');
SELECT t_assert(t_run('authenticated', :B,
  $$INSERT INTO profiles (id, name, email) VALUES ('evil2', 'Evil', 'v2@example.com')$$) LIKE '42501%',
  'authenticated INSERT profile -> 42501');
SELECT t_assert(t_run('anon', NULL, $$SELECT email FROM profiles$$) LIKE '42501%', 'anon SELECT email -> 42501');
SELECT t_assert(t_run('anon', NULL, $$SELECT auth_user_id FROM profiles$$) LIKE '42501%', 'anon SELECT auth_user_id -> 42501');
SELECT t_assert(t_run('anon', NULL, $$SELECT email_verification_token FROM profiles$$) LIKE '42501%', 'anon SELECT token -> 42501 (2026-05-13 revoke was a no-op)');
SELECT t_assert(t_run('authenticated', :B, $$SELECT email FROM profiles$$) LIKE '42501%', 'authenticated SELECT email -> 42501');
SELECT t_assert(t_run('anon', NULL, $$SELECT * FROM profiles$$) LIKE '42501%', 'anon SELECT * -> 42501 (code must list columns)');
SELECT t_assert(t_run('anon', NULL,
  $$SELECT id, name, role, bio, email_verified, notifications_enabled, quality_score FROM profiles$$) = 'OK',
  'anon SELECT public columns -> OK');
SELECT t_assert(t_run('anon', NULL, $$UPDATE profiles SET bio = 'x' WHERE id = 'user2'$$) LIKE '42501%', 'anon UPDATE -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET email_verified = true WHERE id = 'unver4'$$) LIKE '42501%',
  'authenticated UPDATE email_verified -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET auth_user_id = NULL WHERE id = 'user2'$$) LIKE '42501%',
  'authenticated UPDATE auth_user_id -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET name = 'X' WHERE id = 'user2'$$) LIKE '42501%',
  'authenticated UPDATE name -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET bio = 'new bio' WHERE id = 'user2'$$) = 'OK', 'owner UPDATE bio runs');
SELECT t_assert((SELECT bio FROM profiles WHERE id = 'user2') = 'new bio',
  'owner UPDATE bio -> row changed (policy on auth_user_id still works with the column revoked)');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET bio = 'hacked' WHERE id = 'owner1'$$) = 'OK', 'foreign UPDATE runs');
SELECT t_assert((SELECT bio FROM profiles WHERE id = 'owner1') IS NULL,
  'UPDATE of someone else''s profile changes 0 rows');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET bio = 'b' WHERE id = 'user2' RETURNING id$$) = 'OK',
  'UPDATE ... RETURNING id -> OK (code uses .select("id"))');

-- e-mail change re-verifies
TRUNCATE test_outbox;
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET email = 'user2.new@example.com' WHERE id = 'user2'$$) = 'OK', 'owner e-mail change runs');
SELECT t_assert((SELECT email_verified FROM profiles WHERE id = 'user2') = false
  AND (SELECT count(*) FROM test_outbox WHERE payload->>'to' = 'user2.new@example.com') = 1,
  'e-mail change -> email_verified=false + 1 verification mail');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET email = 'OWNER1@example.com' WHERE id = 'user2'$$) LIKE '23505%',
  'e-mail of another profile (case-insensitive) -> 23505');
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET email = 'not-an-email' WHERE id = 'user2'$$) LIKE '22023%',
  'invalid e-mail on update -> 22023');
UPDATE profiles SET email = 'user2@example.com' WHERE id = 'user2';
UPDATE profiles SET email_verified = true WHERE id = 'user2';

-- ===== register_profile =====
SELECT t_assert(t_run('anon', NULL, $$SELECT register_profile('a1','Ann','Dev','{}','{}','{}')$$) LIKE '42501%',
  'anon EXECUTE register_profile -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$SELECT register_profile('a1','Ann','Dev','{}','{}','{}')$$) LIKE '42501%',
  'authenticated EXECUTE register_profile -> 42501');
SET ROLE service_role;
SELECT t_assert((register_profile('x"><img', 'X', 'Dev', '{}', '{}', '{}'))->>'success' = 'false', 'id with markup rejected');
SELECT t_assert((register_profile('admin', 'Admin', 'Dev', '{}', '{}', '{}'))->>'success' = 'false', 'reserved id rejected');
SELECT t_assert((register_profile('_admin_', 'Admin', 'Dev', '{}', '{}', '{}'))->>'success' = 'false', 'reserved id with _ rejected');
SELECT t_assert((register_profile('bx', '<b>x</b>', 'Dev', '{}', '{}', '{}'))->>'success' = 'false', 'name with <b> rejected');
SELECT t_assert((register_profile('bx', 'Visit https://evil.example', 'Dev', '{}', '{}', '{}'))->>'success' = 'false', 'name with URL rejected');
SELECT t_assert((register_profile('bx', repeat('a', 101), 'Dev', '{}', '{}', '{}'))->>'success' = 'false', 'name > 100 rejected');
SELECT t_assert((register_profile('bx', 'B X', 'Dev', '{}', '{}', '{}', p_email => 'nope'))->>'success' = 'false', 'bad e-mail rejected');
SELECT t_assert((register_profile('bx', 'B X', 'Dev', '{}', '{}', '{}', p_linkedin_url => 'javascript:alert(1)'))->>'success' = 'false', 'javascript: LinkedIn rejected');
SELECT t_assert((register_profile('bx', 'B X', 'Dev', '{}', '{}', '{}', p_email => 'Owner1@Example.com'))->>'success' = 'false', 'e-mail of an existing profile rejected');
SELECT t_assert((register_profile('bx', 'B X', 'Dev', '{}', '{}', '{}', p_bio => repeat('a', 1001)))->>'success' = 'false', 'bio > 1000 rejected');
SELECT t_assert((register_profile('bx', 'B X', 'Dev', array_fill('s'::text, ARRAY[31]), '{}', '{}'))->>'success' = 'false', '31 skills rejected');
RESET ROLE;
TRUNCATE test_outbox;
SET ROLE service_role;
SELECT t_assert((register_profile('pawel_(x)', 'Paweł (x)', 'Dev', '{a}', '{b}', '{c}', p_email => 'New@Example.com'))->>'success' = 'true',
  'valid registration (Polish letters, parentheses) -> success');
RESET ROLE;
SELECT t_assert((SELECT email_verified = false AND auth_user_id IS NULL AND email = 'new@example.com' FROM profiles WHERE id = 'pawel_(x)'),
  'registered: email_verified=false, auth_user_id NULL, e-mail lower-cased');
SELECT t_assert((SELECT count(*) FROM test_outbox WHERE payload->>'to' = 'new@example.com') = 1, 'registration sends 1 verification mail');
SELECT t_assert((SELECT count(*) FROM email_send_log) >= 1 AND NOT EXISTS (SELECT 1 FROM email_send_log WHERE recipient_hash LIKE '%@%'),
  'send log keeps a hash, not the address');

-- escape in the verification mail (row written directly, as a legacy name would be)
TRUNCATE test_outbox;
INSERT INTO profiles (id, name, role, email) VALUES ('legacy1', '<b>x</b>&"''', 'Dev', 'legacy1@example.com');
SELECT t_assert((SELECT payload->>'html' LIKE '%&lt;b&gt;x&lt;/b&gt;&amp;&quot;&#39;%' AND payload->>'html' NOT LIKE '%<b>x</b>%' FROM test_outbox),
  '<b> in name -> escaped in verification mail');

-- per-recipient limit: 3 verification mails / 24 h
DELETE FROM email_send_log;
UPDATE profiles SET email_verification_sent_at = NULL WHERE id = 'legacy1';
SET ROLE service_role;
SELECT t_assert((resend_verification_email('legacy1'))->>'success' = 'true', 'resend #1 ok');
RESET ROLE;
UPDATE profiles SET email_verification_sent_at = now() - interval '10 minutes' WHERE id = 'legacy1';
SET ROLE service_role;
SELECT t_assert((resend_verification_email('legacy1'))->>'success' = 'true', 'resend #2 ok');
RESET ROLE;
UPDATE profiles SET email_verification_sent_at = now() - interval '10 minutes' WHERE id = 'legacy1';
SET ROLE service_role;
SELECT t_assert((resend_verification_email('legacy1'))->>'success' = 'true', 'resend #3 ok');
RESET ROLE;
UPDATE profiles SET email_verification_sent_at = now() - interval '10 minutes' WHERE id = 'legacy1';
SET ROLE service_role;
SELECT t_assert((resend_verification_email('legacy1'))->>'error' LIKE '%limit%', 'resend #4 within 24 h -> limit');
SELECT t_assert((resend_verification_email('legacy1'))::text NOT LIKE '%@%', 'resend reply carries no address');
SELECT t_assert((resend_verification_email('bad"id'))->>'error' = 'Invalid profile id', 'resend: id regex');
SELECT t_assert((register_profile('lim1', 'Lim', 'Dev', '{}', '{}', '{}', p_email => 'legacy1+x@example.com'))->>'success' = 'true', 'other address not limited');
RESET ROLE;
SELECT t_assert(t_run('anon', NULL, $$SELECT resend_verification_email('legacy1')$$) LIKE '42501%', 'anon EXECUTE resend -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$SELECT resend_verification_email('legacy1')$$) LIKE '42501%', 'authenticated EXECUTE resend -> 42501');
SELECT t_assert(NOT has_function_privilege('public', 'public.resend_verification_email(text)', 'EXECUTE'), 'PUBLIC has no EXECUTE on resend');
-- trigger path over the limit: e-mail update raises TB429
DELETE FROM email_send_log;
INSERT INTO email_send_log (recipient_hash, kind)
  SELECT encode(extensions.digest('limited@example.com', 'sha256'), 'hex'), 'verification' FROM generate_series(1, 3);
SELECT t_assert(t_run('authenticated', :B, $$UPDATE profiles SET email = 'limited@example.com' WHERE id = 'user2'$$) LIKE 'TB429%',
  'e-mail change to a limited address -> TB429');
SET ROLE service_role;
SELECT t_assert((register_profile('lim2', 'Lim Two', 'Dev', '{}', '{}', '{}', p_email => 'limited@example.com'))->>'error' LIKE '%limit%',
  'register_profile to a limited address -> friendly error, no profile');
RESET ROLE;
SELECT t_assert(NOT EXISTS (SELECT 1 FROM profiles WHERE id = 'lim2'), 'no profile row left after limit error');

-- get_email_status
SELECT t_assert(t_run('anon', NULL, $$SELECT get_email_status('user2')$$) = 'OK', 'anon get_email_status -> OK');
SELECT t_assert((get_email_status('user2'))->>'has_email' = 'true' AND (get_email_status('user2'))::text NOT LIKE '%@%',
  'get_email_status: has_email, no address');
SELECT t_assert((get_email_status('nobody'))->>'found' = 'false', 'get_email_status unknown id');

-- helpers / log not reachable over the API
SELECT t_assert(t_run('anon', NULL, $$SELECT tb_html('x')$$) LIKE '42501%', 'anon EXECUTE tb_html -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$SELECT tb_email_send_allowed('a@b.cc','verification',99,'1 day',99)$$) LIKE '42501%',
  'authenticated EXECUTE tb_email_send_allowed -> 42501');
SELECT t_assert(t_run('anon', NULL, $$SELECT * FROM email_send_log$$) LIKE '42501%', 'anon SELECT email_send_log -> 42501');
SELECT t_assert(t_run('authenticated', :B, $$DELETE FROM email_send_log$$) LIKE '42501%', 'authenticated DELETE email_send_log -> 42501');
SELECT t_assert(has_table_privilege('service_role', 'public.email_send_log', 'SELECT'), 'service_role has explicit grant on email_send_log');

-- ===== 8 other mail functions: escape + recipients =====
DELETE FROM email_send_log;
UPDATE profiles SET linkedin_url = 'javascript:alert(1)', preferred_contact = '<script>x</script>' WHERE id = 'owner1';
TRUNCATE test_outbox;
SELECT t_assert(t_run('authenticated', :B,
  $$INSERT INTO connection_requests (id, from_user, to_user, message) VALUES
    ('22222222-2222-2222-2222-222222222222', 'user2', 'owner1', '<img src=x onerror=alert(1)>')$$) = 'OK',
  'connection request insert ok');
SELECT t_assert((SELECT payload->>'html' LIKE '%&lt;img src=x onerror=alert(1)&gt;%' AND payload->>'html' NOT LIKE '%<img%' FROM test_outbox),
  'notify_connection_request: message escaped');
TRUNCATE test_outbox;
SELECT t_assert(t_run('authenticated', :A,
  $$UPDATE connection_requests SET status = 'accepted', response_message = '"><a href=//evil>' WHERE id = '22222222-2222-2222-2222-222222222222'$$) = 'OK',
  'accept ok');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 2, 'notify_connection_accepted: 2 mails');
SELECT t_assert((SELECT bool_and(payload->>'html' NOT LIKE '%javascript:%' OR payload->>'html' NOT LIKE '%href="javascript%') FROM test_outbox)
  AND (SELECT bool_and(payload->>'html' NOT LIKE '%href="javascript%') FROM test_outbox)
  AND (SELECT bool_and(payload->>'html' NOT LIKE '%<script>%' AND payload->>'html' NOT LIKE '%<a href=//evil>%') FROM test_outbox),
  'notify_connection_accepted: no javascript: href, contact + response escaped');
UPDATE profiles SET linkedin_url = 'https://www.linkedin.com/in/owner1', preferred_contact = NULL WHERE id = 'owner1';
UPDATE connection_requests SET status = 'pending' WHERE id = '22222222-2222-2222-2222-222222222222';
TRUNCATE test_outbox;
UPDATE connection_requests SET status = 'accepted' WHERE id = '22222222-2222-2222-2222-222222222222';
SELECT t_assert((SELECT count(*) FROM test_outbox WHERE payload->>'html' LIKE '%href="https://www.linkedin.com/in/owner1"%') = 1,
  'https LinkedIn still rendered as a link');

-- room message: verified only + escaped
INSERT INTO message_recipients VALUES ('33333333-3333-3333-3333-333333333333', 'user2'),
                                      ('33333333-3333-3333-3333-333333333333', 'unver4');
TRUNCATE test_outbox;
INSERT INTO room_messages (id, room_id, from_profile_id, message_type, priority, subject, body)
VALUES ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'owner1', 'request', 'high',
        E'Sub<b>j</b>\r\nBcc: x', '<iframe src=//evil></iframe>');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 1 AND (SELECT payload->>'to' FROM test_outbox) = 'user2@example.com',
  'notify_room_message: unverified recipient skipped');
SELECT t_assert((SELECT payload->>'html' NOT LIKE '%<iframe%' AND payload->>'html' LIKE '%&lt;iframe%'
                    AND payload->>'html' LIKE '%Room &lt;i&gt;R&lt;/i&gt;%' AND payload->>'subject' NOT LIKE E'%\n%' FROM test_outbox),
  'notify_room_message: body, room name escaped; subject without CR/LF');

-- room invite: token escaped + 3 per recipient
TRUNCATE test_outbox;
SELECT t_assert(t_run('authenticated', :A,
  $$INSERT INTO room_invites (room_id, created_by, token, email) VALUES
    ('11111111-1111-1111-1111-111111111111', 'owner1', '"><img src=x>', 'invitee@example.com')$$) = 'OK', 'invite with odd token ok');
SELECT t_assert((SELECT payload->>'html' NOT LIKE '%<img src=x>%' AND payload->>'html' LIKE '%&quot;&gt;&lt;img%' FROM test_outbox),
  'notify_room_invite: token + room name escaped');
INSERT INTO room_invites (room_id, created_by, email) SELECT '11111111-1111-1111-1111-111111111111', 'owner1', 'invitee@example.com'
  FROM generate_series(1, 3);
SELECT t_assert((SELECT count(*) FROM test_outbox WHERE payload->>'to' = 'invitee@example.com') = 3,
  'notify_room_invite: 4th invite to the same address within 24 h -> no mail');

-- member approved: verified only + escaped (user2 verified; unver4 not)
INSERT INTO room_members (room_id, profile_id, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'unver4', 'pending');
TRUNCATE test_outbox;
UPDATE room_members SET status = 'approved' WHERE profile_id = 'unver4';
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'notify_room_member_approved: unverified address skipped');
DELETE FROM room_members WHERE profile_id = 'unver4';

-- welcome + weekly: escaped
TRUNCATE test_outbox;
UPDATE profiles SET email_verified = true WHERE id = 'legacy1';
SELECT t_assert((SELECT count(*) FROM test_outbox) = 1 AND (SELECT payload->>'html' NOT LIKE '%<b>x</b>%' FROM test_outbox),
  'send_welcome_email_after_verification: name escaped');
TRUNCATE test_outbox;
SET ROLE service_role;
SELECT t_assert((send_weekly_matches_email('user2'))->>'success' = 'true', 'weekly mail sent');
RESET ROLE;
SELECT t_assert((SELECT payload->>'html' NOT LIKE '%<b>x</b>%' AND payload->>'html' LIKE '%&lt;b&gt;x%' FROM test_outbox),
  'send_weekly_matches_email: matched name escaped');

-- ===== #20 room_members_insert =====
SELECT t_assert(t_run('authenticated', :B, $$INSERT INTO room_members (room_id, profile_id, role, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2', 'owner', 'approved')$$) LIKE '42501%', 'self-insert approved owner -> denied');
SELECT t_assert(t_run('authenticated', :B, $$INSERT INTO room_members (room_id, profile_id, status, invite_token) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2', 'approved', 'tok1')$$) LIKE '42501%', 'self-insert approved with token -> denied');
SELECT t_assert(t_run('authenticated', :B, $$INSERT INTO room_members (room_id, profile_id) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2')$$) LIKE '42501%', 'self-insert pending without invitation -> denied');
SELECT t_assert(t_run('authenticated', :B, $$INSERT INTO room_members (room_id, profile_id, invite_token) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2', 'tokexp')$$) LIKE '42501%', 'self-insert with expired invitation -> denied');
SELECT t_assert(t_run('authenticated', :B, $$INSERT INTO room_members (room_id, profile_id, invite_token) VALUES
  ('11111111-1111-1111-1111-111111111111', 'owner1', 'tok1')$$) LIKE '42501%', 'insert for someone else''s profile -> denied');
SELECT t_assert(t_run('authenticated', :C, $$INSERT INTO room_members (room_id, profile_id, invite_token, assistant_profile_id) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user3', 'tok1', gen_random_uuid())$$) LIKE '42501%',
  're-entry after offboarding (even with an assistant row) -> denied');
SELECT t_assert(t_run('authenticated', :B, $$INSERT INTO room_members (room_id, profile_id, invite_token) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2', 'tok1')$$) = 'OK', 'self-insert pending member with valid invitation -> OK');
DELETE FROM room_members WHERE profile_id = 'user2';
SELECT t_assert(t_run('authenticated', :A, $$INSERT INTO room_members (room_id, profile_id, role, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2', 'admin', 'approved')$$) = 'OK', 'room owner adds an approved admin -> OK');
DELETE FROM room_members WHERE profile_id = 'user2';

-- join_room_with_invite
SELECT t_assert(t_run('anon', NULL, $$SELECT join_room_with_invite('tok2', 'user2')$$) LIKE '42501%', 'anon join RPC -> 42501');
SET test.uid = '00000000-0000-0000-0000-00000000000b';
SET ROLE authenticated;
SELECT t_assert((join_room_with_invite('tok2', 'owner1'))->>'success' = 'false', 'join with someone else''s profile -> refused');
SELECT t_assert((join_room_with_invite('tokexp', 'user2'))->>'success' = 'false', 'join with expired token -> refused');
SELECT t_assert((join_room_with_invite('nope', 'user2'))->>'success' = 'false', 'join with unknown token -> refused');
SELECT t_assert((join_room_with_invite('tok2', 'user2'))->>'status' = 'pending', 'join with valid token -> pending');
SELECT t_assert((join_room_with_invite('tok2', 'user2'))->>'error' LIKE '%pending%', 'second join -> already pending');
RESET ROLE;
SELECT t_assert((SELECT status = 'pending' AND role = 'member' AND invited_by = 'owner1' FROM room_members WHERE profile_id = 'user2'),
  'joined row = pending member, invited_by = invite creator');
SELECT t_assert((SELECT uses FROM room_invites WHERE token = 'tok2') = 1, 'invite uses incremented');
SELECT t_assert((SELECT count(*) FROM room_audit_log WHERE action = 'member_joined' AND actor_id = 'user2') = 1, 'audit row written');
SET test.uid = '00000000-0000-0000-0000-00000000000c';
SET ROLE authenticated;
SELECT t_assert((join_room_with_invite('tok2', 'user3'))->>'error' LIKE '%admin%', 'offboarded member cannot re-join via RPC');
RESET ROLE;
RESET test.uid;
UPDATE room_invites SET uses = max_uses WHERE token = 'tok1';
SET test.uid = '00000000-0000-0000-0000-00000000000d';
SET ROLE authenticated;
SELECT t_assert((join_room_with_invite('tok1', 'unver4'))->>'success' = 'false', 'used-up invite -> refused');
RESET ROLE;
RESET test.uid;

-- ===== @ciso attacks after review (W1, W6) =====
INSERT INTO rooms (id, name, slug, room_type, owner_id) VALUES
  ('44444444-4444-4444-4444-444444444444', 'Personal P', 'p', 'personal', 'owner1');
INSERT INTO room_invites (room_id, created_by, token, max_uses) VALUES
  ('44444444-4444-4444-4444-444444444444', 'owner1', 'tokp', 5);
INSERT INTO assistant_profiles (id, name, slug, human_profile_id) VALUES
  ('55555555-5555-5555-5555-555555555555', 'Owner bot', 'owner-bot', 'owner1'),
  ('66666666-6666-6666-6666-666666666666', 'User2 bot', 'user2-bot', 'user2');
SET test.uid = '00000000-0000-0000-0000-00000000000b';
SET ROLE authenticated;
SELECT t_assert((join_room_with_invite('tokp', 'user2', '55555555-5555-5555-5555-555555555555'))->>'error'
  = 'Assistant profile does not belong to you', 'W1: attach someone else''s assistant -> refused');
SELECT t_assert((join_room_with_invite('tokp', 'user2', '66666666-6666-6666-6666-666666666666'))->>'status' = 'pending',
  'W1: own assistant -> pending');
RESET ROLE;
RESET test.uid;
SELECT t_assert((SELECT count(*) FROM room_members WHERE room_id = '44444444-4444-4444-4444-444444444444'
  AND assistant_profile_id = '55555555-5555-5555-5555-555555555555') = 0, 'W1: no row with the foreign assistant');
-- W6: offboarded member deletes own row, then re-joins (the @ciso attack)
SELECT t_assert(t_run('authenticated', :C, $$DELETE FROM room_members$$) = 'OK', 'W6: DELETE without WHERE runs');
SELECT t_assert((SELECT count(*) FROM room_members WHERE profile_id = 'user3' AND status = 'offboarded') = 1,
  'W6: own offboarded row survives DELETE');
SET test.uid = '00000000-0000-0000-0000-00000000000c';
SET ROLE authenticated;
SELECT t_assert((join_room_with_invite('tok2', 'user3'))->>'success' = 'false', 'W6: re-join after attempted delete -> refused');
RESET ROLE;
RESET test.uid;
-- an approved member may still leave (a pending one cannot see its own row: SELECT policy, unchanged)
UPDATE room_members SET status = 'approved' WHERE profile_id = 'user2' AND room_id = '44444444-4444-4444-4444-444444444444';
SELECT t_assert(t_run('authenticated', :B, $$DELETE FROM room_members WHERE profile_id = 'user2'
  AND room_id = '44444444-4444-4444-4444-444444444444'$$) = 'OK', 'W6: approved member leave runs');
SELECT t_assert((SELECT count(*) FROM room_members WHERE profile_id = 'user2'
  AND room_id = '44444444-4444-4444-4444-444444444444') = 0, 'W6: approved member can still leave (own row deleted)');
SELECT t_assert(t_run('authenticated', :A, $$DELETE FROM room_members WHERE profile_id = 'user3'$$) = 'OK', 'W6: owner delete runs');
SELECT t_assert((SELECT count(*) FROM room_members WHERE profile_id = 'user3') = 0, 'W6: owner can still delete an offboarded row');
INSERT INTO room_members (room_id, profile_id, role, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user3', 'member', 'offboarded');

-- ===== ACL / definition checks =====
SELECT t_assert((SELECT bool_and(prosecdef) FROM pg_proc WHERE proname IN
  ('register_profile','get_email_status','join_room_with_invite','resend_verification_email','send_verification_email',
   'tb_email_send_allowed','tb_can_self_join')), 'new/changed RPCs are SECURITY DEFINER');
SELECT t_assert((SELECT bool_and(proconfig::text LIKE '%search_path%') FROM pg_proc WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('register_profile','get_email_status','join_room_with_invite','tb_html','tb_subject','tb_safe_url',
  'tb_email_send_allowed','tb_can_self_join','send_verification_email','resend_verification_email','notify_new_profile',
  'send_welcome_email_after_verification','notify_connection_accepted','notify_connection_request','notify_room_invite',
  'notify_room_member_approved','notify_room_message','send_weekly_matches_email')), 'every function pins search_path');
SELECT t_assert(NOT has_function_privilege('anon', 'public.notify_room_message()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.send_weekly_matches_email(text)', 'EXECUTE'),
  'trigger/service mail functions keep their ACL (no anon)');
SELECT t_assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'profiles' AND cmd = 'INSERT'), 'no INSERT policy on profiles');
