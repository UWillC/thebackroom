-- Rollback for 2026-10-30_privacy_retention.sql (NOT APPLIED, same as the migration).
-- Removes the 4 retention triggers and both functions. Rows already deleted by the migration or
-- by the triggers are NOT restored (only a database backup has them).
BEGIN;
DROP TRIGGER IF EXISTS tb_retention ON public.audit_logs;
DROP TRIGGER IF EXISTS tb_retention ON public.search_logs;
DROP TRIGGER IF EXISTS tb_retention ON public.profile_stats;
DROP TRIGGER IF EXISTS tb_retention ON public.rate_limits;
DROP FUNCTION IF EXISTS public.tb_retention_cleanup();
DROP FUNCTION IF EXISTS public.tb_delete_account(text);
COMMIT;
