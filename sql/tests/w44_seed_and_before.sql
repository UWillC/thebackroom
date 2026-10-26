-- LOCAL ONLY. Seed + proof that the holes exist BEFORE the migration (live state 2026-10-26).
\set QUIET on
INSERT INTO profiles (id, name, role, email, auth_user_id) VALUES
  ('owner1', 'Owner One', 'Owner', 'owner1@example.com', '00000000-0000-0000-0000-00000000000a'),
  ('user2',  'User Two',  'Dev',   'user2@example.com',  '00000000-0000-0000-0000-00000000000b'),
  ('user3',  'User Three','Dev',   'user3@example.com',  '00000000-0000-0000-0000-00000000000c'),
  ('unver4', 'Unverified Four', 'Dev', 'unver4@example.com', '00000000-0000-0000-0000-00000000000d');
UPDATE profiles SET email_verified = true WHERE id IN ('owner1', 'user2', 'user3');
INSERT INTO rooms (id, name, slug, room_type, owner_id) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Room <i>R</i>', 'room-r', 'enterprise', 'owner1');
INSERT INTO room_members (room_id, profile_id, role, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'owner1', 'owner', 'approved'),
  ('11111111-1111-1111-1111-111111111111', 'user3', 'member', 'offboarded');
INSERT INTO room_invites (room_id, created_by, token, max_uses) VALUES
  ('11111111-1111-1111-1111-111111111111', 'owner1', 'tok1', 5),
  ('11111111-1111-1111-1111-111111111111', 'owner1', 'tok2', 5);
INSERT INTO room_invites (room_id, created_by, token, expires_at) VALUES
  ('11111111-1111-1111-1111-111111111111', 'owner1', 'tokexp', now() - interval '1 day');
TRUNCATE test_outbox;

SELECT t_assert(t_run('anon', NULL,
  $$INSERT INTO profiles (id, name, email, email_verified) VALUES ('evil', 'Evil', 'v@example.com', true)$$) = 'OK',
  'BEFORE: anon INSERT with email_verified=true succeeds (hole S2-L1/L2)');
SELECT t_assert(t_run('anon', NULL, $$SELECT email, auth_user_id FROM profiles$$) = 'OK',
  'BEFORE: anon SELECT email/auth_user_id succeeds (hole D9)');
SELECT t_assert(t_run('authenticated', '00000000-0000-0000-0000-00000000000b',
  $$INSERT INTO room_members (room_id, profile_id, role, status) VALUES
    ('11111111-1111-1111-1111-111111111111', 'user2', 'owner', 'approved')$$) = 'OK',
  'BEFORE: authenticated self-insert as approved owner succeeds (hole S2-L3 / #20)');
SELECT t_assert(t_run('anon', NULL, $$SELECT resend_verification_email('owner1')$$) = 'OK',
  'BEFORE: anon may EXECUTE resend_verification_email');
DELETE FROM room_members WHERE profile_id = 'user2';
DELETE FROM profiles WHERE id = 'evil';
TRUNCATE test_outbox;
