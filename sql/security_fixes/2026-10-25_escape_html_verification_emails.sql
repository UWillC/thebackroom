-- ============================================================
-- NOT APPLIED YET. Prepared 2026-10-25 (@cto), waiting for @ciso review + owner go.
-- ROADMAP #19 "szybka łata" (S2-L2, SECURITY-AUDIT-2026-10-23-s2-run1.md, lead 2).
--
-- WHAT WAS WRONG:
--   send_verification_email (trigger on profiles, SECURITY DEFINER) and
--   resend_verification_email (RPC, SECURITY DEFINER, EXECUTE granted to anon) paste
--   user-controlled values raw into the HTML body sent from hello@thebackroom.ai:
--     * name  -> <strong>' || NEW.name || '</strong>          (both functions)
--     * id    -> <a href="' || verification_link || '">        (link ends with '&profile=' || id;
--                profiles.id is text without default, so the inserting client chooses it)
--   => anyone with the public anon key can send HTML of their choice from our domain.
--
-- FIX (surgical replace, same pattern as email_token_hash_at_rest_2026-06-09.sql):
--   the two concatenations above get an inline HTML escape:
--     replace(replace(replace(replace(replace(x,'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;')
--   '&' first, so nothing is double-escaped. NULL stays NULL (same behaviour as before).
--   Escaping the href value is correct HTML: '&amp;profile=' decodes back to '&profile='.
--   Not touched: token (gen_random_uuid, server-generated), subject, to, rate limit, grants,
--   SECURITY DEFINER, search_path. CREATE OR REPLACE keeps owner and ACL.
--   This does NOT fix the rest of #19 (INSERT true policy, email_verified writable, anon
--   EXECUTE on resend, per-recipient limit) -> slot W44.
--
-- GUARDS: aborts unless the live body md5 equals the one read on 2026-10-25 (no drift since
--   review), each target occurs exactly once, and no raw target is left afterwards.
--   Whole file runs in one transaction (DO block): any RAISE = nothing changed.
--
-- APPLY:   supabase-write apply_migration name `escape_html_verification_emails_2026_10_25`
--          with this file's body, or paste into the SQL editor of project ifofgblilanwjhypzvdb.
-- ROLLBACK: 2026-10-25_escape_html_verification_emails_rollback.sql
-- VERIFIED LOCALLY (postgres:17 docker, live bodies byte-identical by md5, net.http_post stub):
--   see the commit message / report; post-apply md5 values are listed in the rollback file.
-- ============================================================

DO $mig$
DECLARE
  r record; fn_oid oid; cur_def text; new_def text;
  esc_l constant text := $e$replace(replace(replace(replace(replace($e$;
  esc_r constant text := $e$, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')$e$;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('send_verification_email',   '',                  '3f7a98e8994e6a2efd677ae305d7c6d4', 'NEW.name'),
      ('send_verification_email',   '',                  NULL,                               'verification_link'),
      ('resend_verification_email', 'p_profile_id text', '2bed4232cea779ae13fe21a6d86f8346', 'profile_record.name'),
      ('resend_verification_email', 'p_profile_id text', NULL,                               'verification_link')
    ) AS t(fname, args, md5_before, expr)
  LOOP
    SELECT p.oid INTO fn_oid FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace AND p.proname = r.fname
        AND pg_get_function_identity_arguments(p.oid) = r.args;
    IF fn_oid IS NULL THEN RAISE EXCEPTION 'function % not found', r.fname; END IF;
    cur_def := pg_get_functiondef(fn_oid);

    IF r.md5_before IS NOT NULL AND md5(cur_def) <> r.md5_before THEN
      RAISE EXCEPTION '% changed since review (md5 %), aborting', r.fname, md5(cur_def);
    END IF;

    -- target = the concatenation inside the HTML literal: ' || <expr> || '
    IF (length(cur_def) - length(replace(cur_def, $q$' || $q$ || r.expr || $q$ || '$q$, '')))
       / length($q$' || $q$ || r.expr || $q$ || '$q$) <> 1 THEN
      RAISE EXCEPTION 'target % must occur exactly once in %', r.expr, r.fname;
    END IF;

    new_def := replace(cur_def,
                       $q$' || $q$ || r.expr || $q$ || '$q$,
                       $q$' || $q$ || esc_l || r.expr || esc_r || $q$ || '$q$);
    EXECUTE new_def;

    IF position($q$' || $q$ || r.expr || $q$ || '$q$ IN pg_get_functiondef(fn_oid)) > 0 THEN
      RAISE EXCEPTION 'raw % still present in % after replace', r.expr, r.fname;
    END IF;
  END LOOP;
END $mig$;
