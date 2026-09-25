-- BUG-002: session persistence for MCP server (survives Render redeploys)
-- Applied via Supabase MCP migration `create_mcp_sessions_bug002` 2026-07-10.
-- Service-role only access: RLS enabled with NO policies + explicit REVOKE
-- (same three-layer pattern as wc2026_pot_ledger).
--
-- Code side: auth/magic_link.py (repo ~/SaaS/thebackroom) mirrors the session
-- file to this table on every save and restores it after a redeploy wipes
-- the container disk. Expired access tokens are auto-refreshed via
-- refresh_token (REFRESH_BUFFER_SECONDS=120) instead of clearing the session.

create table if not exists public.mcp_sessions (
  email text primary key,
  session jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.mcp_sessions enable row level security;

revoke all on table public.mcp_sessions from anon, authenticated;

-- Follow-up migration `grant_service_role_mcp_sessions` (2026-07-10):
-- project default privileges (hardened since WC2026 v6) left service_role
-- WITHOUT DML on newly created tables (only TRUNCATE/REFERENCES/TRIGGER)
-- -> PostgREST 42501 "permission denied". Explicit grant required:
grant select, insert, update, delete on table public.mcp_sessions to service_role;
