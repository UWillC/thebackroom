-- Read-only checks after 2026-10-30_privacy_retention.sql (pg_catalog + counts, no user data).
-- Run with the read-only MCP (execute_sql). Row '== ALL OK ==' must be true.
-- Row checks ("nothing older than ...", NULL dates) are valid only right after applying: later, on a table
-- with no new writes, they turn false without any fault, because cleanup runs when a row is written.
-- This file proves state, not that cleanup fires: for that run 2026-10-30_privacy_retention_smoke.sql.
WITH c AS (
  SELECT 'trigger on audit_logs' AS chk, EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tb_retention' AND tgrelid = 'public.audit_logs'::regclass) AS ok
  UNION ALL SELECT 'trigger on search_logs', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tb_retention' AND tgrelid = 'public.search_logs'::regclass)
  UNION ALL SELECT 'trigger on profile_stats', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tb_retention' AND tgrelid = 'public.profile_stats'::regclass)
  UNION ALL SELECT 'trigger on rate_limits', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'tb_retention' AND tgrelid = 'public.rate_limits'::regclass)
  UNION ALL SELECT 'cleanup is security definer', (SELECT prosecdef FROM pg_proc WHERE oid = 'public.tb_retention_cleanup()'::regprocedure)
  UNION ALL SELECT 'delete_account is security definer', (SELECT prosecdef FROM pg_proc WHERE oid = 'public.tb_delete_account(text)'::regprocedure)
  UNION ALL SELECT 'delete_account not executable by API roles',
    NOT has_function_privilege('anon', 'public.tb_delete_account(text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.tb_delete_account(text)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.tb_delete_account(text)', 'EXECUTE')
  UNION ALL SELECT 'cleanup not executable by API roles',
    NOT has_function_privilege('anon', 'public.tb_retention_cleanup()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.tb_retention_cleanup()', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.tb_retention_cleanup()', 'EXECUTE')
  UNION ALL SELECT 'triggers enabled, AFTER INSERT per statement, bound to cleanup',
    (SELECT count(*) = 4 FROM pg_trigger t WHERE t.tgname = 'tb_retention' AND t.tgenabled = 'O' AND t.tgtype = 4
       AND t.tgfoid = 'public.tb_retention_cleanup()'::regprocedure)
  UNION ALL SELECT 'search_path pinned, owner postgres',
    (SELECT bool_and(coalesce(proconfig @> ARRAY['search_path=public, pg_temp'], false) AND pg_get_userbyid(proowner) = 'postgres')
       FROM pg_proc WHERE oid IN ('public.tb_retention_cleanup()'::regprocedure, 'public.tb_delete_account(text)'::regprocedure))
  UNION ALL SELECT 'audit_logs nothing older than 90 days', NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE created_at < now() - interval '90 days')
  UNION ALL SELECT 'search_logs nothing older than 12 months', NOT EXISTS (SELECT 1 FROM public.search_logs WHERE created_at < now() - interval '12 months')
  UNION ALL SELECT 'profile_stats nothing older than 12 months', NOT EXISTS (SELECT 1 FROM public.profile_stats WHERE created_at < now() - interval '12 months')
  UNION ALL SELECT 'rate_limits nothing older than 7 days', NOT EXISTS (SELECT 1 FROM public.rate_limits WHERE created_at < now() - interval '7 days')
  UNION ALL SELECT 'no rows with NULL created_at (cleanup would never remove them)',
    NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE created_at IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.search_logs WHERE created_at IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.profile_stats WHERE created_at IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.rate_limits WHERE created_at IS NULL)
)
SELECT chk, ok FROM c
UNION ALL SELECT '== ALL OK ==', count(*) FILTER (WHERE ok IS NOT TRUE) = 0 FROM c;  -- bool_and would skip a NULL check
