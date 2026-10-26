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

## W44 (2026-10-26): ROADMAP #19 rest + #20, NOT APPLIED

Files (`security_fixes/`): `2026-10-26_w44_19_20_hardening.sql` (migration),
`..._rollback.sql`, `2026-10-26_w44_live_snapshot.sql` (live bodies read 2026-10-26, md5-verified).
Local proof: `tests/run_w44_local.sh` (postgres:17 in docker; 102 assertions + re-apply abort +
rollback md5). Apply only after @ciso review + user "pchaj":

1. Read-only pre-check: the migration's guard aborts by itself on drift (md5 of 10 functions).
2. `apply_migration` name `w44_19_20_hardening_2026_10_26`, body = the migration file (one unit).
3. Right after: merge branch `fix/w44-19-20` to `main` and push (CI -> Render MCP) and push the
   HF Space. Until then the old code fails on `select *` / anon INSERT (minutes, 1 user).
4. Post-apply checks (read-only): md5 of the 10 functions = values printed by run_w44_local.sh
   ("md5 after"); `has_column_privilege('anon','public.profiles','email','SELECT')` = false;
   `has_function_privilege('anon','public.resend_verification_email(text)','EXECUTE')` = false;
   `has_function_privilege('anon','public.register_profile(text,text,text,text[],text[],text[],text,text,text[],text,text,text,text,text,text[])','EXECUTE')` = false
   (Supabase default ACL grants new functions to anon: the file revokes it explicitly);
   no INSERT policy on profiles; then one real registration through MCP with a `+alias` address.
