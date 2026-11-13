# SQL (Supabase)

Schema, RLS, triggers and security fixes for The Backroom, as applied in the Supabase SQL editor
or via MCP migrations. Moved here from a folder outside version control on 2026-09-25, so every
future migration lands in the same repo as the code that depends on it.

Rules:
- **New table = explicit `GRANT ... TO service_role`.** Default privileges for new tables are off
  in this project (hardening 2026-05-13). Pattern: `mcp_client_sessions.sql`.
- **Supabase Data API grants (enforced on all projects from 2026-10-30, changelog 45329):** new
  tables in `public` are not reachable over the Data API without an explicit grant. Nothing
  changes for us (checked 2026-10-21 in `pg_default_acl`: tables created by `postgres` already get
  no select/insert/update/delete for `anon`/`authenticated`/`service_role`), but every migration
  that creates a table must ship grant + RLS + policies as one unit. Pick the variant by who reads
  the table:

  ```sql
  -- A) service_role only (default for The Backroom, MCP server uses service_role)
  alter table public.your_table enable row level security;
  revoke all on public.your_table from anon, authenticated, public;
  grant select, insert, update, delete on public.your_table to service_role;

  -- B) read by signed-in users through the Data API (RLS decides which rows)
  alter table public.your_table enable row level security;
  revoke all on public.your_table from anon, public;
  grant select on public.your_table to authenticated;   -- add insert/update/delete only if a policy needs it
  grant select, insert, update, delete on public.your_table to service_role;
  create policy "own rows" on public.your_table for select to authenticated
    using (auth.uid() = user_id);

  -- C) Edge Function over direct Postgres (wc2026 / nfl / marvel pattern): no Data API exposure
  alter table public.your_table enable row level security;   -- RLS on, zero policies = deny-all
  revoke all on public.your_table from anon, authenticated, public;
  ```

  Missing grant = PostgREST error `42501` with the exact `GRANT` in the hint. Never grant `anon`
  write access; `truncate` is revoked from `anon`/`authenticated` on existing tables (2026-09-22) and
  in default privileges for new ones (2026-10-21, `security_fixes/2026-10-21_revoke_default_truncate.sql`);
  keep `revoke all` in the migration anyway.
- `security_fixes/` = dated fixes; the file header says what was wrong and how it was verified.
- Not kept here on purpose: one-off data scripts (test inserts, email fixes for a single profile,
  "clear all data") and state dumps. They contained personal data or are destructive by design.

## W44 (2026-10-26): ROADMAP #19 rest + #20, APPLIED 2026-10-26 (`w44_19_20_hardening_2026_10_26`, version 20261026234249; @ciso: GO z warunkami, W1-W8 done)

**Do not run `2026-10-26_w44_19_20_hardening_rollback.sql` without a new migration.** It overwrites all 10 mail
functions with their pre-W44 bodies (message text, no escaping), including the room and connection mails
changed on 2026-11-05. Its guard refuses when those functions are no longer the W44 bodies.

Files (`security_fixes/`): `2026-10-26_w44_19_20_hardening.sql` (migration),
`..._rollback.sql`, `2026-10-26_w44_live_snapshot.sql` (live bodies read 2026-10-26, md5-verified),
`2026-10-26_w44_verify_after_apply.sql` (read-only checks over pg_catalog).
Local proof: `tests/run_w44_local.sh` (postgres:17 in docker): 112 SQL assertions incl. the
@ciso attacks, 4 atomicity modes, verify file all ok, re-apply abort, rollback to live md5 + ACL,
second apply inside an outer transaction.

**Apply path (chosen, @ciso W2):** `supabase-write apply_migration`, name
`w44_19_20_hardening_2026_10_26`, body = the migration file as is. The file carries its own
`BEGIN; ... COMMIT;`, so atomicity does not depend on how the tool sends it: the Management API
docs (`POST /v1/projects/{ref}/database/migrations`) do not say whether the call runs in one
transaction, so we do not rely on it. Tested locally: with an error forced just before COMMIT
nothing stays changed when the file is sent statement by statement (stop or continue on error),
as one simple query, or inside an outer transaction (there `BEGIN` only warns). The SQL editor
of project ifofgblilanwjhypzvdb is the fallback, same file unchanged. Apply only after
@ciso review + user "pchaj":

1. Pre-check: the guard aborts by itself on drift (md5 of 10 functions, W44 objects present).
2. Apply as above. Error = nothing changed; stop and report, do not retry blindly.
3. Run `security_fixes/2026-10-26_w44_verify_after_apply.sql` with the read-only MCP
   (`execute_sql`). Row `== ALL OK ==` must be `true`; any `false` = stop (do not deploy code),
   rollback file if needed.
4. Right after: merge branch `fix/w44-19-20` to `main` and push (CI -> Render MCP) and push the
   HF Space. Until then the old code fails on `select *` / anon INSERT (minutes, 1 user).
5. Smoke test: Backroom MCP `auth_check`, `get_profile("przemek_(snow)")`, then one real
   registration through MCP with a `+alias` address (mail arrives, profile deleted afterwards).

## Privacy retention + account deletion (2026-10-30), APPLIED 2026-11-02 (`privacy_retention_2026_10_30`; 21 rows deleted, verify `== ALL OK ==`, smoke `RETENTION_SMOKE_OK`). Do not use `tb_delete_account` before W5 and W7 (ROADMAP #26)

Files (`security_fixes/`): `2026-10-30_privacy_retention.sql` (migration), `..._rollback.sql`,
`..._verify_after_apply.sql` (read-only, `== ALL OK ==` must be true), `..._smoke.sql` (needs write
access, always ends in an error that rolls it back).
Local proof: `tests/run_privacy_local.sh` (postgres:17 in docker): atomicity with a forced error,
retention per table, cleanup when `anon` inserts, `tb_delete_account` on linked accounts and on profiles
named like a JSON key or value, verify file green and false on each sabotage, smoke file, re-apply abort,
rollback. Static checks: `tests/test_privacy_retention_2026_10_30.py`.

What it does: retention without pg_cron (statement-level AFTER INSERT trigger deletes rows past the
period, same idea as `email_send_log`): `audit_logs` 90 days, `search_logs` and `profile_stats`
12 months, `rate_limits` 7 days; plus a one-time cleanup and `tb_delete_account(profile_id)`.

Apply steps, in this order:

1. Fresh backup, from the CEO repo with Docker Desktop running: `scripts/backup-ai-first.sh --db-only`.
   Done = exit 0 and `DB-OK` with `rozjazd=0` in the last line of `~/Backups/backup-ai-first.log`.
   Rollback does not restore deleted rows, this backup is the only way back. Only a `.dump` file passed
   the restore test. A `backroom_*.dump.part` left by an alarm or an interrupted run is unverified: it does
   not count as a backup, rotation removes it after 56 days, and it may be used only by hand.
2. Row counts with the read-only MCP (counts only), written into the deployment report. More rows to
   delete than `audit_logs` 20, `search_logs` 1, `profile_stats` 17, `rate_limits` 8 = stop, ask @ciso:
   ```sql
   SELECT 'audit_logs' t, count(*) FILTER (WHERE created_at < now() - interval '90 days') old_rows, count(*) all_rows FROM public.audit_logs
   UNION ALL SELECT 'search_logs', count(*) FILTER (WHERE created_at < now() - interval '12 months'), count(*) FROM public.search_logs
   UNION ALL SELECT 'profile_stats', count(*) FILTER (WHERE created_at < now() - interval '12 months'), count(*) FROM public.profile_stats
   UNION ALL SELECT 'rate_limits', count(*) FILTER (WHERE created_at < now() - interval '7 days'), count(*) FROM public.rate_limits;
   ```
3. User says "pchaj". Same path as W44: `supabase-write apply_migration`, name
   `privacy_retention_2026_10_30`, file as is (it carries its own BEGIN/COMMIT).
4. Verify file with the read-only MCP: `== ALL OK ==` must be true. Its row checks are valid only right
   after applying, see the file header.
5. `2026-10-30_privacy_retention_smoke.sql` through `supabase-write execute_sql`: the call returns an
   error, and its text must start with `RETENTION_SMOKE_OK`. `RETENTION_SMOKE_FAIL` = cleanup does not
   fire, run the rollback file and report. Nothing stays in the table in either case.

### Account deletion runbook (request from the e-mail address on the account)

1. Check the request came from the account's e-mail address. Note the profile id.
2. SQL editor (role postgres; the function is not executable by any API role):
   `select public.tb_delete_account('<profile_id>');` -> returns counts and `auth_user_id`.
   One transaction: any error = nothing deleted.
3. Supabase dashboard -> Authentication -> Users -> delete the user with that `auth_user_id`.
4. Add `<date> <profile_id> <auth_user_id>` to `~/Backups/backroom-db/usuniete-konta.txt` (outside git
   and OneDrive; create it the first time with `install -m 600 /dev/null ~/Backups/backroom-db/usuniete-konta.txt`).
   Used before any restore: re-run steps 2-3 for every id on the list deleted after the backup date; a
   missing file means stop. No e-mail address on the list. At the weekly retro, remove entries older
   than 56 days by hand: by then no backup from before the deletion exists, so the entry has no use.
5. Reply to the requester within 30 days (GDPR) / 45 days (CCPA).

## Room mail without message content (2026-11-05), APPLIED 2026-11-05 (`room_mail_no_content_2026_11_05`, version 20261105124355; verify `== ALL OK ==`, md5 `43370bf6...`)

Files (`security_fixes/`): `2026-11-05_room_mail_no_content.sql`, `..._rollback.sql`,
`..._verify_after_apply.sql`, `2026-11-05_room_mail_send_paths_verify.sql` (all checks read-only).
Test: `tests/run_room_mail_local.sh` (docker, never Supabase), with the real `send_room_message` and
`respond_to_message` (copy in `tests/live_room_send_functions.sql`).

This mail never went out: `send_room_message` adds recipients after the message, so the trigger found none.
`2026-11-05_drop_room_message_trigger.sql` (+ `_rollback.sql`), APPLIED 2026-11-05 as `drop_room_message_trigger_2026_11_05`
(version 20261106010821 UTC, @ciso GO, guard 0 of 4 failed), removed trigger `on_room_message_sent`;
the function stays, unattached. The policy says room messages are not sent by e-mail, true by construction
while `2026-11-05_room_mail_send_paths_verify.sql` is all true (no trigger on the message tables, function
attached nowhere, no other mailing function reading room messages). Any false = policy and code change together.
After these migrations row `md5: notify_room_message` of the W44 verify file and row "trigger present" of
`2026-11-05_room_mail_no_content_verify_after_apply.sql` are false by design.

Rollback (@ciso W3):
1. While the mail does not go out, the policy stays as it is: the rollback does not change whether it is true,
   and a sentence about content in the mail would be untrue. Once the send order is fixed: policy first,
   @ciso approval, SQL last.
2. The rollback is harmless only while the mail does not go out. Once the send order is fixed it puts
   message subject and text back through Resend.
3. Never run `2026-10-26_w44_19_20_hardening_rollback.sql` without a new migration: it would overwrite all 10
   mail functions with pre-W44 bodies. Its guard refuses over bodies changed after W44.

## Connection mails without user text (2026-11-05), APPLIED 2026-11-05 (`connection_mail_no_text_2026_11_05`, version 20261106005715 UTC; verify `== ALL OK ==` 0 of 12 failed)

Files (`security_fixes/`): `2026-11-05_connection_mail_no_text.sql`, `..._rollback.sql`,
`..._verify_after_apply.sql`. Test: `tests/run_connection_mail_local.sh`. `NEW.message` and
`NEW.response_message` leave the mails; LinkedIn and preferred contact stay (user decision).
Apply through `supabase-write apply_migration`, name `connection_mail_no_text_2026_11_05`, then the verify file.
These mails are live, so the rollback really puts text back through Resend: @ciso + user first.
Same ban as above: never `2026-10-26_w44_19_20_hardening_rollback.sql` without a new migration (all 10 mail functions).
After it rows `md5: notify_connection_request` and `md5: notify_connection_accepted` of the W44 verify file
are false by design. No policy change depends on it: the policy does not describe the text in these mails.

## Read-only backup role `backup_ro` (2026-11-12), APPLIED 2026-11-12 (fallback variant B, first dump DB-OK)

Replaces the `postgres` URI used by the weekly `pg_dump` (CEO repo `scripts/backup-ai-first.sh`, step 7) with a role
that can only read `public` and `auth`. Files (`security_fixes/`): `2026-11-12_backup_ro_precheck.sql` (read-only,
decides the variant), `2026-11-12_backup_ro_role.sql` (variant A: explicit grants, default), `..._role_fallback_pg_read_all_data.sql`
(only if the precheck says variant A is impossible and @ciso agrees), `..._verify_after_apply.sql` (read-only,
`== ALL OK ==`; fallback: only `[A]` rows false), `..._rollback.sql` (both variants).
Test: `tests/run_backup_ro_local.sh` (docker, never Supabase, non-superuser `postgres` like on Supabase): a real
`pg_dump` as `backup_ro` with the script's flags, restore, and everything the role must not do.
Why SELECT on the 8 token tables and BYPASSRLS stay, the password step (`\password`, never in a file) and the
acceptance test: CEO repo `raporty/zespol/2026-11-12_cto-backup-ro_raport.md`.
After a Supabase auth upgrade adds a table in `auth`, the dump stops at LOCK (DB-ALARM): run the verify file, then the
two `GRANT ... IN SCHEMA auth TO backup_ro` lines of the migration.

## W2: PUBLIC loses EXECUTE on 3 writing SECURITY DEFINER functions (2026-11-12), APPLIED 2026-11-12

@ciso condition W2 (CEO repo `raporty/zespol/2026-11-12_ciso-backup-ro_review.md`, section "Precheck produkcji 12.11"):
must be DONE before the `backup_ro` password step. `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO anon,
authenticated, service_role` for `public.verify_email_token(text,text)`, `public.wc2026_reset(text)` and
`public.wc2026_save(text,int,int,int,int,int,text,text)`. Without it any role that logs in directly (e.g. `backup_ro`)
can set `request.jwt.claims` itself and run these functions with their owner's rights. Callers (checked 2026-11-12):
`verify_email_token` = anon (`docs/app/app.js`, MCP `verify_email` via the anon client); `wc2026_*` = none (Edge
Function `wc2026` writes over `SUPABASE_DB_URL`). Files (`security_fixes/`): `2026-11-12_w2_revoke_public_secdef.sql`
(apply_migration name `revoke_public_secdef_w2_2026_11_12`, guard + post-check in one transaction),
`..._verify_after_apply.sql` (read-only, `== ALL OK ==`; also re-runs @ciso query W2b: PUBLIC may execute only
`get_my_profile_id`, `is_room_member`, `owns_profile`, `wc2026_get_matches`; run once BEFORE apply and keep the
`INFO: ACL` row), `..._rollback.sql` (EXECUTE back to PUBLIC; re-opens W2, only with `backup_ro` without password).
Independent of `backup_ro_role_fallback_2026_11_12` (either order). Test: `tests/run_w2_revoke_local.sh` (docker,
never Supabase): guards, atomicity, both orders, the attack as `backup_ro` before/after, callers still working,
verify sabotage, rollback = pre-state. Report: CEO repo `raporty/zespol/2026-11-12_cto-w2-revoke_raport.md`.
