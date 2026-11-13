#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker (--network none), never points at Supabase. Supabase-like stand-in: superuser
# supabase_admin, NON-superuser "postgres" (CREATEROLE, BYPASSRLS, pg_read_all_data WITH ADMIN OPTION), auth schema
# owned by supabase_auth_admin with the 8 token/session tables, RLS on, a vault table. Then:
# precheck, guards (no grant option, wrong user, re-apply), atomicity, apply, verify file, a real pg_dump as
# backup_ro with the exact flags of CEO scripts/backup-ai-first.sh + restore + row counts, everything backup_ro must
# NOT be able to do, why BYPASSRLS and SELECT on token tables are required, default privileges, new auth table
# (fails loud), verify sabotage, rollback, fallback variant (pg_read_all_data) + rollback.
# Usage: sql/tests/run_backup_ro_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=backupro_pg_test
IMG="postgres:17@sha256:b8faeff7712663c2773a190181e1246e37e364b887611c04658c28b44e2408fe"   # same pin as the CEO script
MIG=security_fixes/2026-11-12_backup_ro_role.sql
FB=security_fixes/2026-11-12_backup_ro_role_fallback_pg_read_all_data.sql
RB=security_fixes/2026-11-12_backup_ro_rollback.sql
VER=security_fixes/2026-11-12_backup_ro_verify_after_apply.sql
PRE=security_fixes/2026-11-12_backup_ro_precheck.sql
EXCL="auth.refresh_tokens auth.sessions auth.mfa_amr_claims auth.one_time_tokens auth.flow_state auth.mfa_challenges public.mcp_client_sessions public.mcp_sessions"
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
role() { S -At -c "select count(*) from pg_roles where rolname='backup_ro'"; }
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }
pre_a() { P -At < "$PRE" | grep '^variant A possible' | cut -d'|' -f2; }
XD=""; for x in $EXCL; do XD="$XD --exclude-table-data=$x"; done
dump() { docker exec -e PGPASSWORD=ro-local "$C" sh -c "pg_dump -h 127.0.0.1 -U backup_ro -d postgres -Fc -Z 6 -n public -n auth $XD -f /tmp/b.dump" 2>&1; }
deny() {  # deny NAME SQL : must fail as backup_ro with permission denied / read-only
  local out; if out=$(B -c "$2" 2>&1); then fail "backup_ro could: $1"; fi
  echo "$out" | grep -qE "permission denied|must be|read-only transaction|cannot execute" && pass "backup_ro denied: $1" || fail "$1: $out"
}

# ---- Supabase-like stand-in -------------------------------------------------------------------------------
S <<'SQL' >/dev/null
CREATE ROLE postgres LOGIN NOSUPERUSER CREATEROLE BYPASSRLS;
GRANT pg_read_all_data TO postgres WITH ADMIN OPTION;
GRANT pg_signal_backend TO postgres;
CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT;
CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
ALTER DATABASE postgres OWNER TO postgres;          -- postgres = pg_database_owner, owns schema public's grants
GRANT ALL ON SCHEMA public TO postgres WITH GRANT OPTION;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA auth AUTHORIZATION supabase_auth_admin;
CREATE SCHEMA vault AUTHORIZATION supabase_admin;
CREATE TABLE vault.secrets (id serial PRIMARY KEY, name text, secret text);
INSERT INTO vault.secrets (name, secret) VALUES ('resend_api_key', 'encrypted-blob');
GRANT USAGE ON SCHEMA vault TO postgres; GRANT SELECT ON vault.secrets TO postgres;
SET ROLE supabase_auth_admin;
CREATE TABLE auth.users (id uuid PRIMARY KEY, email text);
CREATE TABLE auth.sessions (id uuid PRIMARY KEY, user_id uuid REFERENCES auth.users ON DELETE CASCADE);
CREATE TABLE auth.refresh_tokens (id bigserial PRIMARY KEY, token text, session_id uuid REFERENCES auth.sessions ON DELETE CASCADE);
CREATE TABLE auth.mfa_amr_claims (id uuid PRIMARY KEY, session_id uuid REFERENCES auth.sessions ON DELETE CASCADE);
CREATE TABLE auth.one_time_tokens (id uuid PRIMARY KEY, user_id uuid REFERENCES auth.users ON DELETE CASCADE, token_hash text);
CREATE TABLE auth.flow_state (id uuid PRIMARY KEY, auth_code text);
CREATE TABLE auth.saml_relay_states (id uuid PRIMARY KEY, flow_state_id uuid REFERENCES auth.flow_state ON DELETE CASCADE);
CREATE TABLE auth.mfa_factors (id uuid PRIMARY KEY, user_id uuid REFERENCES auth.users ON DELETE CASCADE);
CREATE TABLE auth.mfa_challenges (id uuid PRIMARY KEY, factor_id uuid REFERENCES auth.mfa_factors ON DELETE CASCADE);
ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY; ALTER TABLE auth.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.refresh_tokens ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA auth TO postgres WITH GRANT OPTION;
GRANT ALL ON ALL TABLES IN SCHEMA auth TO postgres WITH GRANT OPTION;
GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO postgres WITH GRANT OPTION;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-000000000001', 'a@example.test'), ('00000000-0000-0000-0000-000000000002', 'b@example.test');
INSERT INTO auth.sessions VALUES ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001');
INSERT INTO auth.refresh_tokens (token, session_id) VALUES ('live-refresh-token', '10000000-0000-0000-0000-000000000001');
INSERT INTO auth.flow_state VALUES ('20000000-0000-0000-0000-000000000001', 'code');
INSERT INTO auth.saml_relay_states VALUES ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001');
RESET ROLE;
SQL
P <<'SQL' >/dev/null
CREATE TABLE public.profiles (id serial PRIMARY KEY, profile_id text UNIQUE, auth_user_id uuid REFERENCES auth.users);
CREATE TABLE public.rooms (id uuid PRIMARY KEY, name text);
CREATE TABLE public.mcp_sessions (id uuid PRIMARY KEY, token text);
CREATE TABLE public.mcp_client_sessions (id uuid PRIMARY KEY, secret_hash text);
CREATE VIEW public.profile_names WITH (security_invoker = true) AS SELECT profile_id FROM public.profiles;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mcp_sessions ENABLE ROW LEVEL SECURITY; ALTER TABLE public.mcp_client_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY own ON public.profiles FOR SELECT TO authenticated USING (false);
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO service_role;
INSERT INTO public.profiles (profile_id, auth_user_id) VALUES ('przemek_(snow)', '00000000-0000-0000-0000-000000000001'), ('x', NULL);
INSERT INTO public.rooms VALUES ('40000000-0000-0000-0000-000000000001', 'SNOW Sync');
INSERT INTO public.mcp_sessions VALUES ('50000000-0000-0000-0000-000000000001', 'live-mcp-token');
INSERT INTO public.mcp_client_sessions VALUES ('60000000-0000-0000-0000-000000000001', 'live-client-secret');
CREATE FUNCTION public.tb_delete_account(p text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ BEGIN DELETE FROM public.profiles WHERE profile_id = p; RETURN '{}'::jsonb; END $$;
REVOKE ALL ON FUNCTION public.tb_delete_account(text) FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.some_rpc() RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$ SELECT 1 $$;
SQL
pass "stand-in: non-superuser postgres, auth owned by supabase_auth_admin, 8 token/session tables, RLS, vault"

# ---- precheck + guards -----------------------------------------------------------------------------------
[ "$(pre_a)" = t ] && pass "precheck: variant A possible" || { P -At < "$PRE"; fail "precheck"; }
P -At < "$PRE" | grep -q '^INFO: SECURITY DEFINER.*|1: public.some_rpc()' && pass "precheck: lists SECDEF functions PUBLIC may execute (tb_delete_account not among them)" || { P -At < "$PRE"; fail "precheck info"; }

S -c "REVOKE GRANT OPTION FOR ALL ON auth.flow_state FROM postgres" >/dev/null
[ "$(pre_a)" = f ] && pass "precheck: false when postgres lacks GRANT OPTION on one auth table" || fail "precheck sabotage"
if G=$(P < "$MIG" 2>&1); then fail "guard let a missing grant option through"; fi
echo "$G" | grep -q "no GRANT OPTION on 1 relation.*auth.flow_state" && [ "$(role)" = 0 ] && pass "guard: missing GRANT OPTION aborts, role not created" || fail "guard: $G"
S -c "GRANT ALL ON auth.flow_state TO postgres WITH GRANT OPTION" >/dev/null

if G=$(S < "$MIG" 2>&1); then fail "ran as superuser"; fi
echo "$G" | grep -q "run as postgres" && [ "$(role)" = 0 ] && pass "guard: refuses any user other than postgres" || fail "guard user: $G"

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && fail "forced error not raised" || true
[ "$(role)" = 0 ] && [ "$(S -At -c "select count(*) from pg_default_acl")" = 0 ] && pass "atomic: forced error before COMMIT, no role, no default privileges" || fail "partial apply"

# ---- apply + verify --------------------------------------------------------------------------------------
P < "$MIG" >/dev/null
[ "$(role)" = 1 ] && pass "apply: role created" || fail "apply"
green && pass "verify file: all checks ok" || { P -At < "$VER"; fail "verify"; }
P -At < "$VER" | grep -q '^INFO: SECURITY DEFINER.*|t|1: public.some_rpc' && pass "verify: INFO row names the PUBLIC-executable SECDEF function" || fail "verify info"
if G=$(P < "$MIG" 2>&1); then fail "re-apply accepted"; fi
echo "$G" | grep -q "already exists" && pass "re-apply aborts" || fail "re-apply: $G"

S -c "ALTER ROLE backup_ro PASSWORD 'ro-local'" >/dev/null    # local only; production: psql \password
[ "$(B -At -c 'select current_user')" = backup_ro ] && pass "login as backup_ro over TCP with password (scram)" || fail "login"
[ "$(B -At -c 'show default_transaction_read_only')" = on ] && pass "session starts read-only" || fail "read-only GUC"

# ---- the real dump, same flags as backup-ai-first.sh -------------------------------------------------------
out=$(dump) && pass "pg_dump as backup_ro: -Fc -Z 6 -n public -n auth + 8 --exclude-table-data, rc 0" || fail "pg_dump: $out"
LST=$(docker exec "$C" pg_restore -l /tmp/b.dump)
leak=""; for x in $EXCL; do grep -qE "TABLE DATA ${x%%.*} ${x#*.} " <<< "$LST" && leak="$leak $x"; done
[ -z "$leak" ] && pass "pg_restore -l: no TABLE DATA for the 8 token/session tables" || fail "leak:$leak"
for x in $EXCL; do grep -qE "TABLE ${x%%.*} ${x#*.} " <<< "$LST" || fail "schema of $x missing"; done
pass "schema of all 8 excluded tables is in the dump (FKs keep working)"
grep -q "FK CONSTRAINT auth saml_relay_states saml_relay_states_flow_state_id_fkey" <<< "$LST" && pass "FK saml_relay_states -> flow_state kept" || fail "FK"
newdb() { S -c "DROP DATABASE IF EXISTS restore_test" -c "CREATE DATABASE restore_test" >/dev/null
  docker exec "$C" psql -U supabase_admin -d restore_test -q -c "DROP SCHEMA public CASCADE" >/dev/null; }   # as the script does
# side finding (pre-existing, not caused by backup_ro): data of auth.flow_state is excluded, but auth.saml_relay_states
# (data kept) points at it. A relay-state row makes the restore fail on the FK; the script then says ALARM and rm's the
# dump (loud, not silent). Production uses no SAML, so the table is expected empty -> check in the report.
newdb; if out=$(docker exec "$C" pg_restore -U supabase_admin -d restore_test --no-owner --no-acl /tmp/b.dump 2>&1); then fail "FK finding not reproduced"; fi
echo "$out" | grep -q 'violates foreign key constraint "saml_relay_states_flow_state_id_fkey"' && pass "side finding reproduced: saml_relay_states row + excluded flow_state data = restore FK error (script: ALARM)" || fail "fk: $out"
S -c "DELETE FROM auth.saml_relay_states" >/dev/null; out=$(dump) || fail "re-dump: $out"
newdb; docker exec "$C" pg_restore -U supabase_admin -d restore_test --no-owner --no-acl /tmp/b.dump 2>&1 && pass "restore (no SAML rows, like production): pg_restore rc 0, no errors" || fail "restore"
Q="SELECT 'auth.users', count(*) FROM auth.users UNION ALL SELECT 'public.profiles', count(*) FROM public.profiles UNION ALL SELECT 'public.rooms', count(*) FROM public.rooms ORDER BY 1"
RESTORED=$(docker exec "$C" psql -U supabase_admin -d restore_test -At -F'|' -c "$Q")
PROD=$(B -At -F'|' -c "BEGIN READ ONLY; $Q; COMMIT;" | grep '|')
[ "$RESTORED" = "$PROD" ] && pass "row counts as backup_ro (BEGIN READ ONLY, like the script) = restored: $(echo $PROD)" || fail "counts: $PROD vs $RESTORED"
[ "$(docker exec "$C" psql -U supabase_admin -d restore_test -At -c "select count(*) from auth.refresh_tokens")" = 0 ] && pass "restored copy has no refresh tokens" || fail "tokens restored"

# ---- what backup_ro must not do ----------------------------------------------------------------------------
deny "INSERT public.profiles"        "SET default_transaction_read_only = off; INSERT INTO public.profiles (profile_id) VALUES ('evil')"
deny "UPDATE auth.users"             "SET default_transaction_read_only = off; UPDATE auth.users SET email = 'x'"
deny "DELETE public.rooms"           "SET default_transaction_read_only = off; DELETE FROM public.rooms"
deny "TRUNCATE public.rooms"         "SET default_transaction_read_only = off; TRUNCATE public.rooms"
deny "CREATE TABLE in public"        "SET default_transaction_read_only = off; CREATE TABLE public.evil (i int)"
deny "CREATE SCHEMA"                 "SET default_transaction_read_only = off; CREATE SCHEMA evil"
deny "nextval on a sequence"         "SET default_transaction_read_only = off; SELECT nextval('public.profiles_id_seq')"
deny "tb_delete_account"             "SET default_transaction_read_only = off; SELECT public.tb_delete_account('x')"
deny "read vault.secrets"            "SELECT * FROM vault.secrets"
deny "SET ROLE postgres"             "SET ROLE postgres"
deny "CREATE ROLE"                   "SET default_transaction_read_only = off; CREATE ROLE evil"
deny "ALTER own role (BYPASSRLS off->on games, password)" "ALTER ROLE backup_ro CONNECTION LIMIT 100"
deny "write in default read-only session" "INSERT INTO public.profiles (profile_id) VALUES ('evil')"
[ "$(S -At -c "select count(*) from public.profiles where profile_id='evil'")" = 0 ] && pass "nothing written" || fail "write happened"

# ---- why BYPASSRLS and SELECT on token tables are required (evidence for the report) -------------------------
S -c "ALTER ROLE backup_ro NOBYPASSRLS" >/dev/null
out=$(dump) && fail "dump worked without BYPASSRLS" || true
echo "$out" | grep -q "row-level security" && pass "evidence: without BYPASSRLS pg_dump aborts (row-level security)" || fail "no-bypass: $out"
S -c "ALTER ROLE backup_ro BYPASSRLS" >/dev/null
P -c "REVOKE SELECT ON auth.sessions FROM backup_ro" >/dev/null
out=$(dump) && fail "dump worked without SELECT on auth.sessions" || true
echo "$out" | grep -q "permission denied for table sessions" && echo "$out" | grep -q "LOCK TABLE" \
  && pass "evidence: without SELECT on a data-excluded token table pg_dump aborts at LOCK TABLE" || fail "lock: $out"
P -c "GRANT SELECT ON auth.sessions TO backup_ro" >/dev/null
green && pass "back to green after evidence runs" || fail "not green"

# ---- default privileges, new auth table ---------------------------------------------------------------------
P -c "CREATE TABLE public.new_feature (id bigserial PRIMARY KEY, v text); INSERT INTO public.new_feature (v) VALUES ('a')" >/dev/null
[ "$(B -At -c 'select count(*) from public.new_feature')" = 1 ] && dump >/dev/null && pass "new postgres table in public: readable by default privileges, dump OK" || fail "default privileges"
S -c "SET ROLE supabase_auth_admin; CREATE TABLE auth.new_auth_thing (id int PRIMARY KEY); GRANT ALL ON auth.new_auth_thing TO postgres WITH GRANT OPTION" >/dev/null
out=$(dump) && fail "dump silently worked over an unreadable new auth table" || true
echo "$out" | grep -q "permission denied for table new_auth_thing" && pass "new auth table (GoTrue upgrade): dump fails LOUD at LOCK, no partial copy" || fail "new auth: $out"
green && fail "verify stayed green with an unreadable auth table" || pass "verify: false on the unreadable auth table"
P -c "GRANT SELECT ON ALL TABLES IN SCHEMA auth TO backup_ro; GRANT SELECT ON ALL SEQUENCES IN SCHEMA auth TO backup_ro" >/dev/null
dump >/dev/null && green && pass "fix from the migration header (2 GRANT lines) = dump OK, verify green" || fail "auth fix"

# ---- verify sabotage --------------------------------------------------------------------------------------
sab() { P -c "$2" >/dev/null; if green; then fail "verify missed: $1"; fi; P -c "$3" >/dev/null; green || fail "restore after $1"; pass "verify false on sabotage: $1"; }
sab "INSERT grant"           "GRANT INSERT ON public.rooms TO backup_ro"        "REVOKE INSERT ON public.rooms FROM backup_ro"
sab "sequence USAGE"         "GRANT USAGE ON SEQUENCE public.profiles_id_seq TO backup_ro" "REVOKE USAGE ON SEQUENCE public.profiles_id_seq FROM backup_ro"
sab "CREATE on public"       "GRANT CREATE ON SCHEMA public TO backup_ro"       "REVOKE CREATE ON SCHEMA public FROM backup_ro"
sab "pg_read_all_data"       "GRANT pg_read_all_data TO backup_ro"              "REVOKE pg_read_all_data FROM backup_ro"
sab "connection limit"       "ALTER ROLE backup_ro CONNECTION LIMIT -1"         "ALTER ROLE backup_ro CONNECTION LIMIT 3"
sab "read-only GUC removed"  "ALTER ROLE backup_ro RESET default_transaction_read_only" "ALTER ROLE backup_ro SET default_transaction_read_only = on"
sab "tb_delete_account EXECUTE" "GRANT EXECUTE ON FUNCTION public.tb_delete_account(text) TO backup_ro" "REVOKE EXECUTE ON FUNCTION public.tb_delete_account(text) FROM backup_ro"
S -c "GRANT SELECT ON vault.secrets TO backup_ro; GRANT USAGE ON SCHEMA vault TO backup_ro" >/dev/null
green && fail "verify missed vault" || true
S -c "REVOKE SELECT ON vault.secrets FROM backup_ro; REVOKE USAGE ON SCHEMA vault FROM backup_ro" >/dev/null; green && pass "verify false on sabotage: vault readable" || fail "vault restore"

# ---- rollback ---------------------------------------------------------------------------------------------
P < "$RB" >/dev/null
[ "$(role)" = 0 ] && [ "$(S -At -c "select count(*) from pg_default_acl")" = 0 ] && pass "rollback: role and default privileges gone" || fail "rollback"
green && fail "verify green without the role" || pass "verify false without the role"
if G=$(P < "$RB" 2>&1); then fail "rollback twice"; fi; echo "$G" | grep -q "does not exist" && pass "rollback twice aborts" || fail "rb2: $G"
[ "$(S -At -c "select count(*) from public.profiles")" = 2 ] && pass "data untouched" || fail "data"

# ---- fallback variant -------------------------------------------------------------------------------------
P < "$FB" >/dev/null && pass "fallback (pg_read_all_data) applies" || fail "fallback apply"
S -c "ALTER ROLE backup_ro PASSWORD 'ro-local'" >/dev/null
dump >/dev/null && pass "fallback: pg_dump OK" || fail "fallback dump"
FAILED=$(P -At < "$VER" | awk -F'|' '$2=="f"{print $1}' | grep -v '^== ALL OK ==' | sort | tr '\n' ';')
[ "$FAILED" = "[A] default privileges: new postgres tables+sequences in public readable;[A] member of no role (no pg_read_all_data);[A] no SELECT on any relation outside public/auth (vault, storage, ...);" ] \
  && pass "fallback: verify false only on the 3 [A] rows" || fail "fallback verify: $FAILED"
[ "$(B -At -c 'select count(*) from vault.secrets')" = 1 ] && pass "fallback reads vault (why it is the fallback, not the default)" || fail "fallback vault"
deny "fallback: INSERT"            "SET default_transaction_read_only = off; INSERT INTO public.profiles (profile_id) VALUES ('evil')"
deny "fallback: tb_delete_account" "SET default_transaction_read_only = off; SELECT public.tb_delete_account('x')"
P < "$RB" >/dev/null; [ "$(role)" = 0 ] && pass "rollback of the fallback" || fail "fallback rollback"
S -At -c "select count(*) from pg_auth_members m join pg_roles r on r.oid=m.member where r.rolname='backup_ro'" | grep -q '^0$' && pass "no membership left" || fail "membership left"

echo "ALL $PASSN PASS"
