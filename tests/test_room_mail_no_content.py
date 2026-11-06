"""
Room message notification without message content (2026-11-05): static checks of the migration files
and the policy. The SQL behaviour is tested on postgres:17 by sql/tests/run_room_mail_local.sh.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "sql/security_fixes/2026-11-05_room_mail_no_content"
MIG = BASE.with_name(BASE.name + ".sql")
RB = BASE.with_name(BASE.name + "_rollback.sql")
VERIFY = BASE.with_name(BASE.name + "_verify_after_apply.sql")
SNAPSHOT_MD5 = "ca322bde9b801dec4274ccc1738f43e2"


def _code_lines(src):
    return [l.strip() for l in src.splitlines() if l.strip() and not l.strip().startswith("--")]


def _function(src):
    return src.split("CREATE OR REPLACE FUNCTION public.notify_room_message()", 1)[1].split("$function$;", 1)[0]


def test_migration_and_rollback_are_guarded_transactions():
    for path in (MIG, RB):
        lines = _code_lines(path.read_text(encoding="utf-8"))
        assert lines[0] == "BEGIN;" and lines[-1] == "COMMIT;", path.name
        assert "RAISE EXCEPTION" in path.read_text(encoding="utf-8")
    assert SNAPSHOT_MD5 in MIG.read_text(encoding="utf-8").split("CREATE OR REPLACE FUNCTION", 1)[0]


def test_new_body_has_no_message_field():
    fn = _function(MIG.read_text(encoding="utf-8"))
    assert not re.search(r"NEW\.(subject|body|deadline|from_profile_id)|sender_name|\|\| NEW\.", fn)
    assert "You have a new message in room" in fn and 'href="https://www.thebackroom.ai"' in fn


def test_new_body_keeps_the_rest_of_the_notification():
    fn = _function(MIG.read_text(encoding="utf-8"))
    for needle in ("p.email_verified = true", "p.notifications_enabled = true",
                   "tb_html(COALESCE(room_name, ''))", "tb_subject(",
                   "tb_email_send_allowed(recipient.email, 'notification', 20, interval '24 hours', 200)",
                   "SECURITY DEFINER", "SET search_path TO 'public', 'pg_temp'"):
        assert needle in fn, needle


def test_rollback_restores_the_w44_production_body():
    w44 = (ROOT / "sql/security_fixes/2026-10-26_w44_19_20_hardening.sql").read_text(encoding="utf-8")
    assert _function(w44) == _function(RB.read_text(encoding="utf-8"))


def test_verify_file_is_read_only():
    code = "\n".join(_code_lines(VERIFY.read_text(encoding="utf-8"))).lower()
    no_literals = re.sub(r"'[^']*'", "''", code)
    assert not re.search(r"\b(insert|update|delete|grant|revoke|create|drop|alter|truncate)\b", no_literals)


def test_send_paths_copy_has_production_md5():
    fixture = (ROOT / "sql/tests/live_room_send_functions.sql").read_text(encoding="utf-8")
    for digest in ("ca1c13939521b694f4a2bed53b999c95", "742cabd5fe79f590b6072259fabb72cb"):
        assert digest in fixture


def test_no_security_fix_redefines_the_send_functions():
    """A fix of the send order must also update the W4 test copy and the policy."""
    for path in (ROOT / "sql/security_fixes").glob("*.sql"):
        src = path.read_text(encoding="utf-8")
        assert not re.search(r"CREATE (OR REPLACE )?FUNCTION (public\.)?(send_room_message|respond_to_message)\b", src), path.name


def test_send_paths_verify_guards_no_trigger_and_cannot_go_falsely_green():
    src = BASE.with_name("2026-11-05_room_mail_send_paths_verify.sql").read_text(encoding="utf-8")
    assert "bool_and(COALESCE(ok, false))" in src and "ok IS NOT TRUE" in src
    assert "'no trigger on room_messages or message_recipients'" in src
    assert "'notify_room_message attached to no trigger'" in src
    assert "COALESCE(md5(pg_get_functiondef(to_regprocedure('public.notify_room_message()'))) = '43370bf649dc583d902aa655831ba951', false)" in src


def test_drop_trigger_migration_and_rollback():
    mig = BASE.with_name("2026-11-05_drop_room_message_trigger.sql").read_text(encoding="utf-8")
    rb = BASE.with_name("2026-11-05_drop_room_message_trigger_rollback.sql").read_text(encoding="utf-8")
    for src in (mig, rb):
        lines = _code_lines(src)
        assert lines[0] == "BEGIN;" and lines[-1] == "COMMIT;"
        assert "156e5d9d683c7204ee4ec09afa96fe2e" in src and "43370bf649dc583d902aa655831ba951" in src
    assert "DROP TRIGGER on_room_message_sent ON public.room_messages;" in mig
    assert "DROP FUNCTION" not in mig  # the function stays for the rollback
    assert "CREATE TRIGGER on_room_message_sent AFTER INSERT ON public.room_messages" in rb


def test_w44_rollback_refuses_after_later_migrations():
    src = (ROOT / "sql/security_fixes/2026-10-26_w44_19_20_hardening_rollback.sql").read_text(encoding="utf-8")
    guard = src.index("later migrations changed the mail functions")
    assert guard < src.index("DROP POLICY room_members_delete")
    for digest in (SNAPSHOT_MD5, "36739fc73168e1a322c3b2654f793ac9", "5f9f831afdd47c99a9695c1c780f5ab0"):
        assert digest in src[:guard]
