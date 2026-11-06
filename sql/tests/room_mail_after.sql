-- LOCAL ONLY. Assertions AFTER 2026-11-05_room_mail_no_content.sql. Every line must print PASS.
\set QUIET on
\set ROOM '''11111111-1111-1111-1111-111111111111'''
\set M1 '''44444444-4444-4444-4444-444444444441'''
\set M2 '''44444444-4444-4444-4444-444444444442'''
\set M3 '''44444444-4444-4444-4444-444444444443'''

-- content, recipients: verified + notifications on only
UPDATE profiles SET notifications_enabled = false WHERE id = 'user3';
INSERT INTO message_recipients VALUES (:M1, 'user2'), (:M1, 'unver4'), (:M1, 'user3');
TRUNCATE test_outbox;
INSERT INTO room_messages (id, room_id, from_profile_id, message_type, priority, subject, body, deadline)
VALUES (:M1, :ROOM, 'owner1', 'request', 'urgent', E'SECRETSUBJECT\r\nBcc: x', 'SECRETBODY <iframe>', '2031-02-03 04:05+00');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 1 AND (SELECT payload->>'to' FROM test_outbox) = 'user2@example.com',
  'recipients: verified with notifications on get it; unverified and notifications off do not');
SELECT t_assert((SELECT payload::text NOT LIKE '%SECRETSUBJECT%' AND payload::text NOT LIKE '%Bcc%' FROM test_outbox),
  'message subject nowhere in the request to Resend');
SELECT t_assert((SELECT payload::text NOT LIKE '%SECRETBODY%' AND payload::text NOT LIKE '%iframe%' FROM test_outbox),
  'message body nowhere in the request to Resend');
SELECT t_assert((SELECT payload::text NOT LIKE '%Owner One%' AND payload::text NOT LIKE '%2031%'
                    AND payload::text NOT LIKE '%urgent%' AND payload::text NOT LIKE '%' || :M1 || '%' FROM test_outbox),
  'sender, deadline, priority and message id nowhere in the request to Resend');
SELECT t_assert((SELECT payload->>'html' LIKE '%You have a new message in room <strong style="color: #58A6FF;">Room &lt;i&gt;R&lt;/i&gt;</strong>%'
                    AND payload->>'html' NOT LIKE '%<i>R%' FROM test_outbox),
  'sentence present, room name escaped in HTML');
SELECT t_assert((SELECT payload->>'html' LIKE '%<a href="https://www.thebackroom.ai"%' FROM test_outbox), 'link present');
SELECT t_assert((SELECT payload->>'subject' = 'You have a new message in room Room <i>R</i>' FROM test_outbox),
  'mail subject = fixed sentence + room name (plain text)');
SELECT t_assert((SELECT payload->>'from' = 'The Backroom <hello@thebackroom.ai>' FROM test_outbox), 'sender address unchanged');

-- CR/LF in a room name cannot inject a header
UPDATE rooms SET name = E'Room\r\nBcc: evil@example.com' WHERE id = :ROOM;
INSERT INTO message_recipients VALUES (:M2, 'user2');
TRUNCATE test_outbox;
INSERT INTO room_messages (id, room_id, from_profile_id, message_type, priority, subject, body)
VALUES (:M2, :ROOM, 'owner1', 'reminder', 'normal', 's', 'b');
SELECT t_assert((SELECT payload->>'subject' !~ E'[\\r\\n]' FROM test_outbox), 'reminder is mailed; CR/LF in room name stripped from mail subject');
UPDATE rooms SET name = 'Room <i>R</i>' WHERE id = :ROOM;

-- which messages mail at all
INSERT INTO message_recipients VALUES (:M3, 'user2');
TRUNCATE test_outbox;
INSERT INTO room_messages (id, room_id, from_profile_id, message_type, priority, subject, body)
VALUES (:M3, :ROOM, 'owner1', 'info', 'normal', 's', 'b');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'info + normal: no mail (trigger condition unchanged)');

-- send limit: 20 per recipient per 24 h
TRUNCATE test_outbox;
DELETE FROM email_send_log;
DO $$
DECLARE i int; m uuid;
BEGIN
  FOR i IN 1..21 LOOP
    m := gen_random_uuid();
    INSERT INTO message_recipients VALUES (m, 'user2');
    INSERT INTO room_messages (id, room_id, from_profile_id, message_type, priority, subject, body)
    VALUES (m, '11111111-1111-1111-1111-111111111111', 'owner1', 'request', 'normal', 's', 'b');
  END LOOP;
END $$;
SELECT t_assert((SELECT count(*) FROM test_outbox) = 20, 'send limit still stops the 21st mail');

-- privileges and wiring
SELECT t_assert(NOT has_function_privilege('anon', 'public.notify_room_message()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.notify_room_message()', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.notify_room_message()', 'EXECUTE'), 'ACL unchanged');
SELECT t_assert((SELECT prosecdef FROM pg_proc WHERE oid = 'public.notify_room_message()'::regprocedure), 'still security definer');

-- FOUND 2026-11-05, behaviour NOT changed by this migration: production send_room_message inserts the
-- message first and the recipients after it. The trigger fires between the two, sees no recipient, sends nothing.
DELETE FROM email_send_log;
TRUNCATE test_outbox;
DO $$
DECLARE m uuid;
BEGIN
  INSERT INTO room_messages (room_id, from_profile_id, message_type, priority, subject, body)
  VALUES ('11111111-1111-1111-1111-111111111111', 'owner1', 'request', 'urgent', 's', 'b') RETURNING id INTO m;
  INSERT INTO message_recipients VALUES (m, 'user2');
END $$;
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'send_room_message order (message, then recipients): 0 mails');
BEGIN;
ALTER TABLE message_recipients ADD CONSTRAINT t_fk FOREIGN KEY (message_id) REFERENCES room_messages(id) NOT VALID;
SELECT t_assert(t_run('postgres', NULL, $$INSERT INTO message_recipients VALUES (gen_random_uuid(), 'user2')$$) LIKE '23503%',
  'with the production foreign key a recipient cannot exist before its message');
ROLLBACK;
