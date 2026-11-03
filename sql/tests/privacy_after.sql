-- LOCAL ONLY. Seeds two accounts with everything tied together, then checks retention and
-- tb_delete_account('alice_x'). Prints PASS/FAIL lines.
\set QUIET on
INSERT INTO profiles (id, name, email, auth_user_id) VALUES
  ('alice_x', 'Alice', 'Alice@Example.com', '11111111-1111-1111-1111-111111111111'),
  ('bob_(y)', 'Bob', 'bob@example.com', '22222222-2222-2222-2222-222222222222');
INSERT INTO profile_offers (profile_id, title) VALUES ('alice_x', 'o1'), ('bob_(y)', 'o2');
INSERT INTO assistant_profiles (id, name, human_profile_id) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'A-bot', 'alice_x'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'B-bot', 'bob_(y)');
INSERT INTO assistant_posts (id, assistant_id, content) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f1', 'aaaaaaaa-0000-0000-0000-000000000001', 'alice post'),
  ('bbbbbbbb-0000-0000-0000-0000000000f1', 'bbbbbbbb-0000-0000-0000-000000000001', 'bob post');
INSERT INTO post_reactions (post_id, profile_id) VALUES
  ('aaaaaaaa-0000-0000-0000-0000000000f1', 'bob_(y)'), ('bbbbbbbb-0000-0000-0000-0000000000f1', 'alice_x');
INSERT INTO connection_requests (id, from_user, to_user, message) VALUES
  ('cccccccc-0000-0000-0000-000000000001', 'alice_x', 'bob_(y)', 'hi');
INSERT INTO connection_metrics (request_id) VALUES ('cccccccc-0000-0000-0000-000000000001');
INSERT INTO rooms (id, name, owner_id) VALUES
  ('dddddddd-0000-0000-0000-00000000000a', 'alice room', 'alice_x'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob room', 'bob_(y)');
INSERT INTO room_members (room_id, profile_id, invited_by) VALUES
  ('dddddddd-0000-0000-0000-00000000000a', 'bob_(y)', 'alice_x'),
  ('dddddddd-0000-0000-0000-00000000000b', 'alice_x', 'bob_(y)'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'alice_x');
INSERT INTO room_members (room_id, profile_id, assistant_profile_id) VALUES
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO room_invites (room_id, created_by) VALUES ('dddddddd-0000-0000-0000-00000000000b', 'alice_x');
INSERT INTO room_audit_log (room_id, actor_id, action) VALUES
  ('dddddddd-0000-0000-0000-00000000000b', 'alice_x', 'invite'), ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'approve');
INSERT INTO message_templates (room_id, created_by) VALUES ('dddddddd-0000-0000-0000-00000000000b', 'alice_x');
-- in bob's room: alice writes m1, bob replies m2 (in_reply_to m1), bob writes m3 to alice's assistant
INSERT INTO room_messages (id, room_id, from_profile_id, from_assistant_id, to_profile_id, subject, body) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-00000000000b', 'alice_x', 'aaaaaaaa-0000-0000-0000-000000000001', 'bob_(y)', 's1', 'alice secret');
INSERT INTO room_messages (id, room_id, from_profile_id, to_profile_id, to_assistant_id, in_reply_to, subject, body) VALUES
  ('eeeeeeee-0000-0000-0000-000000000002', 'dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'alice_x', NULL, 'eeeeeeee-0000-0000-0000-000000000001', 's2', 'bob reply'),
  ('eeeeeeee-0000-0000-0000-000000000003', 'dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', NULL, 'aaaaaaaa-0000-0000-0000-000000000001', NULL, 's3', 'bob to bot');
INSERT INTO message_recipients (message_id, profile_id, assistant_profile_id, response_message_id) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001', 'bob_(y)', NULL, 'eeeeeeee-0000-0000-0000-000000000002'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'alice_x', NULL, NULL),
  ('eeeeeeee-0000-0000-0000-000000000003', 'bob_(y)', 'aaaaaaaa-0000-0000-0000-000000000001', NULL);
INSERT INTO profile_stats (profile_id, stat_type, viewer_id, context) VALUES
  ('bob_(y)', 'view', 'alice_x', 'q'), ('alice_x', 'view', 'bob_(y)', 'q');
INSERT INTO search_logs (query, user_id) VALUES ('net', 'alice_x');
INSERT INTO rate_limits (user_id, action_type) VALUES ('alice_x', 'connection_request'), ('bob_(y)', 'connection_request');
INSERT INTO mcp_client_sessions (client_key_hash, email, user_id) VALUES
  ('h1', 'alice@example.com', NULL), ('h2', NULL, '11111111-1111-1111-1111-111111111111'), ('h3', 'bob@example.com', NULL);
INSERT INTO email_send_log (recipient_hash, kind) VALUES
  (encode(extensions.digest('alice@example.com', 'sha256'), 'hex'), 'verification'),
  (encode(extensions.digest('bob@example.com', 'sha256'), 'hex'), 'verification');
UPDATE profiles SET name = 'Alice X' WHERE id = 'alice_x';

-- ---------- retention ----------
INSERT INTO audit_logs (action, table_name, created_at) VALUES ('OLD', 't', now() - interval '91 days'), ('KEEP', 't', now() - interval '89 days');
INSERT INTO search_logs (query, created_at) VALUES ('old', now() - interval '13 months'), ('keep', now() - interval '11 months');
INSERT INTO profile_stats (profile_id, stat_type, created_at) VALUES ('bob_(y)', 'old', now() - interval '13 months'), ('bob_(y)', 'keep', now() - interval '11 months');
INSERT INTO rate_limits (user_id, action_type, created_at) VALUES ('x', 'old', now() - interval '8 days'), ('x', 'keep', now() - interval '6 days');
SELECT CASE WHEN (SELECT count(*) FROM audit_logs WHERE action='OLD') = 0 AND (SELECT count(*) FROM audit_logs WHERE action='KEEP') = 1
  THEN 'PASS' ELSE 'FAIL' END || ' audit_logs: 91-day row deleted on next insert, 89-day row kept';
SELECT CASE WHEN (SELECT count(*) FROM search_logs WHERE query='old') = 0 AND (SELECT count(*) FROM search_logs WHERE query='keep') = 1
  THEN 'PASS' ELSE 'FAIL' END || ' search_logs: 13 months deleted, 11 months kept';
SELECT CASE WHEN (SELECT count(*) FROM profile_stats WHERE stat_type='old') = 0 AND (SELECT count(*) FROM profile_stats WHERE stat_type='keep') = 1
  THEN 'PASS' ELSE 'FAIL' END || ' profile_stats: 13 months deleted, 11 months kept';
SELECT CASE WHEN (SELECT count(*) FROM rate_limits WHERE action_type='old') = 0 AND (SELECT count(*) FROM rate_limits WHERE action_type='keep') = 1
  THEN 'PASS' ELSE 'FAIL' END || ' rate_limits: 8 days deleted, 6 days kept';
-- insert by an API role without DELETE rights still triggers the cleanup (SECURITY DEFINER)
INSERT INTO search_logs (query, created_at) VALUES ('old2', now() - interval '2 years');
SET ROLE anon; INSERT INTO search_logs (query) VALUES ('anon search'); RESET ROLE;
SELECT CASE WHEN (SELECT count(*) FROM search_logs WHERE query='old2') = 0 THEN 'PASS' ELSE 'FAIL' END || ' cleanup runs when anon inserts (no DELETE grant for anon)';

-- ---------- tb_delete_account permissions ----------
SELECT CASE WHEN NOT has_function_privilege('service_role', 'public.tb_delete_account(text)', 'EXECUTE')
             AND NOT has_function_privilege('anon', 'public.tb_delete_account(text)', 'EXECUTE')
             AND NOT has_function_privilege('authenticated', 'public.tb_delete_account(text)', 'EXECUTE')
  THEN 'PASS' ELSE 'FAIL' END || ' tb_delete_account not executable by anon/authenticated/service_role';
DO $$ BEGIN PERFORM tb_delete_account('Bad Id;'); RAISE NOTICE 'FAIL invalid id accepted';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'PASS invalid id rejected'; END $$;
DO $$ BEGIN DELETE FROM profiles WHERE id = 'alice_x'; RAISE NOTICE 'FAIL plain DELETE of profile passed (FKs expected to block)';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'PASS plain DELETE of profile is blocked by FKs (the reason for the runbook)'; END $$;

-- ---------- tb_delete_account('alice_x') ----------
SELECT 'INFO result ' || tb_delete_account('alice_x')::text;
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM profiles WHERE id='alice_x') AND EXISTS (SELECT 1 FROM profiles WHERE id='bob_(y)')
  THEN 'PASS' ELSE 'FAIL' END || ' profile alice deleted, bob kept';
SELECT CASE WHEN (SELECT count(*) FROM profile_offers) = 1 AND (SELECT count(*) FROM assistant_profiles) = 1 AND (SELECT count(*) FROM assistant_posts) = 1
  THEN 'PASS' ELSE 'FAIL' END || ' offers, assistant and posts of alice gone, bob''s kept';
SELECT CASE WHEN (SELECT count(*) FROM post_reactions) = 0 AND (SELECT reactions_count FROM assistant_posts) = -1 + 1
  THEN 'PASS' ELSE 'FAIL' END || ' reactions by/on alice gone, bob''s post counter back to 0';
SELECT CASE WHEN (SELECT count(*) FROM connection_requests) = 0 AND (SELECT count(*) FROM connection_metrics) = 0
  THEN 'PASS' ELSE 'FAIL' END || ' connection request + metrics gone';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM rooms WHERE owner_id='alice_x') AND EXISTS (SELECT 1 FROM rooms WHERE name='bob room')
  THEN 'PASS' ELSE 'FAIL' END || ' alice room gone, bob room kept';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM room_members WHERE profile_id='alice_x' OR invited_by='alice_x' OR assistant_profile_id='aaaaaaaa-0000-0000-0000-000000000001')
             AND EXISTS (SELECT 1 FROM room_members WHERE profile_id='bob_(y)' AND room_id='dddddddd-0000-0000-0000-00000000000b')
  THEN 'PASS' ELSE 'FAIL' END || ' memberships of alice gone, invited_by cleared, bob membership kept';
SELECT CASE WHEN (SELECT count(*) FROM room_invites) = 0 AND (SELECT count(*) FROM room_audit_log) = 1 AND (SELECT count(*) FROM message_templates) = 0
  THEN 'PASS' ELSE 'FAIL' END || ' invites/templates by alice gone, room log only bob''s action left';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM room_messages WHERE body='alice secret')
             AND (SELECT in_reply_to FROM room_messages WHERE body='bob reply') IS NULL
             AND (SELECT to_profile_id FROM room_messages WHERE body='bob reply') IS NULL
             AND (SELECT to_assistant_id FROM room_messages WHERE body='bob to bot') IS NULL
  THEN 'PASS' ELSE 'FAIL' END || ' alice''s message deleted; bob''s messages kept without links to alice';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM message_recipients WHERE profile_id='alice_x')
             AND (SELECT assistant_profile_id FROM message_recipients WHERE message_id='eeeeeeee-0000-0000-0000-000000000003') IS NULL
  THEN 'PASS' ELSE 'FAIL' END || ' recipient rows of alice gone, assistant link cleared';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM profile_stats WHERE viewer_id='alice_x' OR profile_id='alice_x')
             AND NOT EXISTS (SELECT 1 FROM search_logs WHERE user_id='alice_x')
             AND NOT EXISTS (SELECT 1 FROM rate_limits WHERE user_id='alice_x') AND EXISTS (SELECT 1 FROM rate_limits WHERE user_id='bob_(y)')
  THEN 'PASS' ELSE 'FAIL' END || ' stats/search/rate limits: no trace of alice, bob kept';
SELECT CASE WHEN (SELECT count(*) FROM mcp_client_sessions) = 1 AND (SELECT count(*) FROM email_send_log) = 1
  THEN 'PASS' ELSE 'FAIL' END || ' MCP sessions (by e-mail and by auth id) and mail-log hash of alice gone, bob''s kept';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM audit_logs WHERE strpos(coalesce(old_data::text,'')||coalesce(new_data::text,''), 'alice_x') > 0
                                OR strpos(lower(coalesce(old_data::text,'')||coalesce(new_data::text,'')), 'alice@example.com') > 0
                                OR record_id = 'alice_x')
             AND EXISTS (SELECT 1 FROM audit_logs WHERE record_id='bob_(y)')
  THEN 'PASS' ELSE 'FAIL' END || ' audit_logs: no copy of alice left (incl. the delete itself), bob''s history kept';
DO $$ BEGIN PERFORM tb_delete_account('alice_x'); RAISE NOTICE 'FAIL second call accepted';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'PASS second call: profile not found'; END $$;

-- ---------- @ciso W1: a profile id equal to a JSON key or value must not wipe unrelated history ----------
-- ids come from display names (utils/validation.py) and 'id', 'approved', 'status', 'email', 'name' are not reserved
INSERT INTO connection_requests (from_user, to_user, status) SELECT 'bob_(y)', 'bob_(y)', 'approved';
INSERT INTO room_members (room_id, profile_id, status) VALUES ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'approved');
UPDATE profiles SET name = 'Bob Y' WHERE id = 'bob_(y)';
INSERT INTO audit_logs (action, table_name, record_id, new_data) VALUES
  ('INSERT', 'rooms', 'dddddddd-0000-0000-0000-00000000000b', '{"owner_id": "bob_(y)", "id": "x", "approved": true}');
INSERT INTO profiles (id, name, email) VALUES ('id', 'Id', 'id-owner@example.com'), ('approved', 'Approved', 'approved-owner@example.com');
CREATE TEMP TABLE w1_unrelated AS SELECT id FROM audit_logs WHERE record_id NOT IN ('id', 'approved');
SELECT CASE WHEN (SELECT count(*) FROM w1_unrelated) >= 4 THEN 'PASS' ELSE 'FAIL' END || ' W1 setup: unrelated history present before the deletes';
SELECT 'INFO W1 ' || tb_delete_account('id')::text;
SELECT CASE WHEN (SELECT count(*) FROM w1_unrelated u JOIN audit_logs a USING (id)) = (SELECT count(*) FROM w1_unrelated)
  THEN 'PASS' ELSE 'FAIL' END || ' W1 profile "id" (equal to a JSON key): unrelated history untouched';
SELECT 'INFO W1 ' || tb_delete_account('approved')::text;
SELECT CASE WHEN (SELECT count(*) FROM w1_unrelated u JOIN audit_logs a USING (id)) = (SELECT count(*) FROM w1_unrelated)
  THEN 'PASS' ELSE 'FAIL' END || ' W1 profile "approved" (equal to a JSON value): unrelated history untouched';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM audit_logs WHERE record_id IN ('id', 'approved'))
  THEN 'PASS' ELSE 'FAIL' END || ' W1 own history of "id" and "approved" gone';

-- the narrower match must still remove every table's rows that really are about the person
INSERT INTO profiles (id, name, email) VALUES ('carol_z', 'Carol', 'carol@example.com');
INSERT INTO assistant_profiles (id, name, human_profile_id) VALUES ('cccccccc-0000-0000-0000-0000000000a1', 'C-bot', 'carol_z');
INSERT INTO connection_requests (from_user, to_user) VALUES ('carol_z', 'bob_(y)'), ('bob_(y)', 'carol_z');
INSERT INTO rooms (id, name, owner_id) VALUES ('dddddddd-0000-0000-0000-00000000000c', 'carol room', 'carol_z');
INSERT INTO room_members (room_id, profile_id, invited_by, offboarded_by, assistant_profile_id) VALUES
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'carol_z', NULL, NULL),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', NULL, 'carol_z', NULL),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', NULL, NULL, 'cccccccc-0000-0000-0000-0000000000a1');
INSERT INTO audit_logs (action, table_name, record_id, user_email) VALUES ('UPDATE', 'other', 'r1', 'CAROL@example.com');
INSERT INTO audit_logs (action, table_name, record_id, new_data) VALUES ('UPDATE', 'other', 'r2', '{"contact": "carol@example.com"}');
SELECT 'INFO W1 ' || tb_delete_account('carol_z')::text;
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM audit_logs WHERE strpos(coalesce(old_data::text,'')||coalesce(new_data::text,''), 'carol_z') > 0 OR record_id = 'carol_z')
  THEN 'PASS' ELSE 'FAIL' END || ' W1 no audit row of any table carries the deleted id';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM audit_logs WHERE strpos(coalesce(old_data::text,'')||coalesce(new_data::text,''), 'cccccccc-0000-0000-0000-0000000000a1') > 0)
  THEN 'PASS' ELSE 'FAIL' END || ' W1 no audit row carries the deleted person''s assistant id';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM audit_logs WHERE lower(user_email) = 'carol@example.com' OR strpos(lower(coalesce(new_data::text,'')), 'carol@example.com') > 0)
  THEN 'PASS' ELSE 'FAIL' END || ' W1 no audit row carries the deleted e-mail (column or JSON, any case)';

-- ---------- @ciso W2: no id or e-mail of the deleted person in room_invites, room_audit_log, mcp_sessions ----------
INSERT INTO profiles (id, name, email) VALUES ('dave_w', 'Dave', 'Dave@Example.com'), ('member', 'Member', 'member-owner@example.com');
INSERT INTO room_invites (room_id, created_by, email) VALUES
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'dave@example.com'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'someone-else@example.com');
INSERT INTO room_audit_log (room_id, actor_id, action, target_id, details) VALUES
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'w2-target', 'dave_w', '{"role": "member"}'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'w2-mail', NULL, '{"max_uses": 1, "note": null, "email": "DAVE@example.com"}'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'w2-nested', NULL, '{"a": {"who": ["dave_w"]}}'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'w2-other', 'bob_(y)', '{"role": "member"}'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'w2-other-mail', NULL, '{"email": "someone-else@example.com"}'),
  ('dddddddd-0000-0000-0000-00000000000b', 'bob_(y)', 'w2-scalar', NULL, '1'),
  ('dddddddd-0000-0000-0000-00000000000b', 'dave_w', 'w2-actor', 'bob_(y)', '{}');
INSERT INTO mcp_sessions (email, session) VALUES ('dave@example.com', '{"t": 1}'), ('bob@example.com', '{"t": 2}');
SELECT 'INFO W2 ' || tb_delete_account('dave_w')::text;
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM room_invites WHERE lower(email) = 'dave@example.com') AND EXISTS (SELECT 1 FROM room_invites WHERE email = 'someone-else@example.com')
  THEN 'PASS' ELSE 'FAIL' END || ' W2 invite addressed to the person gone, someone else''s kept';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM room_audit_log WHERE target_id = 'dave_w' OR actor_id = 'dave_w')
              AND (SELECT target_id IS NULL AND details = '{"role": "member"}' FROM room_audit_log WHERE action = 'w2-target')
  THEN 'PASS' ELSE 'FAIL' END || ' W2 room log: target_id cleared, own entries gone, the entry of the other actor stays';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM room_audit_log WHERE strpos(lower(details::text), 'dave') > 0)
              AND (SELECT details = '{}' FROM room_audit_log WHERE action = 'w2-mail')
              AND (SELECT details = '{}' FROM room_audit_log WHERE action = 'w2-nested')
  THEN 'PASS' ELSE 'FAIL' END || ' W2 room log: e-mail (invite_created, any case) and nested id gone from details, entries stay';
SELECT CASE WHEN (SELECT details = '{"role": "member"}' AND target_id = 'bob_(y)' FROM room_audit_log WHERE action = 'w2-other')
              AND (SELECT details = '{"email": "someone-else@example.com"}' FROM room_audit_log WHERE action = 'w2-other-mail')
  THEN 'PASS' ELSE 'FAIL' END || ' W2 room log: entries about others untouched';
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM mcp_sessions WHERE email = 'dave@example.com') AND EXISTS (SELECT 1 FROM mcp_sessions WHERE email = 'bob@example.com')
  THEN 'PASS' ELSE 'FAIL' END || ' W2 old mcp_sessions row of the person gone, bob''s kept';
-- same trap as W1 inside details: a profile named like the value of a role must not clear other people's entries
SELECT 'INFO W2 ' || tb_delete_account('member')::text;
SELECT CASE WHEN (SELECT details = '{"role": "member"}' FROM room_audit_log WHERE action = 'w2-other')
  THEN 'PASS' ELSE 'FAIL' END || ' W2 profile "member" (equal to a role value): details of other entries untouched';
