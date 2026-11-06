#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker, never points at Supabase. Production state of both connection mail
# functions (W44 stand-in), proof the old mails carry the text, then 2026-11-05_connection_mail_no_text.sql:
# atomicity, guard, assertions, verify file incl. sabotage, re-apply, rollback, apply in an outer transaction.
# Usage: sql/tests/run_connection_mail_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=connmail_pg_test
MIG=security_fixes/2026-11-05_connection_mail_no_text.sql
RB=security_fixes/2026-11-05_connection_mail_no_text_rollback.sql
VER=security_fixes/2026-11-05_connection_mail_no_text_verify_after_apply.sql
LIVE="36739fc73168e1a322c3b2654f793ac9 5f9f831afdd47c99a9695c1c780f5ab0"
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
REQ="'public.notify_connection_request()'::regprocedure"; ACC="'public.notify_connection_accepted()'::regprocedure"
MD5Q="select md5(pg_get_functiondef($REQ))||' '||md5(pg_get_functiondef($ACC))"
ACLQ="select string_agg(proacl::text||' '||proowner::regrole::text, ' ' order by proname) from pg_proc where oid in ($REQ, $ACC)"
md5now() { P -At -c "$MD5Q"; }
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }
defq() { P -At -c "select pg_get_functiondef($1)"; }

P < tests/w44_base_schema.sql >/dev/null
P < security_fixes/2026-10-26_w44_live_snapshot.sql >/dev/null
P < tests/w44_live_acl_triggers.sql >/dev/null
P < tests/w44_seed_and_before.sql >/dev/null 2>&1
P < security_fixes/2026-10-26_w44_19_20_hardening.sql >/dev/null 2>&1
ACL0=$(P -At -c "$ACLQ")
[ "$(md5now)" = "$LIVE" ] && echo "PASS start: both md5 = production read 2026-11-05" || { echo "FAIL start md5 $(md5now)"; exit 1; }

P -c "INSERT INTO connection_requests (id, from_user, to_user, message) VALUES ('66666666-6666-6666-6666-666666666660', 'owner1', 'user2', 'SECRETMESSAGE');
      UPDATE connection_requests SET status='accepted', response_message='SECRETREPLY' WHERE id='66666666-6666-6666-6666-666666666660'" >/dev/null
[ "$(P -At -c "select count(*) from test_outbox where payload::text like '%SECRETMESSAGE%'")" = 1 ] && [ "$(P -At -c "select count(*) from test_outbox where payload::text like '%SECRETREPLY%'")" -ge 1 ] \
  && echo "PASS before: old functions put both texts into the mails" || { echo "FAIL before"; exit 1; }
P -c "DELETE FROM connection_requests; DELETE FROM email_send_log; TRUNCATE test_outbox" >/dev/null

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && { echo "FAIL forced error not raised"; exit 1; } || true
[ "$(md5now)" = "$LIVE" ] && echo "PASS atomic: forced error before COMMIT, nothing changed" || { echo "FAIL partial apply"; exit 1; }

OLD_ACC=$(defq "$ACC")
P -c "$(echo "$OLD_ACC" | sed 's/^BEGIN$/BEGIN -- drift/')" >/dev/null
if G=$(P < "$MIG" 2>&1); then echo "FAIL guard let a changed body through"; exit 1; fi
echo "$G" | grep -q "aborting" && echo "PASS guard: changed production body stops the migration" || { echo "FAIL guard: $G"; exit 1; }
[ "$(P -At -c "select md5(pg_get_functiondef($REQ))")" = "${LIVE%% *}" ] && echo "PASS guard: the other function untouched" || { echo "FAIL guard partial"; exit 1; }
P -c "$OLD_ACC" >/dev/null
[ "$(md5now)" = "$LIVE" ] || { echo "FAIL restoring after the drift test"; exit 1; }

P < "$MIG" >/dev/null
echo "== md5 after apply: $(md5now)"
OUT=$(P -At < tests/connection_mail_after.sql 2>&1) || { echo "$OUT" | tail -5; echo "FAIL assertions stopped"; exit 1; }
echo "$OUT" | sed 's/^psql:[^ ]* NOTICE:  //' | grep -E "PASS|FAIL|ERROR"
echo "$OUT" | grep -qE "FAIL|ERROR" && { echo "FAIL assertions"; exit 1; }
[ "$(P -At -c "$ACLQ")" = "$ACL0" ] && echo "PASS owner and ACL identical to before" || { echo "FAIL ACL changed"; exit 1; }
green && echo "PASS verify file: all checks ok" || { echo "FAIL verify file"; P -At < "$VER"; exit 1; }

sabotage() {  # name, break, restore
  P -c "$2" >/dev/null
  if green; then echo "FAIL verify stayed green: $1"; exit 1; else echo "PASS verify false: $1"; fi
  P -c "$3" >/dev/null
}
NEW_ACC=$(defq "$ACC")
sabotage "old accepted body back" "$OLD_ACC" "$NEW_ACC"
sabotage "trigger disabled" "ALTER TABLE connection_requests DISABLE TRIGGER on_new_connection_request" "ALTER TABLE connection_requests ENABLE TRIGGER on_new_connection_request"
sabotage "anon may execute" "GRANT EXECUTE ON FUNCTION public.notify_connection_request() TO anon" "REVOKE EXECUTE ON FUNCTION public.notify_connection_request() FROM anon"
sabotage "search_path not pinned" "ALTER FUNCTION public.notify_connection_accepted() RESET search_path" "ALTER FUNCTION public.notify_connection_accepted() SET search_path TO 'public', 'pg_temp'"
sabotage "not security definer" "ALTER FUNCTION public.notify_connection_request() SECURITY INVOKER" "ALTER FUNCTION public.notify_connection_request() SECURITY DEFINER"
green && echo "PASS verify green again after every restore" || { echo "FAIL restore"; P -At < "$VER"; exit 1; }

if P < "$MIG" >/dev/null 2>&1; then echo "FAIL re-apply did not abort"; exit 1; else echo "PASS re-apply aborted"; fi
W44RB=security_fixes/2026-10-26_w44_19_20_hardening_rollback.sql
B44=$(md5now)
if G=$(P < "$W44RB" 2>&1); then echo "FAIL W44 rollback ran"; exit 1; fi
echo "$G" | grep -q "later migrations changed the mail functions" && [ "$(md5now)" = "$B44" ] \
  && echo "PASS W44 rollback refused after this migration, nothing changed" || { echo "FAIL W44 rollback: $G"; exit 1; }
P < "$RB" >/dev/null
[ "$(md5now)" = "$LIVE" ] && [ "$(P -At -c "$ACLQ")" = "$ACL0" ] && echo "PASS rollback restores production md5 and ACL" || { echo "FAIL rollback $(md5now)"; exit 1; }
if P < "$RB" >/dev/null 2>&1; then echo "FAIL second rollback did not abort"; exit 1; else echo "PASS rollback refuses a body that is not the no-text one"; fi
P -c "BEGIN; $(cat "$MIG") COMMIT;" >/dev/null 2>&1
green && echo "PASS apply inside an outer transaction: verify all ok" || { echo "FAIL apply in outer transaction"; exit 1; }
echo "== ALL PASS"
