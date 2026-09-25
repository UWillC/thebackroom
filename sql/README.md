# SQL (Supabase)

Schema, RLS, triggers and security fixes for The Backroom, as applied in the Supabase SQL editor
or via MCP migrations. Moved here from a folder outside version control on 2026-09-25, so every
future migration lands in the same repo as the code that depends on it.

Rules:
- **New table = explicit `GRANT ... TO service_role`.** Default privileges for new tables are off
  in this project (hardening 2026-05-13). Pattern: `mcp_client_sessions.sql`.
- `security_fixes/` = dated fixes; the file header says what was wrong and how it was verified.
- Not kept here on purpose: one-off data scripts (test inserts, email fixes for a single profile,
  "clear all data") and state dumps. They contained personal data or are destructive by design.
