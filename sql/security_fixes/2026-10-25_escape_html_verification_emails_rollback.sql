-- ============================================================
-- ROLLBACK for 2026-10-25_escape_html_verification_emails.sql (@cto, 2026-10-25).
-- Restores the raw concatenation (re-opens the HTML injection!). Use only if the escape
-- breaks verification mails and the fix-forward is not possible.
--
-- Guards: md5 after the forward migration must match (values measured on postgres:17 with
-- the live bodies from 2026-10-25), and after rollback the md5 must equal the original:
--   send_verification_email    after fix 02869da99eb42c68ff5a90ec9944ab7e -> original 3f7a98e8994e6a2efd677ae305d7c6d4
--   resend_verification_email  after fix 9b56025c125f7bfe3d4c8d43a8e433ba -> original 2bed4232cea779ae13fe21a6d86f8346
-- ============================================================

DO $rb$
DECLARE
  r record; fn_oid oid; cur_def text; new_def text; e text;
  esc_l constant text := $e$replace(replace(replace(replace(replace($e$;
  esc_r constant text := $e$, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')$e$;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('send_verification_email',   '',                  '02869da99eb42c68ff5a90ec9944ab7e', '3f7a98e8994e6a2efd677ae305d7c6d4', ARRAY['NEW.name','verification_link']),
      ('resend_verification_email', 'p_profile_id text', '9b56025c125f7bfe3d4c8d43a8e433ba', '2bed4232cea779ae13fe21a6d86f8346', ARRAY['profile_record.name','verification_link'])
    ) AS t(fname, args, md5_fixed, md5_original, exprs)
  LOOP
    SELECT p.oid INTO fn_oid FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = r.fname
        AND pg_get_function_identity_arguments(p.oid) = r.args;
    IF fn_oid IS NULL THEN RAISE EXCEPTION 'function % not found', r.fname; END IF;
    cur_def := pg_get_functiondef(fn_oid);
    IF md5(cur_def) <> r.md5_fixed THEN
      RAISE EXCEPTION '% is not in the post-fix state (md5 %), aborting', r.fname, md5(cur_def);
    END IF;
    new_def := cur_def;
    FOREACH e IN ARRAY r.exprs LOOP
      new_def := replace(new_def, esc_l || e || esc_r, e);
    END LOOP;
    IF md5(new_def) <> r.md5_original THEN
      RAISE EXCEPTION 'rollback of % would not restore the original body, aborting', r.fname;
    END IF;
    EXECUTE new_def;
  END LOOP;
END $rb$;
