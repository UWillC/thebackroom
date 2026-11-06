-- LOCAL ONLY (@ciso W4). Real production send_room_message / respond_to_message on production columns and
-- foreign keys. If someone fixes the order so these functions start mailing, the "0 mails" lines fail,
-- and the policy sentence "We do not send e-mail when a message is sent to you in a room" must change too.
\set QUIET on
DROP TABLE public.message_recipients, public.room_messages;
CREATE TABLE public.room_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.rooms(id) ON DELETE CASCADE,
  from_profile_id text NOT NULL REFERENCES public.profiles(id), from_assistant_name text,
  to_profile_id text REFERENCES public.profiles(id), to_role text,
  message_type text NOT NULL CHECK (message_type = ANY (ARRAY['info','reminder','request','response','announcement'])),
  subject text NOT NULL, body text NOT NULL, template jsonb, expected_format text, deadline timestamptz,
  in_reply_to uuid REFERENCES public.room_messages(id),
  priority text DEFAULT 'normal' CHECK (priority = ANY (ARRAY['low','normal','high','urgent'])),
  status text DEFAULT 'sent' CHECK (status = ANY (ARRAY['draft','sent','cancelled'])),
  created_at timestamptz DEFAULT now(), sent_at timestamptz DEFAULT now(),
  from_assistant_id uuid REFERENCES public.assistant_profiles(id),
  to_assistant_id uuid REFERENCES public.assistant_profiles(id));
CREATE TABLE public.message_recipients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.room_messages(id) ON DELETE CASCADE,
  profile_id text NOT NULL REFERENCES public.profiles(id),
  status text DEFAULT 'unread' CHECK (status = ANY (ARRAY['unread','read','acknowledged','responded','ignored'])),
  delivered_at timestamptz DEFAULT now(), read_at timestamptz, acknowledged_at timestamptz, responded_at timestamptz,
  response_message_id uuid REFERENCES public.room_messages(id),
  assistant_profile_id uuid REFERENCES public.assistant_profiles(id),
  CONSTRAINT uq_message_recipients_msg_profile_assistant UNIQUE (message_id, profile_id, assistant_profile_id));
CREATE TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages FOR EACH ROW
  WHEN ((new.message_type = ANY (ARRAY['request','reminder'])) OR (new.priority = ANY (ARRAY['urgent','high'])))
  EXECUTE FUNCTION notify_room_message();
\i /tmp/live_room_send_functions.sql
SELECT t_assert(md5(pg_get_functiondef('public.send_room_message(uuid,text,uuid,text,text,text,text,text,uuid,text,jsonb,timestamptz,text,uuid)'::regprocedure)) = 'ca1c13939521b694f4a2bed53b999c95',
  'send_room_message loaded byte for byte (md5 = production)');
SELECT t_assert(md5(pg_get_functiondef('public.respond_to_message(uuid,text,text,text,jsonb)'::regprocedure)) = '742cabd5fe79f590b6072259fabb72cb',
  'respond_to_message loaded byte for byte (md5 = production)');

INSERT INTO room_members (room_id, profile_id, role, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'user2', 'member', 'approved');
INSERT INTO assistant_profiles (id, name, slug, human_profile_id) VALUES ('55555555-5555-5555-5555-555555555555', 'A', 'a', 'user2');
INSERT INTO rooms (id, name, slug, room_type, owner_id) VALUES ('22222222-2222-2222-2222-222222222222', 'Personal', 'p', 'personal', 'owner1');
INSERT INTO room_members (room_id, profile_id, role, status, assistant_profile_id) VALUES
  ('22222222-2222-2222-2222-222222222222', 'user2', 'member', 'approved', '55555555-5555-5555-5555-555555555555');
DELETE FROM email_send_log;
TRUNCATE test_outbox;

SELECT send_room_message('11111111-1111-1111-1111-111111111111', 'owner1', p_message_type := 'request', p_subject := 'SECRETSUBJECT',
  p_body := 'SECRETBODY', p_to_profile_id := 'user2', p_priority := 'urgent') \gset r1_
SELECT t_assert((SELECT count(*) FROM message_recipients WHERE profile_id = 'user2') = 1, 'enterprise, one person: recipient row exists');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'send_room_message, enterprise, one person, urgent request: 0 mails');
SELECT send_room_message('11111111-1111-1111-1111-111111111111', 'owner1', p_message_type := 'reminder', p_subject := 's', p_body := 'b', p_priority := 'high') \gset r2_
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'send_room_message, enterprise, broadcast, high reminder: 0 mails');
SELECT send_room_message('22222222-2222-2222-2222-222222222222', 'owner1', p_message_type := 'request', p_subject := 's', p_body := 'b', p_priority := 'urgent') \gset r3_
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'send_room_message, personal room, broadcast: 0 mails');
SELECT send_room_message('22222222-2222-2222-2222-222222222222', 'owner1', p_to_assistant_id := '55555555-5555-5555-5555-555555555555',
  p_message_type := 'request', p_subject := 's', p_body := 'b', p_priority := 'urgent') \gset r4_
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'send_room_message, personal room, one assistant: 0 mails');
SELECT respond_to_message(:'r1_send_room_message', 'user2', 'A', 'SECRETREPLY') \gset r5_
SELECT t_assert((SELECT count(*) FROM room_messages WHERE id = :'r5_respond_to_message' AND message_type = 'response') = 1, 'respond_to_message wrote the reply');
SELECT t_assert((SELECT count(*) FROM test_outbox) = 0, 'respond_to_message: 0 mails');
SELECT t_assert((SELECT count(*) FROM email_send_log WHERE kind = 'notification') = 0, 'nothing logged as a notification (the mail loop never ran)');

-- control: the trigger does mail when recipients are already visible, so the zeros above are not a dead test
TRUNCATE test_outbox;
WITH m AS (INSERT INTO room_messages (room_id, from_profile_id, message_type, subject, body, priority)
           VALUES ('11111111-1111-1111-1111-111111111111', 'owner1', 'request', 'SECRETSUBJECT', 'SECRETBODY', 'urgent') RETURNING id)
INSERT INTO message_recipients (message_id, profile_id) SELECT id, 'user2' FROM m;
SELECT t_assert((SELECT count(*) FROM test_outbox) = 1, 'control: one statement inserting message and recipient does mail (admin access only)');
SELECT t_assert((SELECT payload::text NOT LIKE '%SECRET%' FROM test_outbox), 'control: that mail has no message content');
