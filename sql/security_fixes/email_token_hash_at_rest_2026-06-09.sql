-- ============================================================
-- APPLIED 2026-06-09 (@cto, apply_migration `email_token_hash_at_rest_2026_06_09`)
-- Closes P0: anon could harvest live email_verification_token via
--   GET /rest/v1/profiles?select=* (RLS USING(true) + table-level SELECT grant).
--
-- GATE A RESULT (empirical, live PostgREST, anon key):
--   * Column-level restriction DOES block the token for anon...
--   * ...but PostgREST `select=*` then returns 42501 permission denied (BREAKS).
--     The app uses select("*") on profiles in ~8 sites -> column-revoke is NOT viable.
--   * Also: REVOKE SELECT(col) is a NO-OP while the role holds table-level SELECT
--     (must REVOKE table-level then GRANT column-level). The 2026-05-13 fix would
--     have been ineffective for this reason even if applied.
--   => RLS/grant column-scoping rejected. Fix = neutralize the data sensitivity.
--
-- CHOSEN FIX (user decision 2026-06-09): hash-at-rest.
--   Store SHA-256(token) in profiles.email_verification_token; email the PLAINTEXT;
--   verify by hashing the submitted token. Anon reading the column gets a useless
--   hash. No app change, no schema change, no select=* break.
--
-- CHANGES (surgical replace, bodies preserved byte-for-byte except target):
--   send_verification_email (trigger):  NEW.email_verification_token := encode(extensions.digest(verification_token,'sha256'),'hex')
--   resend_verification_email (rpc):     SET email_verification_token = encode(extensions.digest(new_token,'sha256'),'hex')
--   verify_email_token (rpc):            compare against encode(extensions.digest(p_token,'sha256'),'hex')
--                                        + hardened INVOKER -> SECURITY DEFINER, pinned search_path
--
-- VERIFICATION (all passed):
--   - structural: store-side & verify-side use byte-identical hash expr; all 3 secdef.
--   - hash discrimination: correct==correct true, correct==wrong false.
--   - e2e via real function (rollback-DO, no persistence): wrong->Invalid, correct->success=true.
--   - founder profile untouched (email_verified=true, token NULL).
--
-- NOTE: 0 live tokens at apply time -> zero backward-compat impact. Any future
--   pending token from before this change would simply fail verify (re-send fixes).
-- ============================================================

DO $mig$
DECLARE r record; fn_oid oid; cur_def text; new_def text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('send_verification_email', '',
       'NEW.email_verification_token := verification_token;',
       'NEW.email_verification_token := encode(extensions.digest(verification_token, ''sha256''), ''hex'');'),
      ('resend_verification_email', 'p_profile_id text',
       'SET email_verification_token = new_token,',
       'SET email_verification_token = encode(extensions.digest(new_token, ''sha256''), ''hex''),'),
      ('verify_email_token', 'p_profile_id text, p_token text',
       'profile_record.email_verification_token != p_token',
       'profile_record.email_verification_token != encode(extensions.digest(p_token, ''sha256''), ''hex'')')
    ) AS t(fname, args, src, rep)
  LOOP
    SELECT p.oid INTO fn_oid FROM pg_proc p
      WHERE p.pronamespace='public'::regnamespace AND p.proname=r.fname
        AND pg_get_function_identity_arguments(p.oid)=r.args;
    IF fn_oid IS NULL THEN RAISE EXCEPTION 'function % not found', r.fname; END IF;
    cur_def := pg_get_functiondef(fn_oid);
    new_def := replace(cur_def, r.src, r.rep);
    IF new_def = cur_def THEN RAISE EXCEPTION 'replace target NOT found in % — aborting', r.fname; END IF;
    EXECUTE new_def;
  END LOOP;
  ALTER FUNCTION public.verify_email_token(text, text) SECURITY DEFINER SET search_path = 'public','pg_temp';
END $mig$;
