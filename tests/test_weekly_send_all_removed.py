"""
Regression tests for the removal of the weekly "send to everyone" path (2026-11-25, user variant A).

- the GitHub Actions workflow that called send_all_weekly_matches_emails with the anon key is gone
- no Python code calls send_all_weekly_matches_emails any more
- the MCP tool send_weekly_matches_email still works for the logged-in owner, only via the per-profile RPC
- the REVOKE migration targets the exact signature and the three client roles
"""
import os
import pathlib

from auth import magic_link as ml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def test_weekly_workflow_removed():
    assert not (ROOT / ".github/workflows/weekly-matches-email.yml").exists()
    for wf in (ROOT / ".github/workflows").glob("*.y*ml"):
        assert "send_all_weekly_matches_emails" not in wf.read_text(encoding="utf-8")


def test_no_python_caller_of_send_all():
    hits = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", "tests", "__pycache__"}
                       and not d.startswith(".venv")]
        for name in filenames:
            if name.endswith(".py"):
                path = pathlib.Path(dirpath) / name
                if "send_all_weekly_matches_emails" in path.read_text(encoding="utf-8", errors="ignore"):
                    hits.append(str(path.relative_to(ROOT)))
    assert hits == []


def _tool():
    from core.profiles import quality
    captured = {}

    class Mcp:
        def tool(self, fn):
            captured[fn.__name__] = fn
            return fn

    quality.register_tools(Mcp())
    return quality, captured["send_weekly_matches_email"]


def test_owner_send_uses_only_per_profile_rpc(monkeypatch):
    quality, tool = _tool()
    calls = []

    class Resp:
        data = {"success": True, "matches_sent": 2}

    class Client:
        def rpc(self, name, params=None):
            calls.append((name, params))
            return self

        def execute(self):
            return Resp()

    monkeypatch.setattr(quality, "get_supabase", lambda: object())
    monkeypatch.setattr(quality, "get_profile_email", lambda pid: "owner@example.test")
    monkeypatch.setattr(ml, "get_session", lambda: {"email": "Owner@example.test"})
    monkeypatch.setattr(ml, "_get_service_client", lambda: Client())
    r = tool("me")
    assert r["success"] is True and r["matches_sent"] == 2
    assert calls == [("send_weekly_matches_email", {"p_profile_id": "me"})]


def test_empty_profile_id_is_refused_without_rpc(monkeypatch):
    quality, tool = _tool()

    class Client:
        def rpc(self, *a, **k):
            raise AssertionError("no RPC expected")

    monkeypatch.setattr(quality, "get_supabase", lambda: object())
    monkeypatch.setattr(ml, "get_session", lambda: {"email": "owner@example.test"})
    monkeypatch.setattr(ml, "_get_service_client", lambda: Client())
    r = tool("")
    assert "profile_id is required" in r["error"]


def test_revoke_migration_targets_exact_signature():
    sql = (ROOT / "sql/security_fixes/2026-11-25_revoke_send_all_weekly.sql").read_text(encoding="utf-8")
    assert "REVOKE EXECUTE ON FUNCTION public.send_all_weekly_matches_emails() FROM anon, authenticated, public;" in sql
    assert sql.lstrip("-= \n").startswith("NOT APPLIED")
    rb = (ROOT / "sql/security_fixes/2026-11-25_revoke_send_all_weekly_rollback.sql").read_text(encoding="utf-8")
    assert "GRANT EXECUTE ON FUNCTION public.send_all_weekly_matches_emails() TO public, anon, authenticated;" in rb
