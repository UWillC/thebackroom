-- ============================================================
-- ROLLBACK of 2026-11-05_mail_links_to_pages.sql: mail links go back to the Hugging Face Space.
-- Use only while the Space still exists. Verification links go back to ?verify= in the query string.
-- Guard: each body must be exactly the one the migration produced (md5), else nothing changes.
-- After: md5 of every body = the production read of 2026-11-05 (asserted before COMMIT).
-- ============================================================

BEGIN;

DO $rollback$
DECLARE
  r record;
  def text;
  cur text;
  new_verify CONSTANT text := 'https://huggingface.co/spaces/UWillC/thebackroom?verify=';
  old_verify CONSTANT text := 'https://www.thebackroom.ai/app/#verify=';
  new_href   CONSTANT text := 'href="https://huggingface.co/spaces/UWillC/thebackroom"';
  old_href   CONSTANT text := 'href="https://www.thebackroom.ai/app/"';
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('send_verification_email()',               '2c1bf8f8e967d9011c58c1be2be46aa1', 1, 0, '4ec5ca19f0e39f5d80af4827503d7878'),
    ('resend_verification_email(text)',         '87912d665262670628a5cee78884bb10', 1, 0, 'ef0e16b47f239198e9db8988fe10cc0c'),
    ('notify_connection_accepted()',            '4325336202ced3c3bb4278735efe8c7e', 0, 1, '25f44f42b3d607e865200104045354c0'),
    ('notify_connection_request()',             '91d94cc35ab9b92c2bdbe2cc3e88743e', 0, 1, 'afe33640be139e29d07808cf2217d125'),
    ('notify_new_profile()',                    'f3d6ec8daee76088a5339647a15d69f4', 0, 1, 'f28cc562832f991ae089a142e39139a4'),
    ('notify_room_invite()',                    '13f80c0304dcefb54d8d4432bf765a24', 0, 1, '4b27280d7eaf436450a888246ab41797'),
    ('notify_room_member_approved()',           'de14ce75e626101cb8e967729a1f9bd1', 0, 1, '33294880c050cb484830eaeca7400041'),
    ('send_weekly_matches_email(text)',         '71d35a3bf79ee3a4e3527f9203e0be07', 0, 1, '0917b95d5ea952ac3eebb0a49e02a0cf'),
    ('send_welcome_email_after_verification()', '855954fbe5dc9b6e45abe4e8441c81eb', 0, 1, 'db7ab1f85b7d346118c51d4968352d7b')
  ) AS t(sig, md5_before, n_verify, n_href, md5_after) LOOP
    def := pg_get_functiondef(to_regprocedure('public.' || r.sig));
    IF md5(def) IS DISTINCT FROM r.md5_before THEN
      RAISE EXCEPTION '% is not the body written by mail_links_to_pages (md5 %), aborting', r.sig, md5(def);
    END IF;
    IF (length(def) - length(replace(def, old_verify, ''))) / length(old_verify) <> r.n_verify
       OR (length(def) - length(replace(def, old_href, ''))) / length(old_href) <> r.n_href THEN
      RAISE EXCEPTION '% does not have the expected link count, aborting', r.sig;
    END IF;
    EXECUTE replace(replace(def, old_verify, new_verify), old_href, new_href);
    cur := md5(pg_get_functiondef(to_regprocedure('public.' || r.sig)));
    IF cur IS DISTINCT FROM r.md5_after THEN
      RAISE EXCEPTION '% after rollback has md5 %, expected %, aborting', r.sig, cur, r.md5_after;
    END IF;
  END LOOP;
END $rollback$;

COMMIT;
