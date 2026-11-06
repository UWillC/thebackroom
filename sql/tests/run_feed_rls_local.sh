#!/usr/bin/env bash
# LOCAL ONLY: postgres:17 in docker, never points at Supabase. Rebuilds the production RLS of assistant_posts /
# assistant_profiles / assistant_feed (12 policies, md5 = production read 2026-11-05) on the W44 stand-in, proves
# the 42501 bug, then runs 2026-11-05_feed_rls_legacy_policies.sql: guard, atomicity, apply, authorization matrix
# identical to the legacy policy set, hidden profile columns still refused, verify file incl. sabotage, rollback.
# Usage: sql/tests/run_feed_rls_local.sh   KEEP=1 keeps the container.
set -euo pipefail
cd "$(dirname "$0")/.."
C=feedrls_pg_test
MIG=security_fixes/2026-11-05_feed_rls_legacy_policies.sql
RB=security_fixes/2026-11-05_feed_rls_legacy_policies_rollback.sql
VER=security_fixes/2026-11-05_feed_rls_legacy_policies_verify_after_apply.sql
docker rm -fv "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" -e POSTGRES_PASSWORD=local postgres:17 >/dev/null
[ "${KEEP:-0}" = 1 ] || trap 'docker rm -fv "$C" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
P() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
PASSN=0; pass() { PASSN=$((PASSN+1)); echo "PASS $1"; }
fail() { echo "FAIL $1"; exit 1; }
POLQ="select string_agg(tablename||'.'||policyname||'='||md5(coalesce(qual,'∅')||'|'||coalesce(with_check,'∅')), ' ' order by tablename, convert_to(policyname, 'UTF8')) from pg_policies where schemaname='public' and tablename in ('assistant_posts','assistant_profiles')"
LIVE_POL="assistant_posts.Published posts are viewable by everyone=9fab48479668a99290fea091b87c89c0 assistant_posts.Users can manage own posts=a896d0258b5956b574c0415bc6578b5b assistant_posts.assistant_posts_delete=8bdd3076f8d2c9b15bc407f145a1b1d4 assistant_posts.assistant_posts_insert=86977bce7aa8908a8aabd08cb48541dd assistant_posts.assistant_posts_select_published=0b237a8df8cb60484cd3969e2536d25a assistant_posts.assistant_posts_update=8bdd3076f8d2c9b15bc407f145a1b1d4 assistant_profiles.Assistant profiles are viewable by everyone=b93851f87859716f0709b05a44651227 assistant_profiles.Users can manage own assistant profiles=785ffd96edb5701d524bca75747a62da assistant_profiles.assistant_profiles_delete=43c0f4ec0f1e0d5983eaf44fcb977081 assistant_profiles.assistant_profiles_insert=ee8bbea7b0b030121a7ff2a8b4d37127 assistant_profiles.assistant_profiles_select=b93851f87859716f0709b05a44651227 assistant_profiles.assistant_profiles_update=43c0f4ec0f1e0d5983eaf44fcb977081"
pol() { P -At -c "$POLQ"; }
green() { P -At < "$VER" | grep -q "^== ALL OK ==|t|"; }
# what the public key sees: feed, assistants, and the columns hidden since W44
ANON="select t_cnt('anon',NULL,'SELECT id FROM assistant_feed')||' '||t_cnt('anon',NULL,'SELECT id FROM assistant_profiles')||' '||
  t_cnt('anon',NULL,'SELECT auth_user_id FROM profiles')||' '||t_cnt('anon',NULL,'SELECT email FROM profiles')||' '||
  t_cnt('anon',NULL,'SELECT email_verification_token FROM profiles')||' '||t_cnt('anon',NULL,'SELECT * FROM profiles')||' '||
  t_cnt('authenticated','00000000-0000-0000-0000-00000000000a','SELECT auth_user_id FROM profiles')"
COLQ="select string_agg(grantee||':'||column_name, ',' order by grantee, column_name) from information_schema.column_privileges where table_schema='public' and table_name='profiles' and grantee in ('anon','authenticated') and privilege_type='SELECT'"
GRQ="select string_agg(grantee||':'||table_name||':'||privilege_type, ',' order by 1) from information_schema.role_table_grants where table_schema='public' and table_name in ('assistant_posts','assistant_profiles','assistant_feed','profiles') and grantee in ('anon','authenticated')"

P < tests/w44_base_schema.sql >/dev/null
P < security_fixes/2026-10-26_w44_live_snapshot.sql >/dev/null
P < tests/w44_live_acl_triggers.sql >/dev/null
P < tests/w44_seed_and_before.sql >/dev/null 2>&1
P < security_fixes/2026-10-26_w44_19_20_hardening.sql >/dev/null 2>&1
P < tests/feed_rls_live.sql >/dev/null
[ "$(pol)" = "$LIVE_POL" ] && pass "start: 12 policies, md5 of every expression = production read 2026-11-05" || { pol; fail "start policies"; }
COLS0=$(P -At -c "$COLQ"); GR0=$(P -At -c "$GRQ")

[ "$(P -At -c "$ANON")" = "42501 rows 2 42501 42501 42501 42501 42501" ] \
  && pass "before: public key gets 42501 on assistant_feed (the x.Feed 401), assistants readable, hidden columns 42501" \
  || fail "before: $(P -At -c "$ANON")"
[ "$(P -At -c "select t_cnt('authenticated','00000000-0000-0000-0000-00000000000a','SELECT id FROM assistant_posts')")" = 42501 ] \
  && pass "before: signed-in owner gets 42501 on assistant_posts too" || fail "before owner"

# Baseline semantics of the legacy set: make the legacy policies evaluable for the moment, record the matrix.
MATRIX_OLD=$(P -At -c "BEGIN; GRANT SELECT (auth_user_id) ON public.profiles TO anon, authenticated; SELECT case_name||'|'||outcome FROM t_feed_matrix(); ROLLBACK;")
[ "$(P -At -c "$COLQ")" = "$COLS0" ] || fail "baseline grant leaked"
echo "$MATRIX_OLD" | grep -q "owner reads posts|rows 2" && echo "$MATRIX_OLD" | grep -q "anon reads posts|rows 1" \
  && pass "baseline matrix recorded with the legacy policies evaluable (24 cases)" || { echo "$MATRIX_OLD"; fail "baseline"; }

FAILING=$(sed 's/^COMMIT;$/SELECT 1\/0;\nCOMMIT;/' "$MIG")
echo "$FAILING" | P >/dev/null 2>&1 && fail "forced error not raised" || true
[ "$(pol)" = "$LIVE_POL" ] && pass "atomic: forced error before COMMIT, all 12 policies still there" || fail "partial apply"

P -c "ALTER POLICY assistant_posts_update ON public.assistant_posts USING (true)" >/dev/null
if G=$(P < "$MIG" 2>&1); then fail "guard let a changed policy through"; fi
echo "$G" | grep -q "assistant_posts_update on assistant_posts is not the 2026-11-05 production one" || fail "guard message: $G"
P -c "ALTER POLICY assistant_posts_update ON public.assistant_posts USING (EXISTS ( SELECT 1 FROM assistant_profiles ap WHERE ((ap.id = assistant_posts.assistant_id) AND owns_profile(ap.human_profile_id))))" >/dev/null
[ "$(pol)" = "$LIVE_POL" ] && pass "guard: a changed replacement policy stops the migration (nothing dropped)" || { pol; fail "guard restore"; }
P -c "CREATE POLICY extra ON public.assistant_profiles FOR SELECT USING (true)" >/dev/null
if P < "$MIG" >/dev/null 2>&1; then fail "extra policy accepted"; fi
P -c "DROP POLICY extra ON public.assistant_profiles" >/dev/null
pass "guard: an unexpected 13th policy stops the migration"

P < "$MIG" >/dev/null
[ "$(P -At -c "$ANON")" = "rows 1 rows 2 42501 42501 42501 42501 42501" ] \
  && pass "after: public key reads assistant_feed (1 published post) and assistant_profiles; auth_user_id, email, token, SELECT * still 42501" \
  || fail "after: $(P -At -c "$ANON")"
[ "$(P -At -c "select t_cnt('anon',NULL,'SELECT content FROM assistant_feed WHERE content LIKE ''draft%''')")" = "rows 0" ] \
  && pass "after: drafts not visible through the feed" || fail "drafts visible"
MATRIX_NEW=$(P -At -c "SELECT case_name||'|'||outcome FROM t_feed_matrix()")
[ "$MATRIX_NEW" = "$MATRIX_OLD" ] && pass "authorization matrix identical to the legacy set (24 cases: read/add/edit/move/delete, owner/other/anon)" \
  || { diff <(echo "$MATRIX_OLD") <(echo "$MATRIX_NEW"); fail "matrix differs"; }
[ "$(P -At -c "$COLQ")" = "$COLS0" ] && [ "$(P -At -c "$GRQ")" = "$GR0" ] && pass "column and table grants identical to before (nothing widened)" || fail "grants changed"
green && pass "verify file: all checks ok" || { P -At < "$VER"; fail "verify file"; }

sabotage() {  # name, break, restore
  P -c "$2" >/dev/null
  if green; then fail "verify stayed green: $1"; else pass "verify false: $1"; fi
  P -c "$3" >/dev/null
}
sabotage "anon gets auth_user_id" "GRANT SELECT (auth_user_id) ON public.profiles TO anon" "REVOKE SELECT (auth_user_id) ON public.profiles FROM anon"
sabotage "authenticated gets email" "GRANT SELECT (email) ON public.profiles TO authenticated" "REVOKE SELECT (email) ON public.profiles FROM authenticated"
sabotage "replacement policy weakened" "ALTER POLICY assistant_profiles_update ON public.assistant_profiles USING (true)" "ALTER POLICY assistant_profiles_update ON public.assistant_profiles USING (owns_profile(human_profile_id))"
sabotage "extra policy" "CREATE POLICY extra ON public.assistant_posts FOR SELECT USING (true)" "DROP POLICY extra ON public.assistant_posts"
sabotage "RLS off" "ALTER TABLE public.assistant_posts DISABLE ROW LEVEL SECURITY" "ALTER TABLE public.assistant_posts ENABLE ROW LEVEL SECURITY"
sabotage "view not security_invoker" "ALTER VIEW public.assistant_feed SET (security_invoker = false)" "ALTER VIEW public.assistant_feed SET (security_invoker = true)"
green && pass "verify green again after every restore" || fail "restore"

if P < "$MIG" >/dev/null 2>&1; then fail "re-apply did not abort"; else pass "re-apply aborted (guard)"; fi

P < "$RB" >/dev/null
[ "$(pol)" = "$LIVE_POL" ] && pass "rollback: all 12 policies back, md5 = production" || { pol; fail "rollback"; }
[ "$(P -At -c "$ANON")" = "42501 rows 2 42501 42501 42501 42501 42501" ] && pass "rollback: back to the 42501 state" || fail "rollback state"
if P < "$RB" >/dev/null 2>&1; then fail "second rollback ran"; else pass "rollback refuses when the policies are already there"; fi

P -c "BEGIN; $(cat "$MIG") COMMIT;" >/dev/null 2>&1
green && pass "apply inside an outer transaction: verify all ok" || fail "apply in outer transaction"

echo "== $PASSN PASS, 0 FAIL"
