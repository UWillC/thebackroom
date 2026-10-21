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
