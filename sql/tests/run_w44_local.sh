#!/usr/bin/env bash
# LOCAL ONLY: reproduces the live state of 2026-10-26 on postgres:17 in docker and runs the
# W44 migration: atomicity (3 send modes + forced failure), assertions incl. @ciso attacks,
# read-only verification file, re-apply (must abort), rollback (must restore live md5 + ACL),
# and a second apply inside an outer transaction (how a migration tool may wrap it).
# Usage: sql/tests/run_w44_local.sh   (needs docker; never points at Supabase). KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=w44pg_test
MIG=security_fixes/2026-10-26_w44_19_20_hardening.sql
RB=security_fixes/2026-10-26_w44_19_20_hardening_rollback.sql
VER=security_fixes/2026-10-26_w44_verify_after_apply.sql
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P()  { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
P0() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=0 -q "$@"; }
MD5Q="select string_agg(proname||'='||md5(pg_get_functiondef(oid)), ' ' order by proname) from pg_proc
 where pronamespace='public'::regnamespace and proname in ('send_verification_email','resend_verification_email',
 'notify_new_profile','send_welcome_email_after_verification','notify_connection_accepted','notify_connection_request',
 'notify_room_invite','notify_room_member_approved','notify_room_message','send_weekly_matches_email')"
STATEQ="select coalesce(to_regclass('public.email_send_log')::text,'no-log')||' '||
 (select count(*) from pg_policies where tablename='profiles' and cmd='INSERT')||' '||
 (select string_agg(a.grantee::regrole::text||':'||a.privilege_type, ',' order by a.grantee::regrole::text, a.privilege_type) from pg_class c,
   aclexplode(c.relacl) a where c.oid='public.profiles'::regclass)||' '||
 (select count(*) from pg_policies where tablename='room_members' and qual like '%offboarded%')"
unchanged() {  # $1 = label
  if [ "$(P -At -c "$MD5Q")" = "$BEFORE" ] && [ "$(P -At -c "$STATEQ")" = "$STATE0" ]; then
    echo "PASS atomic: $1 -> nothing changed"; else echo "FAIL atomic: $1 left partial changes"; exit 1; fi
}

P < tests/w44_base_schema.sql
P < security_fixes/2026-10-26_w44_live_snapshot.sql
P < tests/w44_live_acl_triggers.sql
BEFORE=$(P -At -c "$MD5Q")
STATE0=$(P -At -c "$STATEQ")
echo "== live md5 reproduced: $BEFORE"
echo "== live state: $STATE0"
P < tests/w44_seed_and_before.sql 2>&1 | grep -E "PASS|FAIL|ERROR" || true

echo "== @ciso W2: atomicity, failure forced just before COMMIT"
FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P  >/dev/null 2>&1 && { echo "FAIL forced error not raised"; exit 1; } || true
unchanged "psql -f, stop on error (connection closes inside the transaction)"
echo "$FAILING" | P0 >/dev/null 2>&1 || true
unchanged "psql -f, continue on error (COMMIT turns into ROLLBACK)"
P -c "$FAILING" >/dev/null 2>&1 && { echo "FAIL forced error not raised"; exit 1; } || true
unchanged "whole file as one simple query"
P -c "BEGIN; $FAILING" >/dev/null 2>&1 || true
unchanged "inside an outer transaction of a tool"

echo "== apply migration (statement by statement, as psql -f)"
P < "$MIG" 2>&1 | grep -vE "^$" || true
P < tests/w44_after.sql 2>&1 | grep -E "PASS|FAIL|ERROR"
echo "== verify file (read-only, pg_catalog)"
P -At -F ' | ' < "$VER" | grep -E "ALL OK|\| f \|" || true
P -At < "$VER" | grep -q "^== ALL OK ==|t|" && echo "PASS verify file: all checks ok" || { echo "FAIL verify file"; P -At -F ' | ' < "$VER" | grep "| f |"; exit 1; }
echo "== re-apply must abort"
if P < "$MIG" >/dev/null 2>&1; then echo "FAIL re-apply did not abort"; exit 1; else echo "PASS re-apply aborted"; fi
P -At -c "select count(*) from pg_proc where proname='register_profile'" | grep -qx 1 && echo "PASS re-apply left one register_profile"
echo "== md5 after: $(P -At -c "$MD5Q")"
echo "== md5 join_room_with_invite: $(P -At -c "select md5(pg_get_functiondef('public.join_room_with_invite(text,text,uuid)'::regprocedure))")"

echo "== rollback"
P < "$RB" >/dev/null
[ "$(P -At -c "$MD5Q")" = "$BEFORE" ] && echo "PASS rollback restores live md5" || { echo "FAIL rollback md5"; exit 1; }
[ "$(P -At -c "$STATEQ")" = "$STATE0" ] && echo "PASS rollback restores live ACL (arwd), INSERT policies, delete policy" \
  || { echo "FAIL rollback state: $(P -At -c "$STATEQ") vs $STATE0"; exit 1; }

echo "== second apply inside an outer transaction (tool-style wrapping), then verify"
P -c "BEGIN; $(cat "$MIG") COMMIT;" >/dev/null 2>&1
P -At < "$VER" | grep -q "^== ALL OK ==|t|" && echo "PASS apply in outer transaction: verify all ok" || { echo "FAIL apply in outer transaction"; exit 1; }
P < "$RB" >/dev/null
[ "$(P -At -c "$MD5Q")" = "$BEFORE" ] && [ "$(P -At -c "$STATEQ")" = "$STATE0" ] && echo "PASS second rollback restores live state"
