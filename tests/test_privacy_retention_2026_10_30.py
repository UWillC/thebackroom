"""
Privacy policy (docs/privacy.html) + retention migration 2026-10-30 (@ciso review W1-W8, @ceo A/B/C).

Static checks only. The SQL behaviour (retention triggers, tb_delete_account, atomicity, rollback)
is tested on postgres:17 by sql/tests/run_privacy_local.sh.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIG = ROOT / "sql/security_fixes/2026-10-30_privacy_retention.sql"
RB = ROOT / "sql/security_fixes/2026-10-30_privacy_retention_rollback.sql"
VERIFY = ROOT / "sql/security_fixes/2026-10-30_privacy_retention_verify_after_apply.sql"
SMOKE = ROOT / "sql/security_fixes/2026-10-30_privacy_retention_smoke.sql"
README = ROOT / "sql/README.md"
POLICY = ROOT / "docs/privacy.html"
LANDING = ROOT / "docs/index.html"


def test_migration_is_one_explicit_transaction_with_guard():
    sql = MIG.read_text()
    assert re.search(r"^BEGIN;$", sql, re.M) and re.search(r"^COMMIT;$", sql, re.M)
    assert "already applied" in sql
    assert re.search(r"^BEGIN;$", RB.read_text(), re.M)


def test_retention_periods_match_policy():
    sql = MIG.read_text()
    policy = POLICY.read_text()
    assert "audit_logs    WHERE created_at < now() - interval '90 days'" in sql
    assert "search_logs   WHERE created_at < now() - interval '12 months'" in sql
    assert "profile_stats WHERE created_at < now() - interval '12 months'" in sql
    assert "rate_limits   WHERE created_at < now() - interval '7 days'" in sql
    assert "<strong>Change history:</strong> 90 days." in policy
    assert "<strong>Search records and profile statistics:</strong> 12 months." in policy
    assert "<strong>Rate limit records:</strong> 7 days." in policy


def test_functions_are_definer_with_search_path_and_not_api_callable():
    sql = MIG.read_text()
    assert sql.count("SECURITY DEFINER SET search_path TO 'public', 'pg_temp'") == 2
    assert "REVOKE ALL ON FUNCTION public.tb_delete_account(text) FROM PUBLIC, anon, authenticated, service_role;" in sql
    assert "REVOKE ALL ON FUNCTION public.tb_retention_cleanup() FROM PUBLIC, anon, authenticated, service_role;" in sql
    assert "no pg_cron" in sql  # mechanism = trigger on write, like email_send_log


def test_landing_has_no_google_analytics():
    html = LANDING.read_text()
    assert "G-F10CMB9L3T" not in html and "googletagmanager" not in html and "gtag(" not in html


def test_policy_form_and_opsec():
    policy = POLICY.read_text()
    assert "—" not in policy
    assert not re.search(r"\b(NATO|NCIA|military|norfolk|virginia)\b", policy, re.I)
    assert "Przemysław Snowacki" in policy
    assert "Google Analytics" not in policy.replace("does not use Google Analytics", "")
    assert "<script" not in policy
    # True by construction: no trigger mails room messages (drop_room_message_trigger_2026_11_05).
    # Guard on production: security_fixes/2026-11-05_room_mail_send_paths_verify.sql. Change them together.
    assert "We do not send e-mail when a message is sent to you in a room." in policy
    assert "Room messages are not sent by e-mail, so Resend does not receive their subject or text." in policy
    assert "room message notification" not in policy.lower()


def test_w1_audit_match_is_per_field_not_text_search_on_profile_id():
    sql = MIG.read_text()
    assert "'\"' || p_profile_id || '\"'" not in sql  # the search that also hit JSON keys and values
    for table in ("profiles", "connection_requests", "rooms", "room_members"):
        assert f"a.table_name = '{table}'" in sql


def test_w2_room_traces_and_old_sessions_are_deleted():
    sql = MIG.read_text()
    assert "UPDATE room_audit_log SET target_id = NULL WHERE target_id = p_profile_id;" in sql
    assert "UPDATE room_audit_log SET details = '{}'::jsonb" in sql
    assert "lower(email) = lower(v_email)" in sql.split("DELETE FROM room_invites", 1)[1].split(";", 1)[0]
    assert "DELETE FROM mcp_sessions WHERE lower(email) = lower(v_email);" in sql
    assert "to_regclass('public.mcp_sessions')" in sql  # guard


def test_w3_verify_checks_trigger_state_function_settings_and_service_role():
    verify = VERIFY.read_text()
    assert "tgenabled = 'O'" in verify and "tgtype = 4" in verify and "tgfoid" in verify
    assert "search_path=public, pg_temp" in verify and "proowner" in verify
    assert "has_function_privilege('service_role', 'public.tb_retention_cleanup()', 'EXECUTE')" in verify
    assert "only right after applying" in verify


def test_w3_smoke_cannot_leave_rows_behind_and_is_in_the_runbook():
    smoke = SMOKE.read_text()
    assert "RETENTION_SMOKE_OK" in smoke and "RETENTION_SMOKE_FAIL" in smoke
    assert "COMMIT" not in smoke.upper()  # the block always ends in RAISE EXCEPTION, which rolls it back
    assert "2026-10-30_privacy_retention_smoke.sql" in README.read_text()


def test_header_states_the_owner_decision():
    assert "to be confirmed by @ceo" not in MIG.read_text()
