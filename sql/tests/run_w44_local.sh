#!/usr/bin/env bash
# LOCAL ONLY: reproduces the live state of 2026-10-26 on postgres:17 in docker and runs the
# W44 migration, its assertions, a re-apply (must abort) and the rollback.
# Usage: sql/tests/run_w44_local.sh   (needs docker; never points at Supabase)
set -euo pipefail
cd "$(dirname "$0")/.."
C=w44pg_test
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
MD5Q="select string_agg(proname||'='||md5(pg_get_functiondef(oid)), ' ' order by proname) from pg_proc
 where pronamespace='public'::regnamespace and proname in ('send_verification_email','resend_verification_email',
 'notify_new_profile','send_welcome_email_after_verification','notify_connection_accepted','notify_connection_request',
 'notify_room_invite','notify_room_member_approved','notify_room_message','send_weekly_matches_email')"

P < tests/w44_base_schema.sql
P < security_fixes/2026-10-26_w44_live_snapshot.sql
P < tests/w44_live_acl_triggers.sql
BEFORE=$(P -At -c "$MD5Q")
echo "== live md5 reproduced: $BEFORE"
P < tests/w44_seed_and_before.sql 2>&1 | grep -E "PASS|FAIL|ERROR" || true

echo "== apply migration"
P -1 < security_fixes/2026-10-26_w44_19_20_hardening.sql
P < tests/w44_after.sql 2>&1 | grep -E "PASS|FAIL|ERROR"
echo "== re-apply must abort"
if P -1 < security_fixes/2026-10-26_w44_19_20_hardening.sql >/dev/null 2>&1; then echo "FAIL re-apply did not abort"; exit 1; else echo "PASS re-apply aborted"; fi
echo "== md5 after: $(P -At -c "$MD5Q")"

echo "== rollback"
P -1 < security_fixes/2026-10-26_w44_19_20_hardening_rollback.sql
AFTER_RB=$(P -At -c "$MD5Q")
[ "$AFTER_RB" = "$BEFORE" ] && echo "PASS rollback restores live md5" || { echo "FAIL rollback md5"; exit 1; }
P -At -c "select count(*) from pg_policies where tablename='profiles' and cmd='INSERT'" | grep -qx 2 && echo "PASS rollback restores INSERT policies"
