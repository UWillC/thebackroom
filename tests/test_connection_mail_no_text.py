"""
Connection mails without text written by the user (2026-11-05): static checks of the migration files.
The SQL behaviour is tested on postgres:17 by sql/tests/run_connection_mail_local.sh.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "sql/security_fixes/2026-11-05_connection_mail_no_text"
MIG = BASE.with_name(BASE.name + ".sql")
RB = BASE.with_name(BASE.name + "_rollback.sql")
VERIFY = BASE.with_name(BASE.name + "_verify_after_apply.sql")
W44 = ROOT / "sql/security_fixes/2026-10-26_w44_19_20_hardening.sql"


def _code_lines(src):
    return [l.strip() for l in src.splitlines() if l.strip() and not l.strip().startswith("--")]


def _function(src, name):
    return src.split(f"CREATE OR REPLACE FUNCTION public.{name}()", 1)[1].split("$function$;", 1)[0]


def test_files_are_guarded_transactions():
    for path in (MIG, RB):
        src = path.read_text(encoding="utf-8")
        lines = _code_lines(src)
        assert lines[0] == "BEGIN;" and lines[-1] == "COMMIT;", path.name
        assert "RAISE EXCEPTION" in src


def test_header_records_the_apply_gate():
    head = MIG.read_text(encoding="utf-8")[:300]
    if "NOT APPLIED" in head:
        assert "@ciso" in head and "pchaj" in head
    else:
        assert re.search(r"APPLIED \d{4}-\d{2}-\d{2}", head) and "@ciso" in head


def test_free_text_is_gone_and_the_rest_stays():
    src = MIG.read_text(encoding="utf-8")
    req, acc = _function(src, "notify_connection_request"), _function(src, "notify_connection_accepted")
    assert "NEW.message" not in req and "NEW.response_message" not in acc
    assert "recipient_linkedin" in acc and "recipient_contact" in acc  # user decision 2026-11-05
    for fn in (req, acc):
        assert "tb_email_send_allowed(" in fn and "SECURITY DEFINER" in fn and "_verified = true" in fn


def test_only_the_free_text_blocks_differ_from_production():
    src, w44 = MIG.read_text(encoding="utf-8"), W44.read_text(encoding="utf-8")
    for name, field in (("notify_connection_request", "message"), ("notify_connection_accepted", "response_message")):
        old = re.sub(rf"    ' \|\| CASE WHEN NEW\.{field} IS NOT NULL.*?' ELSE '' END \|\| '\n\n", "", _function(w44, name), flags=re.S)
        assert _function(src, name) == old, name


def test_rollback_restores_the_production_bodies():
    rb, w44 = RB.read_text(encoding="utf-8"), W44.read_text(encoding="utf-8")
    for name in ("notify_connection_request", "notify_connection_accepted"):
        assert _function(rb, name) == _function(w44, name), name
    assert "RE-OPENS" in rb[:300]


def test_verify_file_is_read_only():
    code = "\n".join(_code_lines(VERIFY.read_text(encoding="utf-8"))).lower()
    assert not re.search(r"\b(insert|update|delete|grant|revoke|create|drop|alter|truncate)\b", re.sub(r"'[^']*'", "''", code))
