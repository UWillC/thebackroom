-- ============================================================
-- NOT APPLIED. Needs @ciso review + user "pchaj". Apply only AFTER /app is live on Cloudflare Pages
-- (otherwise the new links point at a 404).
-- Web interface moves from the Hugging Face Space to https://www.thebackroom.ai/app/ (user decision
-- 2026-11-05, variant a of DRAFTS/2026-11-05_cto-hf-przeprowadzka_rozpoznanie.md).
-- What changes, in 9 mail functions, and nothing else:
--   1. '...huggingface.co/spaces/UWillC/thebackroom?verify='  ->  'https://www.thebackroom.ai/app/#verify='
--      (send_verification_email, resend_verification_email). The token moves from the query string to
--      the fragment: browsers never send the fragment to the server, so it stays out of every host log.
--   2. href="https://huggingface.co/spaces/UWillC/thebackroom"  ->  href="https://www.thebackroom.ai/app/"
--      (footer link in the other 7 functions).
-- How: each body is read with pg_get_functiondef, the two literals are replaced, the result runs as
-- CREATE OR REPLACE. Owner, ACL, SECURITY DEFINER, search_path and triggers stay (CREATE OR REPLACE
-- keeps them). Because the input bodies are pinned by md5, the output is deterministic; the expected
-- md5 after the change is asserted before COMMIT.
-- Guard: md5 of all 9 bodies read from production 2026-11-05 (read-only MCP), after
-- connection_mail_no_text_2026_11_05 and drop_room_message_trigger_2026_11_05.
-- APPLY: supabase-write apply_migration, name mail_links_to_pages_2026_11_05, this file unchanged.
-- VERIFY: 2026-11-05_mail_links_to_pages_verify_after_apply.sql (read-only), all rows true.
-- ROLLBACK: 2026-11-05_mail_links_to_pages_rollback.sql (links back to the Space).
-- TESTED LOCALLY: sql/tests/run_mail_links_local.sh (postgres:17, stubs for pg_net/auth).
-- ============================================================

BEGIN;

DO $migration$
DECLARE
  r record;
  def text;
  new_def text;
  cur text;
  old_verify CONSTANT text := 'https://huggingface.co/spaces/UWillC/thebackroom?verify=';
  new_verify CONSTANT text := 'https://www.thebackroom.ai/app/#verify=';
  old_href   CONSTANT text := 'href="https://huggingface.co/spaces/UWillC/thebackroom"';
  new_href   CONSTANT text := 'href="https://www.thebackroom.ai/app/"';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('send_verification_email()',               '4ec5ca19f0e39f5d80af4827503d7878', 1, 0, '2c1bf8f8e967d9011c58c1be2be46aa1'),
    ('resend_verification_email(text)',         'ef0e16b47f239198e9db8988fe10cc0c', 1, 0, '87912d665262670628a5cee78884bb10'),
    ('notify_connection_accepted()',            '25f44f42b3d607e865200104045354c0', 0, 1, '4325336202ced3c3bb4278735efe8c7e'),
    ('notify_connection_request()',             'afe33640be139e29d07808cf2217d125', 0, 1, '91d94cc35ab9b92c2bdbe2cc3e88743e'),
    ('notify_new_profile()',                    'f28cc562832f991ae089a142e39139a4', 0, 1, 'f3d6ec8daee76088a5339647a15d69f4'),
    ('notify_room_invite()',                    '4b27280d7eaf436450a888246ab41797', 0, 1, '13f80c0304dcefb54d8d4432bf765a24'),
    ('notify_room_member_approved()',           '33294880c050cb484830eaeca7400041', 0, 1, 'de14ce75e626101cb8e967729a1f9bd1'),
    ('send_weekly_matches_email(text)',         '0917b95d5ea952ac3eebb0a49e02a0cf', 0, 1, '71d35a3bf79ee3a4e3527f9203e0be07'),
    ('send_welcome_email_after_verification()', 'db7ab1f85b7d346118c51d4968352d7b', 0, 1, '855954fbe5dc9b6e45abe4e8441c81eb')
  ) AS t(sig, md5_before, n_verify, n_href, md5_after) LOOP
    def := pg_get_functiondef(to_regprocedure('public.' || r.sig));
    IF md5(def) IS DISTINCT FROM r.md5_before THEN
      RAISE EXCEPTION '% is not the 2026-11-05 production body (md5 %), aborting', r.sig, md5(def);
    END IF;
    IF (length(def) - length(replace(def, old_verify, ''))) / length(old_verify) <> r.n_verify
       OR (length(def) - length(replace(def, old_href, ''))) / length(old_href) <> r.n_href THEN
      RAISE EXCEPTION '% does not have the expected link count, aborting', r.sig;
    END IF;
    new_def := replace(replace(def, old_verify, new_verify), old_href, new_href);
    IF new_def ILIKE '%huggingface%' THEN
      RAISE EXCEPTION '% still mentions huggingface after the replace, aborting', r.sig;
    END IF;
    EXECUTE new_def;
    cur := md5(pg_get_functiondef(to_regprocedure('public.' || r.sig)));
    IF cur IS DISTINCT FROM r.md5_after THEN
      RAISE EXCEPTION '% after the change has md5 %, expected %, aborting', r.sig, cur, r.md5_after;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND prosrc ILIKE '%huggingface%') THEN
    RAISE EXCEPTION 'a public function still mentions huggingface, aborting';
  END IF;
END $migration$;

COMMIT;
