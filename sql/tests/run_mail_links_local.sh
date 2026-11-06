#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker, never points at Supabase. Rebuilds the production state of the 9 mail
# functions (W44 stand-in + 2026-11-05 migrations), proves the old mails link to the Hugging Face Space, then runs
# 2026-11-05_mail_links_to_pages.sql: atomicity, guard, apply, verify file incl. sabotage, real mails (verification
# token in the fragment, still accepted by verify_email_token as anon), re-apply, rollback, outer transaction.
# Usage: sql/tests/run_mail_links_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=maillinks_pg_test
MIG=security_fixes/2026-11-05_mail_links_to_pages.sql
RB=security_fixes/2026-11-05_mail_links_to_pages_rollback.sql
VER=security_fixes/2026-11-05_mail_links_to_pages_verify_after_apply.sql
# md5 of pg_get_functiondef, production read 2026-11-05 (read-only MCP), sorted by function name
LIVE="notify_connection_accepted|25f44f42b3d607e865200104045354c0
notify_connection_request|afe33640be139e29d07808cf2217d125
notify_new_profile|f28cc562832f991ae089a142e39139a4
notify_room_invite|4b27280d7eaf436450a888246ab41797
notify_room_member_approved|33294880c050cb484830eaeca7400041
resend_verification_email|ef0e16b47f239198e9db8988fe10cc0c
send_verification_email|4ec5ca19f0e39f5d80af4827503d7878
send_weekly_matches_email|0917b95d5ea952ac3eebb0a49e02a0cf
send_welcome_email_after_verification|db7ab1f85b7d346118c51d4968352d7b"
FNS="'send_verification_email','resend_verification_email','notify_connection_accepted','notify_connection_request','notify_new_profile','notify_room_invite','notify_room_member_approved','send_weekly_matches_email','send_welcome_email_after_verification'"
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
md5s() { P -At -c "select proname||'|'||md5(pg_get_functiondef(oid)) from pg_proc where pronamespace='public'::regnamespace and proname in ($FNS) order by 1"; }
ACLQ="select string_agg(proname||' '||coalesce(proacl::text,'')||' '||proowner::regrole::text||' '||prosecdef||' '||coalesce(proconfig::text,''), E'\n' order by proname) from pg_proc where pronamespace='public'::regnamespace and proname in ($FNS)"
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }
PASSN=0; pass() { PASSN=$((PASSN+1)); echo "PASS $1"; }
fail() { echo "FAIL $1"; exit 1; }

P < tests/w44_base_schema.sql >/dev/null
P < security_fixes/2026-10-26_w44_live_snapshot.sql >/dev/null
P < tests/w44_live_acl_triggers.sql >/dev/null
P < tests/w44_seed_and_before.sql >/dev/null 2>&1
P < security_fixes/2026-10-26_w44_19_20_hardening.sql >/dev/null 2>&1
P < security_fixes/2026-11-05_connection_mail_no_text.sql >/dev/null 2>&1
P < security_fixes/2026-11-05_room_mail_no_content.sql >/dev/null 2>&1
P < security_fixes/2026-11-05_drop_room_message_trigger.sql >/dev/null 2>&1
P < tests/live_verify_email_token.sql >/dev/null
[ "$(md5s)" = "$LIVE" ] && pass "start: all 9 function md5 = production read 2026-11-05" || { md5s; fail "start md5"; }
ACL0=$(P -At -c "$ACLQ")

# Mail helper: new profile with e-mail -> send_verification_email fires; returns the html of the last mail.
lastmail() { P -At -c "select payload->>'html' from test_outbox order by n desc limit 1"; }
P -c "TRUNCATE test_outbox; INSERT INTO profiles(id,name,email) VALUES ('before1','B','b1@example.com')" >/dev/null
lastmail | grep -q 'huggingface.co/spaces/UWillC/thebackroom?verify=' && pass "before: verification mail links to the Space with ?verify=" || fail "before"

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && fail "forced error not raised" || true
[ "$(md5s)" = "$LIVE" ] && pass "atomic: forced error before COMMIT, all 9 unchanged" || fail "partial apply"

# Guard: drift in the LAST function of the list; earlier replacements in the same block must roll back too.
WDEF=$(P -At -c "select pg_get_functiondef('public.send_welcome_email_after_verification()'::regprocedure)")
P -c "$(echo "$WDEF" | sed 's/^BEGIN$/BEGIN -- drift/')" >/dev/null
if G=$(P < "$MIG" 2>&1); then fail "guard let a changed body through"; fi
echo "$G" | grep -q "send_welcome_email_after_verification() is not the 2026-11-05 production body" || fail "guard message: $G"
P -c "$WDEF" >/dev/null
[ "$(md5s)" = "$LIVE" ] && pass "guard: drift in one body stops the migration, none of the 9 changed" || fail "guard left changes"

# Link count guard: an extra Space link somewhere stops it as well.
SDEF=$(P -At -c "select pg_get_functiondef('public.notify_new_profile()'::regprocedure)")
P -c "$(echo "$SDEF" | sed 's#<a href="https://github.com/UWillC/thebackroom">GitHub</a>#<a href="https://huggingface.co/spaces/UWillC/thebackroom">GitHub</a>#')" >/dev/null
if P < "$MIG" >/dev/null 2>&1; then fail "changed body accepted"; fi
P -c "$SDEF" >/dev/null
[ "$(md5s)" = "$LIVE" ] && pass "guard: an extra Space link stops the migration" || fail "count guard left changes"

P < "$MIG" >/dev/null
[ "$(P -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and prosrc ilike '%huggingface%'")" = 0 ] \
  && pass "apply: no public function mentions huggingface" || fail "huggingface left"
[ "$(P -At -c "$ACLQ")" = "$ACL0" ] && pass "owner, ACL, SECURITY DEFINER, search_path identical to before" || fail "ACL changed"
green && pass "verify file: all checks ok" || { P -At < "$VER"; fail "verify file"; }

# Real mails after the change
P -c "TRUNCATE test_outbox; INSERT INTO profiles(id,name,email) VALUES ('vt1','VT','vt@example.com')" >/dev/null
M=$(lastmail)
echo "$M" | grep -q 'https://www.thebackroom.ai/app/#verify=' && ! echo "$M" | grep -q 'huggingface' && ! echo "$M" | grep -q '?verify=' \
  && pass "send_verification_email: link is /app/#verify=..., no query string, no Space" || fail "verification mail: $M"
TOKEN=$(echo "$M" | grep -oE '#verify=[0-9a-f-]{36}' | head -1 | cut -d= -f2)
[ -n "$TOKEN" ] || fail "no token in mail"
echo "$M" | grep -q "#verify=$TOKEN&amp;profile=vt1" && pass "fragment carries token and profile (&amp; in HTML = & in the link)" || fail "fragment shape"
R=$(P -At -c "SET ROLE anon; SELECT verify_email_token('vt1', '$TOKEN')")
echo "$R" | grep -q '"success": true' && [ "$(P -At -c "select email_verified from profiles where id='vt1'")" = t ] \
  && pass "token from the new link verifies the address as anon (as the page does)" || fail "verify_email_token: $R"
P -c "TRUNCATE test_outbox; INSERT INTO profiles(id,name,email) VALUES ('vt2','VT2','vt2@example.com');
      UPDATE profiles SET email_verification_sent_at = now() - interval '1 hour' WHERE id='vt2'; TRUNCATE test_outbox" >/dev/null
R=$(P -At -c "select resend_verification_email('vt2')")
echo "$R" | grep -q '"success": true' || fail "resend: $R"
M=$(lastmail)
echo "$M" | grep -q 'https://www.thebackroom.ai/app/#verify=' && ! echo "$M" | grep -q 'huggingface' \
  && pass "resend_verification_email: same fragment link" || fail "resend mail"
T2=$(echo "$M" | grep -oE '#verify=[0-9a-f-]{36}' | head -1 | cut -d= -f2)
R=$(P -At -c "SET ROLE anon; SELECT verify_email_token('vt2', '$T2')")
echo "$R" | grep -q '"success": true' && pass "token from the resend link verifies as anon" || fail "resend verify: $R"
W=$(P -At -c "select count(*) from test_outbox where payload::text like '%www.thebackroom.ai/app/%' and payload::text not like '%huggingface%'")
[ "$W" -ge 2 ] && pass "welcome mail after verification links to /app/ ($W mails with the new link)" || fail "welcome mail"

sabotage() {  # name, break, restore
  P -c "$2" >/dev/null
  if green; then fail "verify stayed green: $1"; else pass "verify false: $1"; fi
  P -c "$3" >/dev/null
}
NDEF=$(P -At -c "select pg_get_functiondef('public.notify_room_invite()'::regprocedure)")
sabotage "body changed" "$(echo "$NDEF" | sed 's#>Web UI<#>Web<#')" "$NDEF"
sabotage "Space link back in a body" "$(echo "$NDEF" | sed 's#https://www.thebackroom.ai/app/#https://huggingface.co/spaces/UWillC/thebackroom#')" "$NDEF"
sabotage "trigger disabled" "ALTER TABLE profiles DISABLE TRIGGER on_profile_email_change" "ALTER TABLE profiles ENABLE TRIGGER on_profile_email_change"
sabotage "anon may execute a mail function" "GRANT EXECUTE ON FUNCTION public.notify_new_profile() TO anon" "REVOKE EXECUTE ON FUNCTION public.notify_new_profile() FROM anon"
sabotage "search_path not pinned" "ALTER FUNCTION public.notify_room_invite() RESET search_path" "ALTER FUNCTION public.notify_room_invite() SET search_path TO 'public', 'pg_temp'"
sabotage "not security definer" "ALTER FUNCTION public.send_verification_email() SECURITY INVOKER" "ALTER FUNCTION public.send_verification_email() SECURITY DEFINER"
green && pass "verify green again after every restore" || fail "restore"

if P < "$MIG" >/dev/null 2>&1; then fail "re-apply did not abort"; else pass "re-apply aborted (guard)"; fi

P < "$RB" >/dev/null
[ "$(md5s)" = "$LIVE" ] && [ "$(P -At -c "$ACLQ")" = "$ACL0" ] && pass "rollback restores all 9 production md5 and ACL" || { md5s; fail "rollback"; }
if P < "$RB" >/dev/null 2>&1; then fail "second rollback ran"; else pass "rollback refuses bodies it did not write"; fi

P -c "BEGIN; $(cat "$MIG") COMMIT;" >/dev/null 2>&1
green && pass "apply inside an outer transaction: verify all ok" || fail "apply in outer transaction"

echo "== $PASSN PASS, 0 FAIL"
