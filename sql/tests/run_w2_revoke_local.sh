#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker (--network none), never points at Supabase. Tests @ciso condition W2
# (security_fixes/2026-11-12_w2_revoke_public_secdef*.sql) on a Supabase-like stand-in: superuser supabase_admin,
# NON-superuser "postgres" owning the functions, anon/authenticated/service_role, Supabase default privileges on
# functions, dummy bodies of the 3 writing SECURITY DEFINER functions with their exact production signatures (one with
# NULL proacl, two with explicit grants like verify_email_token's live ACL of 2026-11-05) and the 4 functions @ciso
# accepted. Covers: verify before (false), guards, atomicity, apply with and without backup_ro, the real attack path
# (backup_ro logged in over TCP, SET request.jwt.claims, calls the function) before/after, callers still working as
# anon/authenticated/service_role, verify sabotage, W2b list, rollback (effective privileges = pre-state).
# Usage: sql/tests/run_w2_revoke_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=w2revoke_pg_test
IMG="postgres:17@sha256:b8faeff7712663c2773a190181e1246e37e364b887611c04658c28b44e2408fe"   # same pin as run_backup_ro_local.sh
MIG=security_fixes/2026-11-12_w2_revoke_public_secdef.sql
VER=security_fixes/2026-11-12_w2_revoke_public_secdef_verify_after_apply.sql
RB=security_fixes/2026-11-12_w2_revoke_public_secdef_rollback.sql
FB=security_fixes/2026-11-12_backup_ro_role_fallback_pg_read_all_data.sql
BRB=security_fixes/2026-11-12_backup_ro_rollback.sql
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --network none -e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD=local "$IMG" >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U supabase_admin -d postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
S() { docker exec -i "$C" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q "$@"; }   # superuser
P() { docker exec -i "$C" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }         # Supabase-like postgres
B() { docker exec -i -e PGPASSWORD=ro-local "$C" psql -h 127.0.0.1 -U backup_ro -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
PASSN=0; pass() { PASSN=$((PASSN+1)); echo "PASS $1"; }
fail() { echo "FAIL $1"; exit 1; }
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }
red() { P -At < "$VER" | grep -q "^== ALL OK ==|f|"; }   # verify ran and found a failure (an SQL error is neither)
row() { P -At < "$VER" | grep -F "$1" | head -1; }
F3="to_regprocedure('public.verify_email_token(text,text)'), to_regprocedure('public.wc2026_reset(text)'),
    to_regprocedure('public.wc2026_save(text,integer,integer,integer,integer,integer,text,text)')"
# sorted ACL of the 3 + effective EXECUTE per role: compared before apply and after rollback
acl() { S -At -c "SELECT p.oid::regprocedure, coalesce((SELECT string_agg(x::text, ',' ORDER BY x::text) FROM unnest(p.proacl) x), 'NULL')
                    FROM pg_proc p WHERE p.oid IN ($F3) ORDER BY 1"; }
eff() { S -At -c "SELECT p.oid::regprocedure, r.rolname, has_function_privilege(r.oid, p.oid, 'EXECUTE')
                    FROM pg_proc p, pg_roles r WHERE p.oid IN ($F3)
                     AND r.rolname IN ('anon','authenticated','service_role','postgres','backup_ro','plain_login') ORDER BY 1, 2"; }
pubexec() { S -At -c "SELECT count(*) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                       WHERE p.oid IN ($F3) AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'"; }
reset_data() { S -c "UPDATE public.profiles SET email_verified = false; UPDATE public.wc2026_matches SET score1 = 1, score2 = 0" >/dev/null; }
deny() {  # deny NAME SQL : must fail as backup_ro with permission denied
  local out; if out=$(B <<< "$2" 2>&1); then fail "backup_ro could: $1"; fi
  echo "$out" | grep -q "permission denied for function" && pass "backup_ro denied: $1" || fail "$1: $out"
}
ATTACK_V="SET default_transaction_read_only = off;
SET request.jwt.claims = '{\"sub\":\"00000000-0000-0000-0000-000000000001\"}';
SELECT public.verify_email_token('victim', (SELECT verification_token FROM public.profiles WHERE profile_id = 'victim'))"
ATTACK_R="SET default_transaction_read_only = off;
SELECT public.wc2026_reset((SELECT k FROM public.wc2026_admin LIMIT 1))"
ATTACK_S="SET default_transaction_read_only = off;
SELECT public.wc2026_save((SELECT k FROM public.wc2026_admin LIMIT 1), 1, 9, 9, NULL, NULL, NULL, NULL)"

# ---- Supabase-like stand-in -------------------------------------------------------------------------------
S <<'SQL' >/dev/null
CREATE ROLE postgres LOGIN NOSUPERUSER CREATEROLE BYPASSRLS;
GRANT pg_read_all_data TO postgres WITH ADMIN OPTION;
GRANT pg_signal_backend TO postgres;
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE ROLE plain_login LOGIN;                       -- any other direct login: must lose EXECUTE too
ALTER DATABASE postgres OWNER TO postgres;
GRANT ALL ON SCHEMA public TO postgres WITH GRANT OPTION;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA auth AUTHORIZATION supabase_admin;
CREATE TABLE auth.users (id uuid PRIMARY KEY);
GRANT USAGE ON SCHEMA auth TO postgres; GRANT ALL ON auth.users TO postgres WITH GRANT OPTION;
-- platform-like schema: SECDEF function closed to PUBLIC (must not show up in W2b)
CREATE SCHEMA pgbouncer AUTHORIZATION supabase_admin;
CREATE FUNCTION pgbouncer.get_auth(p_usename text) RETURNS TABLE(username text, password text)
  LANGUAGE sql SECURITY DEFINER AS $$ SELECT p_usename, 'x'::text $$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
SQL
P <<'SQL' >/dev/null
CREATE TABLE public.profiles (profile_id text PRIMARY KEY, email text, email_verified boolean NOT NULL DEFAULT false,
  verification_token text, auth_user_id uuid);
CREATE TABLE public.wc2026_matches (match_no int PRIMARY KEY, score1 int, score2 int);
CREATE TABLE public.wc2026_admin (k text PRIMARY KEY);
CREATE TABLE public.room_members (room_id uuid, profile_id text);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.wc2026_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wc2026_admin ENABLE ROW LEVEL SECURITY; ALTER TABLE public.room_members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
INSERT INTO public.profiles VALUES ('victim', 'v@example.test', false, 'tok-victim', '00000000-0000-0000-0000-000000000001');
INSERT INTO public.wc2026_matches VALUES (1, 1, 0);
INSERT INTO public.wc2026_admin VALUES ('admin-key-local');

-- created BEFORE the default privileges below = proacl NULL (default: PUBLIC + owner), the other shape we may meet
CREATE FUNCTION public.wc2026_save(p_key text, p_match integer, p_score1 integer, p_score2 integer, p_pen1 integer,
  p_pen2 integer, p_name1 text, p_name2 text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM wc2026_admin WHERE k = p_key) THEN RETURN '{"ok":false}'; END IF;
  UPDATE wc2026_matches SET score1 = p_score1, score2 = p_score2 WHERE match_no = p_match;
  RETURN '{"ok":true}';
END $$;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

CREATE FUNCTION public.verify_email_token(p_profile_id text, p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$ BEGIN
  UPDATE profiles SET email_verified = true WHERE profile_id = p_profile_id AND verification_token = p_token;
  IF NOT FOUND THEN RETURN '{"success":false}'; END IF;
  RETURN '{"success":true}';
END $$;
GRANT EXECUTE ON FUNCTION public.verify_email_token(text, text) TO anon, authenticated, service_role;   -- live ACL 11-05
CREATE FUNCTION public.wc2026_reset(p_key text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM wc2026_admin WHERE k = p_key) THEN RETURN '{"ok":false}'; END IF;
  UPDATE wc2026_matches SET score1 = NULL, score2 = NULL;
  RETURN '{"ok":true}';
END $$;
-- the 4 accepted by @ciso (stable, read-only)
CREATE FUNCTION public.get_my_profile_id() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ SELECT profile_id FROM profiles WHERE auth_user_id = nullif(current_setting('request.jwt.claims', true)::jsonb->>'sub', '')::uuid $$;
CREATE FUNCTION public.is_room_member(p_room_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ SELECT EXISTS (SELECT 1 FROM room_members WHERE room_id = p_room_id) $$;
CREATE FUNCTION public.owns_profile(p_profile_id text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ SELECT p_profile_id = get_my_profile_id() $$;
CREATE FUNCTION public.wc2026_get_matches() RETURNS SETOF wc2026_matches LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ SELECT * FROM wc2026_matches $$;
-- closed already (W44 / 30.10 pattern): must stay out of W2b
CREATE FUNCTION public.tb_delete_account(p text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ SELECT '{}'::jsonb $$;
REVOKE ALL ON FUNCTION public.tb_delete_account(text) FROM PUBLIC, anon, authenticated, service_role;
SQL
pass "stand-in: non-superuser postgres owns 3 writing + 4 accepted SECDEF functions, Supabase default privileges"
ACL_BEFORE=$(acl); EFF_BEFORE=$(eff)
echo "$ACL_BEFORE" | grep -q "wc2026_save.*|NULL$" && echo "$ACL_BEFORE" | grep -q 'verify_email_token.*=X/postgres' \
  && pass "pre-state: wc2026_save proacl NULL, verify_email_token with PUBLIC + explicit grants" || fail "pre-state: $ACL_BEFORE"

# ---- verify before apply ----------------------------------------------------------------------------------
red && pass "verify before apply: == ALL OK == false" || fail "verify before apply not false"
row "W2b:" | grep -q "|f|7 total, not accepted: public.verify_email_token(p_profile_id text, p_token text), public.wc2026_reset(p_key text), public.wc2026_save(" \
  && pass "verify before apply: W2b = 7 (as on production), the 3 writing ones not accepted" || fail "W2b before: $(row 'W2b:')"
row "INFO: ACL" | grep -q "acl=NULL (default)" && pass "verify INFO ACL row usable as pre-state snapshot" || fail "info acl"

# ---- guards + atomicity -------------------------------------------------------------------------------------
if G=$(S < "$MIG" 2>&1); then fail "ran as superuser"; fi
echo "$G" | grep -q "run as postgres" && [ "$(pubexec)" = 3 ] && pass "guard: refuses any user other than postgres, nothing changed" || fail "guard user: $G"

S -c "ALTER FUNCTION public.wc2026_reset(text) RENAME TO wc2026_reset_x" >/dev/null
if G=$(P < "$MIG" 2>&1); then fail "missing function accepted"; fi
echo "$G" | grep -q "wc2026_reset(text) not found" && [ "$(pubexec)" = 2 ] && pass "guard: missing signature aborts, nothing changed" || fail "guard missing: $G"
S -c "ALTER FUNCTION public.wc2026_reset_x(text) RENAME TO wc2026_reset" >/dev/null

S -c "ALTER FUNCTION public.wc2026_reset(text) SECURITY INVOKER" >/dev/null
if G=$(P < "$MIG" 2>&1); then fail "non-SECDEF accepted"; fi
echo "$G" | grep -q "is not SECURITY DEFINER" && [ "$(pubexec)" = 3 ] && pass "guard: changed function (no longer SECDEF) aborts" || fail "guard secdef: $G"
S -c "ALTER FUNCTION public.wc2026_reset(text) SECURITY DEFINER" >/dev/null

S -c "ALTER FUNCTION public.wc2026_reset(text) OWNER TO supabase_admin" >/dev/null
if G=$(P < "$MIG" 2>&1); then fail "non-owner apply accepted"; fi
[ "$(pubexec)" = 3 ] && [ "$(acl | grep -v wc2026_reset)" = "$(echo "$ACL_BEFORE" | grep -v wc2026_reset)" ] \
  && pass "owner not postgres: REVOKE is only a warning, post-check/GRANT aborts the whole transaction, nothing changed" || fail "owner: $G"
S -c "ALTER FUNCTION public.wc2026_reset(text) OWNER TO postgres" >/dev/null
# ownership change re-wrote grantor of the ACL; restore the exact pre-state shape for the later comparisons
S -c "REVOKE ALL ON FUNCTION public.wc2026_reset(text) FROM PUBLIC, anon, authenticated, service_role" >/dev/null
P -c "GRANT EXECUTE ON FUNCTION public.wc2026_reset(text) TO PUBLIC, anon, authenticated, service_role" >/dev/null
[ "$(acl)" = "$ACL_BEFORE" ] && pass "stand-in restored to pre-state after owner test" || fail "restore: $(acl)"

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && fail "forced error not raised" || true
[ "$(acl)" = "$ACL_BEFORE" ] && pass "atomic: forced error before COMMIT, ACL unchanged" || fail "partial apply"

# ---- order 1: W2 before backup_ro exists ----------------------------------------------------------------------
P < "$MIG" >/dev/null && pass "apply (no backup_ro yet)" || fail "apply 1"
green && pass "verify: == ALL OK ==" || { P -At < "$VER"; fail "verify 1"; }
row "backup_ro (if it exists)" | grep -q "|t|role does not exist yet" && pass "verify: backup_ro row passes without the role" || fail "bro row"
row "W2b:" | grep -q "|t|4 total, not accepted: $" && pass "W2b after apply: exactly the 4 accepted" || fail "W2b after: $(row 'W2b:')"
if G=$(P < "$MIG" 2>&1); then fail "re-apply accepted"; fi
echo "$G" | grep -q "nothing to do" && pass "re-apply aborts" || fail "re-apply: $G"
P < "$RB" >/dev/null && [ "$(acl | grep -v wc2026_save)" = "$(echo "$ACL_BEFORE" | grep -v wc2026_save)" ] && [ "$(eff)" = "$EFF_BEFORE" ] \
  && pass "rollback (order 1): proacl of verify_email_token/wc2026_reset identical, effective EXECUTE identical" || fail "rollback 1"

# ---- order 2: backup_ro first (fallback migration, as planned), the real attack path ---------------------------
P < "$FB" >/dev/null && S -c "ALTER ROLE backup_ro PASSWORD 'ro-local'" >/dev/null && pass "backup_ro created by the real fallback migration, local password"
[ "$(B -At -c 'select current_user')" = backup_ro ] || fail "login backup_ro"
reset_data
B <<< "$ATTACK_V" >/dev/null && [ "$(S -At -c "select email_verified from public.profiles where profile_id='victim'")" = t ] \
  && pass "BEFORE W2 (vector reproduced): backup_ro + forged request.jwt.claims verifies a victim's e-mail" || fail "attack v not reproduced"
B <<< "$ATTACK_S" >/dev/null && [ "$(S -At -c "select score1 from public.wc2026_matches where match_no=1")" = 9 ] \
  && pass "BEFORE W2: backup_ro writes World Cup results with the admin key it can read" || fail "attack s"
B <<< "$ATTACK_R" >/dev/null && [ "$(S -At -c "select count(*) from public.wc2026_matches where score1 is null")" = 1 ] \
  && pass "BEFORE W2: backup_ro resets World Cup results" || fail "attack r"
EFF_BEFORE2=$(eff); ACL_BEFORE2=$(acl)
row "backup_ro (if it exists)" | grep -q "|f|role exists" && pass "verify before W2: backup_ro row false while the role can execute" || fail "bro before"

P < "$MIG" >/dev/null && pass "apply (backup_ro exists)" || fail "apply 2"
green && pass "verify: == ALL OK == (incl. backup_ro row)" || { P -At < "$VER"; fail "verify 2"; }
reset_data
deny "verify_email_token (forged jwt claims)" "$ATTACK_V"
deny "wc2026_save" "$ATTACK_S"
deny "wc2026_reset" "$ATTACK_R"
[ "$(S -At -c "select email_verified::text || score1 from public.profiles, public.wc2026_matches")" = false1 ] && pass "nothing written by backup_ro after W2" || fail "written"
for r in plain_login; do
  out=$(S -c "SET ROLE $r; SELECT public.wc2026_reset('admin-key-local')" 2>&1) && fail "$r could execute" || true
  echo "$out" | grep -q "permission denied for function" && pass "any other login role ($r) denied" || fail "$r: $out"
done

# ---- callers keep working ---------------------------------------------------------------------------------------
for r in anon authenticated service_role; do
  [ "$(S -At -c "SET ROLE $r; SELECT public.verify_email_token('victim', 'tok-victim')->>'success'")" = true ] || fail "$r verify_email_token"
  [ "$(S -At -c "SET ROLE $r; SELECT public.wc2026_save('admin-key-local', 1, 2, 2, NULL, NULL, NULL, NULL)->>'ok'")" = true ] || fail "$r save"
  [ "$(S -At -c "SET ROLE $r; SELECT public.wc2026_reset('wrong-key')->>'ok'")" = false ] || fail "$r reset"
  pass "$r still executes the 3 (verify_email_token as the web page / MCP anon client does)"
done
for f in "get_my_profile_id()" "is_room_member(NULL::uuid)" "owns_profile('x')"; do
  S -At -c "SET ROLE anon; SELECT public.$f" >/dev/null || fail "anon $f"
done
pass "the 4 accepted functions untouched (anon executes the RLS helpers, wc2026_get_matches still PUBLIC)"

# ---- verify sabotage --------------------------------------------------------------------------------------------
sab() { P -c "$2" >/dev/null; red || fail "verify missed: $1"; P -c "$3" >/dev/null; green || fail "restore after $1"; pass "verify false on sabotage: $1"; }
sab "EXECUTE back to PUBLIC"   "GRANT EXECUTE ON FUNCTION public.wc2026_reset(text) TO PUBLIC" "REVOKE EXECUTE ON FUNCTION public.wc2026_reset(text) FROM PUBLIC"
sab "anon lost EXECUTE"        "REVOKE EXECUTE ON FUNCTION public.verify_email_token(text,text) FROM anon" "GRANT EXECUTE ON FUNCTION public.verify_email_token(text,text) TO anon"
sab "extra grantee"            "GRANT EXECUTE ON FUNCTION public.wc2026_save(text,integer,integer,integer,integer,integer,text,text) TO plain_login" \
                               "REVOKE EXECUTE ON FUNCTION public.wc2026_save(text,integer,integer,integer,integer,integer,text,text) FROM plain_login"
sab "backup_ro got EXECUTE"    "GRANT EXECUTE ON FUNCTION public.wc2026_reset(text) TO backup_ro" "REVOKE EXECUTE ON FUNCTION public.wc2026_reset(text) FROM backup_ro"
S -c "CREATE SCHEMA private; CREATE FUNCTION private.leak() RETURNS text LANGUAGE sql SECURITY DEFINER AS \$\$ SELECT 'x' \$\$" >/dev/null
red || fail "verify missed a PUBLIC SECDEF function in a schema without PUBLIC USAGE"
row "W2b:" | grep -q "not accepted: private.leak()" && pass "W2b covers all schemas (no USAGE filter): private.leak() flagged" || fail "W2b schema: $(row 'W2b:')"
S -c "DROP SCHEMA private CASCADE" >/dev/null; green && pass "green again after removing it" || fail "not green"

# ---- rollback ---------------------------------------------------------------------------------------------------
P < "$RB" >/dev/null && pass "rollback applies"
[ "$(pubexec)" = 3 ] && [ "$(eff)" = "$EFF_BEFORE2" ] && pass "rollback: effective EXECUTE for every role = pre-state (backup_ro can execute again)" || fail "rb eff"
[ "$(acl | grep -v wc2026_save)" = "$(echo "$ACL_BEFORE2" | grep -v wc2026_save)" ] && pass "rollback: proacl of verify_email_token/wc2026_reset identical to pre-state" || fail "rb acl"
acl | grep "wc2026_save" | grep -q "=X/postgres" && pass "rollback: wc2026_save (was NULL) = PUBLIC + owner + explicit anon/authenticated/service_role, same effect (documented)" || fail "rb save"
red && pass "verify false after rollback" || fail "verify not false after rollback"
if G=$(P < "$RB" 2>&1); then fail "rollback twice"; fi
echo "$G" | grep -q "W2 not applied" && pass "rollback twice aborts" || fail "rb2: $G"
if G=$(S < "$RB" 2>&1); then fail "rollback as superuser"; fi
echo "$G" | grep -q "run as postgres" && pass "rollback guard: refuses any user other than postgres" || fail "rb guard: $G"

# ---- re-apply after rollback, then remove backup_ro (cleanup like production rollback order) ------------------
P < "$MIG" >/dev/null && green && pass "re-apply after rollback: == ALL OK ==" || fail "re-apply"
P < "$BRB" >/dev/null && green && pass "backup_ro rollback leaves W2 green" || fail "brb"
echo "ALL $PASSN PASS"
