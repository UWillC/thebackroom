"""
x.Feed for the publishable key (@ciso W6, 2026-11-05): static checks of the migration that drops the two legacy
FOR ALL policies. Behaviour (42501 before, 200-equivalent after, identical authorization matrix, hidden columns
still refused) is tested on postgres:17 by sql/tests/run_feed_rls_local.sh.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "sql/security_fixes/2026-11-05_feed_rls_legacy_policies"
MIG = BASE.with_name(BASE.name + ".sql").read_text(encoding="utf-8")
RB = BASE.with_name(BASE.name + "_rollback.sql").read_text(encoding="utf-8")
VER = BASE.with_name(BASE.name + "_verify_after_apply.sql").read_text(encoding="utf-8")
LIVE = (ROOT / "sql/tests/feed_rls_live.sql").read_text(encoding="utf-8")


def _code(src):
    return "\n".join(l for l in src.splitlines() if not l.strip().startswith("--"))


def test_guarded_transactions():
    for src in (MIG, RB):
        lines = [l.strip() for l in _code(src).splitlines() if l.strip()]
        assert lines[0] == "BEGIN;" and lines[-1] == "COMMIT;"
        assert "RAISE EXCEPTION" in src


def test_migration_only_drops_the_two_legacy_policies():
    code = _code(MIG)
    assert re.findall(r"DROP POLICY [^;]+;", code) == [
        'DROP POLICY "Users can manage own posts" ON public.assistant_posts;',
        'DROP POLICY "Users can manage own assistant profiles" ON public.assistant_profiles;',
    ]
    for word in ("GRANT", "REVOKE", "CREATE POLICY", "ALTER POLICY", "ALTER TABLE", "DISABLE"):
        assert word not in code, word


def test_guard_covers_all_12_policies_and_verify_the_10_left():
    guard = re.findall(r"\('(assistant_\w+)',\s+'([^']+)',\s+'(\w+)',\s+'([0-9a-f]{32})'\)", MIG)
    assert len(guard) == 12
    left = re.findall(r"\('(assistant_\w+)',\s+'([^']+)',\s+'(\w+)',\s+'([0-9a-f]{32})'\)", VER)
    assert len(left) == 10
    dropped = {"Users can manage own posts", "Users can manage own assistant profiles"}
    assert {g for g in guard if g[1] not in dropped} == set(left)


def test_rollback_restores_the_exact_live_expressions():
    for name in ("Users can manage own posts", "Users can manage own assistant profiles"):
        live = LIVE.split(f'CREATE POLICY "{name}"', 1)[1].split(";", 1)[0]
        rb = RB.split(f'CREATE POLICY "{name}"', 1)[1].split(";", 1)[0]
        assert live == rb, name
    assert "a896d0258b5956b574c0415bc6578b5b" in RB and "785ffd96edb5701d524bca75747a62da" in RB
