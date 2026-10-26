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
