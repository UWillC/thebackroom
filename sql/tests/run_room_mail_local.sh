#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker, never points at Supabase. Builds the production state of
# notify_room_message (W44 stand-in), proves the old mail carries content, then runs
# 2026-11-05_room_mail_no_content.sql: atomicity, assertions, verify file incl. sabotage, re-apply,
# rollback to the production md5, second apply inside an outer transaction.
# Usage: sql/tests/run_room_mail_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=roommail_pg_test
MIG=security_fixes/2026-11-05_room_mail_no_content.sql
RB=security_fixes/2026-11-05_room_mail_no_content_rollback.sql
VER=security_fixes/2026-11-05_room_mail_no_content_verify_after_apply.sql
LIVE_MD5=ca322bde9b801dec4274ccc1738f43e2
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
MD5Q="select md5(pg_get_functiondef('public.notify_room_message()'::regprocedure))"
ACLQ="select proacl::text||' '||proowner::regrole::text from pg_proc where oid='public.notify_room_message()'::regprocedure"
md5now() { P -At -c "$MD5Q"; }
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }

P < tests/w44_base_schema.sql >/dev/null
P < security_fixes/2026-10-26_w44_live_snapshot.sql >/dev/null
P < tests/w44_live_acl_triggers.sql >/dev/null
P < tests/w44_seed_and_before.sql >/dev/null 2>&1
P < security_fixes/2026-10-26_w44_19_20_hardening.sql >/dev/null 2>&1
ACL0=$(P -At -c "$ACLQ")
[ "$(md5now)" = "$LIVE_MD5" ] && echo "PASS start: function md5 = production read 2026-11-05 ($LIVE_MD5)" \
  || { echo "FAIL start md5 $(md5now)"; exit 1; }

BEFORE_SQL="DELETE FROM public.test_outbox;
INSERT INTO message_recipients VALUES ('44444444-4444-4444-4444-444444444440', 'user2');
INSERT INTO room_messages (id, room_id, from_profile_id, message_type, priority, subject, body)
VALUES ('44444444-4444-4444-4444-444444444440', '11111111-1111-1111-1111-111111111111', 'owner1', 'request', 'high', 'SECRETSUBJECT', 'SECRETBODY');"
P -c "$BEFORE_SQL" >/dev/null
[ "$(P -At -c "select count(*) from test_outbox where payload::text like '%SECRETSUBJECT%' and payload::text like '%SECRETBODY%'")" = 1 ] \
  && echo "PASS before: old function puts subject and body into the mail" || { echo "FAIL before"; exit 1; }
P -c "DELETE FROM message_recipients; DELETE FROM room_messages; DELETE FROM email_send_log; TRUNCATE test_outbox" >/dev/null

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && { echo "FAIL forced error not raised"; exit 1; } || true
[ "$(md5now)" = "$LIVE_MD5" ] && echo "PASS atomic: forced error before COMMIT, nothing changed" || { echo "FAIL partial apply"; exit 1; }

LIVE_DEF=$(P -At -c "select pg_get_functiondef('public.notify_room_message()'::regprocedure)")
P -c "$(echo "$LIVE_DEF" | sed 's/^BEGIN$/BEGIN -- drift/')" >/dev/null
if G=$(P < "$MIG" 2>&1); then echo "FAIL guard let a changed body through"; exit 1; fi
echo "$G" | grep -q "aborting" && echo "PASS guard: changed production body stops the migration" || { echo "FAIL guard: $G"; exit 1; }
P -c "$LIVE_DEF" >/dev/null
[ "$(md5now)" = "$LIVE_MD5" ] || { echo "FAIL restoring after the drift test"; exit 1; }

P < "$MIG" >/dev/null
echo "== md5 after apply: $(md5now)"
OUT=$(P -At < tests/room_mail_after.sql 2>&1) || { echo "$OUT" | tail -5; echo "FAIL assertions stopped"; exit 1; }
echo "$OUT" | sed 's/^psql:[^ ]* NOTICE:  //' | grep -E "PASS|FAIL|ERROR"
echo "$OUT" | grep -qE "FAIL|ERROR" && { echo "FAIL assertions"; exit 1; }
[ "$(P -At -c "$ACLQ")" = "$ACL0" ] && echo "PASS owner and ACL identical to before" || { echo "FAIL ACL changed"; exit 1; }
green && echo "PASS verify file: all checks ok" || { echo "FAIL verify file"; P -At < "$VER"; exit 1; }

sabotage() {  # name, break, restore
  P -c "$2" >/dev/null
  if green; then echo "FAIL verify stayed green: $1"; exit 1; else echo "PASS verify false: $1"; fi
  P -c "$3" >/dev/null
}
NEW_DEF=$(P -At -c "select pg_get_functiondef('public.notify_room_message()'::regprocedure)")
sabotage "body changed" "$(echo "$NEW_DEF" | sed 's/Open The Backroom/Open/')" "$NEW_DEF"
sabotage "trigger disabled" "ALTER TABLE room_messages DISABLE TRIGGER on_room_message_sent" "ALTER TABLE room_messages ENABLE TRIGGER on_room_message_sent"
sabotage "anon may execute" "GRANT EXECUTE ON FUNCTION public.notify_room_message() TO anon" "REVOKE EXECUTE ON FUNCTION public.notify_room_message() FROM anon"
sabotage "search_path not pinned" "ALTER FUNCTION public.notify_room_message() RESET search_path" "ALTER FUNCTION public.notify_room_message() SET search_path TO 'public', 'pg_temp'"
sabotage "not security definer" "ALTER FUNCTION public.notify_room_message() SECURITY INVOKER" "ALTER FUNCTION public.notify_room_message() SECURITY DEFINER"
sabotage "old body back" "$LIVE_DEF" "$NEW_DEF"
green && echo "PASS verify green again after every restore" || { echo "FAIL restore"; P -At < "$VER"; exit 1; }

if P < "$MIG" >/dev/null 2>&1; then echo "FAIL re-apply did not abort"; exit 1; else echo "PASS re-apply aborted"; fi

P < "$RB" >/dev/null
[ "$(md5now)" = "$LIVE_MD5" ] && [ "$(P -At -c "$ACLQ")" = "$ACL0" ] && echo "PASS rollback restores production md5 and ACL" \
  || { echo "FAIL rollback $(md5now)"; exit 1; }
if P < "$RB" >/dev/null 2>&1; then echo "FAIL second rollback did not abort"; exit 1; else echo "PASS rollback refuses a body that is not the no-content one"; fi

P -c "BEGIN; $(cat "$MIG") COMMIT;" >/dev/null 2>&1
green && echo "PASS apply inside an outer transaction: verify all ok" || { echo "FAIL apply in outer transaction"; exit 1; }

echo "== @ciso W4: real send_room_message and respond_to_message"
docker cp tests/live_room_send_functions.sql "$C":/tmp/live_room_send_functions.sql >/dev/null
OUT=$(P -At < tests/room_mail_live_send.sql 2>&1) || { echo "$OUT" | tail -5; echo "FAIL live send stopped"; exit 1; }
echo "$OUT" | sed 's/^psql:[^ ]* NOTICE:  //' | grep -E "PASS|FAIL|ERROR"
echo "$OUT" | grep -qE "FAIL|ERROR" && { echo "FAIL live send"; exit 1; }

echo "== @ciso N3: W44 rollback refuses after the new migration"
W44RB=security_fixes/2026-10-26_w44_19_20_hardening_rollback.sql
B44=$(md5now)
if G=$(P < "$W44RB" 2>&1); then echo "FAIL W44 rollback ran"; exit 1; fi
echo "$G" | grep -q "later migrations changed the mail functions" && [ "$(md5now)" = "$B44" ] \
  && echo "PASS W44 rollback refused, nothing changed" || { echo "FAIL W44 rollback: $G"; exit 1; }

echo "== @ciso N2: a send order fix must break the 0 mails assertion (deferred trigger, real functions)"
P -c "DELETE FROM room_members WHERE profile_id = 'user2'; DELETE FROM rooms WHERE id = '22222222-2222-2222-2222-222222222222';
      DROP TABLE message_recipients, room_messages; DELETE FROM assistant_profiles; DELETE FROM email_send_log; TRUNCATE test_outbox" >/dev/null
MUT=$(sed 's/^CREATE TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages FOR EACH ROW$/CREATE CONSTRAINT TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW/; /^DROP TABLE public.message_recipients, public.room_messages;$/d' tests/room_mail_live_send.sql)
[ "$MUT" != "$(cat tests/room_mail_live_send.sql)" ] || { echo "FAIL mutation not applied"; exit 1; }
echo "$MUT" | grep -q "CREATE CONSTRAINT TRIGGER" || { echo "FAIL mutation not applied"; exit 1; }
if M=$(echo "$MUT" | P -At 2>&1); then echo "FAIL mutated test stayed green"; exit 1; fi
echo "$M" | grep -q "FAIL send_room_message, enterprise, one person, urgent request: 0 mails" \
  && echo "PASS order fixed: the 0 mails assertion fails" || { echo "FAIL unexpected error: $M"; exit 1; }
[ "$(P -At -c "select count(*) from test_outbox")" = 1 ] && [ "$(P -At -c "select count(*) from test_outbox where payload::text like '%SECRET%'")" = 0 ] \
  && echo "PASS order fixed: the mail goes out, with no message content" || { echo "FAIL mutated mail"; exit 1; }

echo "== drop_room_message_trigger: rebuild the production state, then remove the trigger"
DROPMIG=security_fixes/2026-11-05_drop_room_message_trigger.sql
DROPRB=security_fixes/2026-11-05_drop_room_message_trigger_rollback.sql
PATHS=security_fixes/2026-11-05_room_mail_send_paths_verify.sql
paths_green() { P -At < "$PATHS" | grep -q "^== ALL OK ==|t|"; }
TRGQ="select coalesce((select md5(pg_get_triggerdef(oid)) from pg_trigger where tgname='on_room_message_sent'), 'none')"
P -c "DELETE FROM room_members WHERE profile_id = 'user2'; DELETE FROM rooms WHERE id = '22222222-2222-2222-2222-222222222222';
      DELETE FROM assistant_profiles; DELETE FROM email_send_log; TRUNCATE test_outbox" >/dev/null
OUT=$(P -At < tests/room_mail_live_send.sql 2>&1) || { echo "$OUT" | tail -5; echo "FAIL rebuild"; exit 1; }
[ "$(echo "$OUT" | grep -c PASS)" = 12 ] && ! echo "$OUT" | grep -qE "FAIL|ERROR" && echo "PASS rebuilt: 12 live send checks green again" || { echo "FAIL rebuild"; exit 1; }
[ "$(P -At -c "$TRGQ")" = 156e5d9d683c7204ee4ec09afa96fe2e ] && echo "PASS trigger md5 = production read 2026-11-05" || { echo "FAIL trigger md5 $(P -At -c "$TRGQ")"; exit 1; }
paths_green && { echo "FAIL guard green while the trigger exists"; exit 1; } || echo "PASS guard false while the trigger exists"

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$DROPMIG")
echo "$FAILING" | P >/dev/null 2>&1 && { echo "FAIL forced error not raised"; exit 1; } || true
[ "$(P -At -c "$TRGQ")" = 156e5d9d683c7204ee4ec09afa96fe2e ] && echo "PASS atomic: forced error before COMMIT, trigger still there" || { echo "FAIL partial"; exit 1; }
TRG_DEF=$(P -At -c "select pg_get_triggerdef(oid) from pg_trigger where tgname='on_room_message_sent'")
DEFER="CREATE CONSTRAINT TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((new.message_type = ANY (ARRAY['request','reminder'])) OR (new.priority = ANY (ARRAY['urgent','high']))) EXECUTE FUNCTION notify_room_message()"
P -c "DROP TRIGGER on_room_message_sent ON public.room_messages; $DEFER" >/dev/null
if G=$(P < "$DROPMIG" 2>&1); then echo "FAIL guard let a changed trigger through"; exit 1; fi
echo "$G" | grep -q "aborting" && echo "PASS guard: changed trigger stops the migration" || { echo "FAIL guard: $G"; exit 1; }
P -c "DROP TRIGGER on_room_message_sent ON public.room_messages; $TRG_DEF" >/dev/null

P < "$DROPMIG" >/dev/null
[ "$(P -At -c "$TRGQ")" = none ] && echo "PASS trigger removed" || { echo "FAIL trigger still there"; exit 1; }
[ "$(P -At < "$PATHS" | grep -c '|')" = 5 ] && echo "PASS guard has 4 checks + the summary" || { echo "FAIL row count"; P -At < "$PATHS"; exit 1; }
paths_green && echo "PASS guard green after the drop" || { echo "FAIL guard"; P -At < "$PATHS"; exit 1; }
P -c "TRUNCATE test_outbox;
      WITH m AS (INSERT INTO room_messages (room_id, from_profile_id, message_type, subject, body, priority)
                 VALUES ('11111111-1111-1111-1111-111111111111', 'owner1', 'request', 'SECRETSUBJECT', 'SECRETBODY', 'urgent') RETURNING id)
      INSERT INTO message_recipients (message_id, profile_id) SELECT id, 'user2' FROM m;
      SELECT send_room_message('11111111-1111-1111-1111-111111111111', 'owner1', p_message_type := 'request', p_subject := 's',
        p_body := 'b', p_to_profile_id := 'user2', p_priority := 'urgent');" >/dev/null
[ "$(P -At -c "select count(*) from test_outbox")" = 0 ] && echo "PASS no trigger: the one-statement path and send_room_message both mail nothing" || { echo "FAIL mail without trigger"; exit 1; }

sabotage_paths() {  # name, break, restore
  P -c "$2" >/dev/null
  if paths_green; then echo "FAIL guard stayed green: $1"; exit 1; else echo "PASS guard false: $1"; fi
  P -c "$3" >/dev/null
}
NRM_DEF=$(P -At -c "select pg_get_functiondef('public.notify_room_message()'::regprocedure)")
sabotage_paths "trigger back" "$TRG_DEF" "DROP TRIGGER on_room_message_sent ON public.room_messages"
sabotage_paths "trigger on recipients" "CREATE TRIGGER t2 AFTER INSERT ON public.message_recipients FOR EACH ROW EXECUTE FUNCTION public.notify_room_message()" "DROP TRIGGER t2 ON public.message_recipients"
sabotage_paths "function on another table" "CREATE TRIGGER t3 AFTER INSERT ON public.room_invites FOR EACH ROW EXECUTE FUNCTION public.notify_room_message()" "DROP TRIGGER t3 ON public.room_invites"
sabotage_paths "harmless other trigger on room_messages" "CREATE FUNCTION public.t_noop() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'; CREATE TRIGGER t4 AFTER INSERT ON public.room_messages FOR EACH ROW EXECUTE FUNCTION public.t_noop()" "DROP TRIGGER t4 ON public.room_messages; DROP FUNCTION public.t_noop()"
sabotage_paths "new function mails room messages" "CREATE FUNCTION public.t_mailer() RETURNS void LANGUAGE plpgsql AS \$\$ BEGIN PERFORM net.http_post('https://api.resend.com/emails', '{}'::jsonb, (SELECT to_jsonb(m) FROM room_messages m LIMIT 1)); END \$\$" "DROP FUNCTION public.t_mailer()"
sabotage_paths "notify_room_message body changed" "$(echo "$NRM_DEF" | sed 's/Open The Backroom/Open/')" "$NRM_DEF"
sabotage_paths "notify_room_message dropped" "ALTER FUNCTION public.notify_room_message() RENAME TO nrm_old" "ALTER FUNCTION public.nrm_old() RENAME TO notify_room_message"
paths_green && echo "PASS guard green again after every restore" || { echo "FAIL restore"; P -At < "$PATHS"; exit 1; }

if P < "$DROPMIG" >/dev/null 2>&1; then echo "FAIL re-apply did not abort"; exit 1; else echo "PASS re-apply aborted"; fi
P < "$DROPRB" >/dev/null
[ "$(P -At -c "$TRGQ")" = 156e5d9d683c7204ee4ec09afa96fe2e ] && [ "$(md5now)" = 43370bf649dc583d902aa655831ba951 ] \
  && echo "PASS rollback restores the production trigger on the no-content function" || { echo "FAIL rollback"; exit 1; }
if P < "$DROPRB" >/dev/null 2>&1; then echo "FAIL second rollback did not abort"; exit 1; else echo "PASS rollback refuses when the trigger exists"; fi
P -c "BEGIN; $(cat "$DROPMIG") COMMIT;" >/dev/null 2>&1
[ "$(P -At -c "$TRGQ")" = none ] && paths_green && echo "PASS apply inside an outer transaction: guard green" || { echo "FAIL apply in outer transaction"; exit 1; }
echo "== ALL PASS"
