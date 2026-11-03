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

## W44 (2026-10-26): ROADMAP #19 rest + #20, NOT APPLIED (@ciso: GO z warunkami, W1-W8 done)

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
