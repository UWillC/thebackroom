-- Proof that cleanup fires on a write, after 2026-10-30_privacy_retention.sql.
-- Needs write access, so it does not run on the read-only MCP. It ALWAYS ends in an error, on purpose: the
-- error rolls back everything inside the block (probe rows and any cleanup they caused), whatever the client does.
-- Expected: error text starts with RETENTION_SMOKE_OK. RETENTION_SMOKE_FAIL = cleanup does not work, stop.
-- Any other error (e.g. read-only transaction) = the check did not run.
DO $smoke$
DECLARE
  v_old int;
  v_new int;
BEGIN
  INSERT INTO public.rate_limits (user_id, action_type, created_at) VALUES
    ('__retention_smoke__', 'old', now() - interval '8 days'),
    ('__retention_smoke__', 'new', now());
  SELECT count(*) FILTER (WHERE action_type = 'old'), count(*) FILTER (WHERE action_type = 'new')
    INTO v_old, v_new FROM public.rate_limits WHERE user_id = '__retention_smoke__';
  IF v_old = 0 AND v_new = 1 THEN
    RAISE EXCEPTION 'RETENTION_SMOKE_OK: old row deleted, new row kept, everything rolled back';
  END IF;
  RAISE EXCEPTION 'RETENTION_SMOKE_FAIL: old rows left %, new rows %, everything rolled back', v_old, v_new;
END
$smoke$;
