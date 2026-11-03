#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker, never points at Supabase.
# Runs security_fixes/2026-10-30_privacy_retention.sql on a stand-in of the live schema
# (tests/privacy_base_schema.sql), then retention + account-deletion assertions, the verify file,
# the verify file turning false on each sabotage, the smoke file, re-apply (must abort), rollback and
# atomicity with a forced error before COMMIT.
# Usage: sql/tests/run_privacy_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=privacy_pg_test
MIG=security_fixes/2026-10-30_privacy_retention.sql
RB=security_fixes/2026-10-30_privacy_retention_rollback.sql
VER=security_fixes/2026-10-30_privacy_retention_verify_after_apply.sql
SMOKE=security_fixes/2026-10-30_privacy_retention_smoke.sql
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P()  { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
STATE="select count(*) from pg_trigger where tgname='tb_retention'"
P < tests/privacy_base_schema.sql >/dev/null

echo "== atomicity: forced error just before COMMIT"
FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && { echo "FAIL forced error not raised"; exit 1; } || true
[ "$(P -At -c "$STATE")" = 0 ] && [ -z "$(P -At -c "select to_regprocedure('public.tb_delete_account(text)')")" ] \
  && echo "PASS atomic: nothing changed" || { echo "FAIL partial apply"; exit 1; }

echo "== apply"
P < "$MIG" >/dev/null
OUT=$(P -At < tests/privacy_after.sql 2>&1) || { echo "$OUT" | tail -5; echo "FAIL assertions stopped on an SQL error"; exit 1; }
echo "$OUT" | sed 's/^psql:[^ ]* NOTICE:  //' | grep -E "PASS|FAIL|INFO|ERROR"
echo "$OUT" | grep -qE "FAIL|ERROR" && { echo "FAIL assertions"; exit 1; }
P -At < "$VER" | grep -q "^== ALL OK ==|t$" && echo "PASS verify file: all checks ok" || { echo "FAIL verify file"; P -At < "$VER"; exit 1; }

echo "== verify file must turn false on each sabotage (@ciso W3)"
TRG="tb_retention AFTER INSERT ON public.rate_limits FOR EACH STATEMENT EXECUTE FUNCTION public.tb_retention_cleanup()"
sabotage() {  # name, break, restore
  P -c "$2" >/dev/null
  if P -At < "$VER" | grep -q "^== ALL OK ==|t$"; then echo "FAIL verify stayed green: $1"; exit 1; else echo "PASS verify false: $1"; fi
  P -c "$3" >/dev/null
}
sabotage "trigger disabled" "ALTER TABLE public.rate_limits DISABLE TRIGGER tb_retention" "ALTER TABLE public.rate_limits ENABLE TRIGGER tb_retention"
sabotage "trigger fires BEFORE" "CREATE OR REPLACE TRIGGER tb_retention BEFORE INSERT ON public.rate_limits FOR EACH STATEMENT EXECUTE FUNCTION public.tb_retention_cleanup()" "CREATE OR REPLACE TRIGGER $TRG"
sabotage "trigger per row" "CREATE OR REPLACE TRIGGER tb_retention AFTER INSERT ON public.rate_limits FOR EACH ROW EXECUTE FUNCTION public.tb_retention_cleanup()" "CREATE OR REPLACE TRIGGER $TRG"
sabotage "trigger bound to another function" "CREATE OR REPLACE TRIGGER tb_retention AFTER INSERT ON public.rate_limits FOR EACH STATEMENT EXECUTE FUNCTION public.audit_trigger_func()" "CREATE OR REPLACE TRIGGER $TRG"
sabotage "cleanup without pinned search_path" "ALTER FUNCTION public.tb_retention_cleanup() RESET search_path" "ALTER FUNCTION public.tb_retention_cleanup() SET search_path TO 'public', 'pg_temp'"
sabotage "delete_account without pinned search_path" "ALTER FUNCTION public.tb_delete_account(text) RESET search_path" "ALTER FUNCTION public.tb_delete_account(text) SET search_path TO 'public', 'pg_temp'"
sabotage "delete_account owned by another role" "ALTER FUNCTION public.tb_delete_account(text) OWNER TO anon" "ALTER FUNCTION public.tb_delete_account(text) OWNER TO postgres"
sabotage "service_role may execute cleanup" "GRANT EXECUTE ON FUNCTION public.tb_retention_cleanup() TO service_role" "REVOKE EXECUTE ON FUNCTION public.tb_retention_cleanup() FROM service_role"
sabotage "row with NULL created_at" "INSERT INTO public.rate_limits (user_id, action_type, created_at) VALUES ('w3', 'null', NULL)" "DELETE FROM public.rate_limits WHERE user_id = 'w3'"
P -At < "$VER" | grep -q "^== ALL OK ==|t$" && echo "PASS verify green again after every restore" || { echo "FAIL restore"; P -At < "$VER"; exit 1; }

echo "== smoke file: proves cleanup fires, leaves nothing behind"
SMOKE_ROWS="select count(*) from public.rate_limits where user_id = '__retention_smoke__'"
BEFORE=$(P -At -c "select count(*) from public.rate_limits")
SM=$(P < "$SMOKE" 2>&1 || true)
echo "$SM" | grep -q "RETENTION_SMOKE_OK" && [ "$(P -At -c "$SMOKE_ROWS")" = 0 ] && [ "$(P -At -c "select count(*) from public.rate_limits")" = "$BEFORE" ] \
  && echo "PASS smoke: OK with the trigger on, no rows left" || { echo "FAIL smoke: $SM"; exit 1; }
P -c "ALTER TABLE public.rate_limits DISABLE TRIGGER tb_retention" >/dev/null
SM=$(P < "$SMOKE" 2>&1 || true)
echo "$SM" | grep -q "RETENTION_SMOKE_FAIL" && [ "$(P -At -c "$SMOKE_ROWS")" = 0 ] \
  && echo "PASS smoke: FAIL with the trigger off, no rows left" || { echo "FAIL smoke did not notice: $SM"; exit 1; }
P -c "ALTER TABLE public.rate_limits ENABLE TRIGGER tb_retention" >/dev/null

if P < "$MIG" >/dev/null 2>&1; then echo "FAIL re-apply did not abort"; exit 1; else echo "PASS re-apply aborted"; fi
P < "$RB" >/dev/null
[ "$(P -At -c "$STATE")" = 0 ] && [ -z "$(P -At -c "select to_regprocedure('public.tb_retention_cleanup()')")" ] \
  && echo "PASS rollback removes triggers and functions" || { echo "FAIL rollback"; exit 1; }
echo "== ALL PASS"
