-- Security fix 2026-09-21: MCP sessions are per client, not global.
-- Applied via migration create_mcp_client_sessions_security_fix (21.09.2026).
-- One row per MCP client, keyed by SHA-256 of a secret only that client holds
-- (Authorization bearer from its MCP config, or its Mcp-Session-Id).
-- Service-role only: RLS on, zero policies, no grants to anon/authenticated.
create table if not exists public.mcp_client_sessions (
    client_key_hash text primary key,
    kind text not null check (kind in ('bearer', 'sid')),
    email text,
    user_id uuid,
    session jsonb not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
alter table public.mcp_client_sessions enable row level security;
revoke all on public.mcp_client_sessions from anon, authenticated, public;
create index if not exists mcp_client_sessions_kind_updated_idx
    on public.mcp_client_sessions (kind, updated_at);
comment on table public.mcp_client_sessions is
    'Per-client MCP sessions (security fix 2026-09-21). Service-role only. Replaces the global mcp_sessions mirror.';

-- Migration grant_service_role_mcp_client_sessions (21.09.2026): default privileges
-- for new tables are off in this project (hardening 2026-05-13), so the service
-- role needs an explicit grant. anon/authenticated stay without any.
grant select, insert, update, delete on public.mcp_client_sessions to service_role;

-- Migration revoke_truncate_and_mail_rpc_from_public_roles (22.09.2026, @ciso #36b B4 → @cto):
-- TRUNCATE (not subject to RLS) taken from anon/authenticated/public on all public tables;
-- send_weekly_matches_email(text) executable only by service_role (MCP tool checks the session);
-- trigger functions notify_*/send_verification_email/send_welcome_email_after_verification
-- no longer executable by client roles. Kept for anon: RLS helpers, verify_email_token,
-- resend_verification_email (onboarding before login, SQL rate limit), wc2026_* (key-gated).
revoke truncate on all tables in schema public from anon, authenticated, public;
revoke execute on function public.send_weekly_matches_email(text) from anon, authenticated, public;
grant execute on function public.send_weekly_matches_email(text) to service_role;
