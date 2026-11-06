-- LOCAL ONLY. Assertions AFTER 2026-11-05_connection_mail_no_text.sql. Every line must print PASS.
\set QUIET on
UPDATE profiles SET linkedin_url = 'https://linkedin.example/in/two', preferred_contact = 'PreferredSignal', role = 'Dev <b>' WHERE id = 'user2';
UPDATE profiles SET notifications_enabled = false WHERE id = 'user3';
TRUNCATE test_outbox;
INSERT INTO connection_requests (id, from_user, to_user, message) VALUES
  ('66666666-6666-6666-6666-666666666661', 'owner1', 'user2', 'SECRETMESSAGE <iframe>');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 1 AND (SELECT payload->>'to' FROM test_outbox) = 'user2@example.com', 'request: mail goes to the recipient');
SELECT t_assert((SELECT payload::text NOT LIKE '%SECRETMESSAGE%' AND payload::text NOT LIKE '%iframe%' FROM test_outbox), 'request: NEW.message nowhere in the request to Resend');
SELECT t_assert((SELECT payload->>'html' LIKE '%Owner One%' AND payload->>'subject' LIKE 'Owner One%' FROM test_outbox), 'request: sender name stays');
SELECT t_assert((SELECT payload->>'html' LIKE '%Sprawdź moje requesty%' FROM test_outbox), 'request: how to answer stays');
TRUNCATE test_outbox;
INSERT INTO connection_requests (from_user, to_user, message) VALUES ('owner1', 'unver4', 'x'), ('owner1', 'user3', 'x');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'request: unverified and notifications off get nothing');

TRUNCATE test_outbox;
UPDATE connection_requests SET status = 'accepted', response_message = 'SECRETREPLY <iframe>' WHERE id = '66666666-6666-6666-6666-666666666661';
SELECT t_assert((SELECT count(*) FROM test_outbox) = 2, 'accepted: both sides get a mail');
SELECT t_assert((SELECT bool_and(payload::text NOT LIKE '%SECRETREPLY%' AND payload::text NOT LIKE '%iframe%') FROM test_outbox), 'accepted: NEW.response_message nowhere in either request to Resend');
SELECT t_assert((SELECT payload->>'html' LIKE '%<a href="https://linkedin.example/in/two">%' AND payload->>'html' LIKE '%PreferredSignal%'
                  AND payload->>'html' LIKE '%Dev &lt;b&gt;%' FROM test_outbox WHERE payload->>'to' = 'owner1@example.com'),
  'accepted: LinkedIn, preferred contact and escaped role stay (user decision)');
TRUNCATE test_outbox;
UPDATE profiles SET linkedin_url = 'javascript:alert(1)' WHERE id = 'user2';
INSERT INTO connection_requests (id, from_user, to_user) VALUES ('66666666-6666-6666-6666-666666666662', 'owner1', 'user2');
TRUNCATE test_outbox;
UPDATE connection_requests SET status = 'accepted' WHERE id = '66666666-6666-6666-6666-666666666662';
SELECT t_assert((SELECT payload->>'html' NOT LIKE '%href="javascript%' FROM test_outbox WHERE payload->>'to' = 'owner1@example.com'), 'accepted: non-https LinkedIn is not a link');
TRUNCATE test_outbox;
UPDATE connection_requests SET response_message = 'later' WHERE id = '66666666-6666-6666-6666-666666666662';
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'no second mail without a status change');
SELECT t_assert(NOT has_function_privilege('anon', 'public.notify_connection_request()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.notify_connection_accepted()', 'EXECUTE'), 'API roles still cannot execute');
