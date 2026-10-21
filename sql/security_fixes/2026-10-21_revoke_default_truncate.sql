-- 2026-10-21 · revoke_default_truncate_public_anon_authenticated (@ciso review PASS → @cto via supabase-write)
-- What was wrong: the 2026-09-22 fix revoked TRUNCATE from anon/authenticated on existing tables only.
-- Default privileges of role postgres in schema public still granted TRUNCATE (D) to anon/authenticated
-- on every NEW table (pg_default_acl: anon=Dxtm, authenticated=Dxtm).
-- Found while checking the Supabase Data API grants change of 2026-10-30 (changelog 45329).
-- Verified before: 0 existing public tables with TRUNCATE for anon/authenticated (aclexplode).
-- Verified after: pg_default_acl = {postgres=arwdDxtm,anon=xtm,authenticated=xtm,service_role=Dxtm}.
alter default privileges for role postgres in schema public revoke truncate on tables from anon, authenticated;
