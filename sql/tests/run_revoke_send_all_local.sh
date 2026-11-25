#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker (--network none), never points at Supabase. Tests
# security_fixes/2026-11-25_revoke_send_all_weekly*.sql on a Supabase-like stand-in: superuser supabase_admin,
# NON-superuser "postgres" owning the functions, anon/authenticated/service_role, Supabase default privileges on
# functions, dummy bodies with the exact production signatures (send_all = SECURITY INVOKER, send_weekly_matches_email
# = SECURITY DEFINER with the 22.09 revoke). Covers: verify before (false) + INFO row, guard (user), apply, the
# workflow-style call as anon before/after, re-apply abort, verify after (true), rollback (ACL = pre-state),
# rollback guard.
# Usage: sql/tests/run_revoke_send_all_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=revoke_send_all_pg_test
IMG="postgres:17@sha256:b8faeff7712663c2773a190181e1246e37e364b887611c04658c28b44e2408fe"   # same pin as run_w2_revoke_local.sh
MIG=security_fixes/2026-11-25_revoke_send_all_weekly.sql
VER=security_fixes/2026-11-25_revoke_send_all_weekly_verify_after_apply.sql
RB=security_fixes/2026-11-25_revoke_send_all_weekly_rollback.sql
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --network none -e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD=local "$IMG" >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U supabase_admin -d postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
S() { docker exec -i "$C" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q "$@"; }   # superuser
P() { docker exec -i "$C" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }         # Supabase-like postgres
PASSN=0; pass() { PASSN=$((PASSN+1)); echo "PASS $1"; }
fail() { echo "FAIL $1"; exit 1; }
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }
red() { P -At < "$VER" | grep -q "^== ALL OK ==|f|"; }
row() { P -At < "$VER" | grep -F "$1" | head -1; }
acl() { S -At -c "SELECT coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text COLLATE \"C\") FROM unnest(proacl) x), 'NULL')
                    FROM pg_proc WHERE oid = to_regprocedure('public.send_all_weekly_matches_emails()')"; }
eff() { S -At -c "SELECT r.rolname, has_function_privilege(r.oid, to_regprocedure('public.send_all_weekly_matches_emails()'), 'EXECUTE')
                    FROM pg_roles r WHERE r.rolname IN ('anon','authenticated','service_role','postgres','plain_login') ORDER BY 1"; }
as_anon() { P -At -c "SET ROLE anon; SELECT public.send_all_weekly_matches_emails()" 2>&1 || true; }

# ---- Supabase-like stand-in -------------------------------------------------------------------------------
S <<'SQL' >/dev/null
CREATE ROLE postgres LOGIN NOSUPERUSER CREATEROLE BYPASSRLS;
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE ROLE plain_login LOGIN;
GRANT anon, authenticated, service_role TO postgres;
ALTER DATABASE postgres OWNER TO postgres;
GRANT ALL ON SCHEMA public TO postgres WITH GRANT OPTION;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
P <<'SQL' >/dev/null
CREATE TABLE public.profiles (id text PRIMARY KEY, email text, email_verified boolean NOT NULL DEFAULT false,
  notifications_enabled boolean DEFAULT true);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
INSERT INTO public.profiles VALUES ('p1', 'p1@example.test', true, true);
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
CREATE FUNCTION public.send_weekly_matches_email(p_profile_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp AS $$ BEGIN RETURN '{"success":true}'; END $$;
REVOKE EXECUTE ON FUNCTION public.send_weekly_matches_email(text) FROM anon, authenticated, public;   -- 22.09
GRANT EXECUTE ON FUNCTION public.send_weekly_matches_email(text) TO service_role;
CREATE FUNCTION public.send_all_weekly_matches_emails() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT id FROM profiles WHERE email IS NOT NULL AND email_verified LOOP
    PERFORM send_weekly_matches_email(r.id); n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('sent', n);
END $$;
SQL
pass "stand-in: non-superuser postgres owns send_all (INVOKER) + send_weekly (DEFINER, 22.09 ACL), Supabase default privileges"
ACL_BEFORE=$(acl); EFF_BEFORE=$(eff)
echo "$ACL_BEFORE" | grep -q '^=X/postgres,anon=X/postgres,authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres$' \
  && pass "pre-state: PUBLIC + owner + anon/authenticated/service_role ($ACL_BEFORE)" || fail "pre-state: $ACL_BEFORE"

# ---- before apply -----------------------------------------------------------------------------------------
red && pass "verify before apply: == ALL OK == false" || fail "verify before apply not false"
row "INFO: ACL" | grep -qF "acl=$ACL_BEFORE" && pass "verify INFO ACL row = pre-state snapshot" || fail "info: $(row 'INFO: ACL')"
as_anon | grep -q "permission denied for table profiles" && pass "before: anon call (workflow path) = 42501 on profiles, as in the 25.11 dry-run" \
  || fail "before anon: $(as_anon)"

# ---- guard ------------------------------------------------------------------------------------------------
if G=$(S < "$MIG" 2>&1); then fail "ran as superuser"; fi
echo "$G" | grep -q "run as postgres" && [ "$(acl)" = "$ACL_BEFORE" ] && pass "guard: refuses any user other than postgres, nothing changed" || fail "guard: $G"
if G=$(S < "$RB" 2>&1); then fail "rollback ran as superuser"; fi
if G=$(P < "$RB" 2>&1); then fail "rollback ran before apply"; fi
echo "$G" | grep -q "revoke not applied" && [ "$(acl)" = "$ACL_BEFORE" ] && pass "rollback guard: refuses before apply, nothing changed" || fail "rb guard: $G"

# ---- apply ------------------------------------------------------------------------------------------------
P < "$MIG" >/dev/null && pass "apply as postgres"
green && pass "verify after apply: == ALL OK == true" || { P -At < "$VER"; fail "verify after apply"; }
as_anon | grep -q "permission denied for function send_all_weekly_matches_emails" && pass "after: anon call = permission denied for function" \
  || fail "after anon: $(as_anon)"
S -At -c "SELECT has_function_privilege('plain_login', 'public.send_all_weekly_matches_emails()', 'EXECUTE')" | grep -qx f \
  && pass "after: any other login role (via PUBLIC) has no EXECUTE" || fail "plain_login"
echo "$(acl)" | grep -q '^postgres=X/postgres,service_role=X/postgres$' && pass "after: ACL = owner + service_role ($(acl))" || fail "acl after: $(acl)"
if G=$(P < "$MIG" 2>&1); then fail "re-apply ran"; fi
echo "$G" | grep -q "nothing to do" && pass "re-apply aborts" || fail "re-apply: $G"

# ---- rollback ---------------------------------------------------------------------------------------------
P < "$RB" >/dev/null && pass "rollback as postgres"
[ "$(acl)" = "$ACL_BEFORE" ] && [ "$(eff)" = "$EFF_BEFORE" ] && pass "rollback: ACL and effective EXECUTE = pre-state" || fail "rollback: $(acl) / $(eff)"
red && pass "verify after rollback: false again" || fail "verify after rollback"
echo "== $PASSN passed =="
