"""
W44 (ROADMAP #19 rest + #20, S2 audit 2026-10-23) - code side of
sql/security_fixes/2026-10-26_w44_19_20_hardening.sql.

- registration goes through the register_profile RPC with the service client, never a raw INSERT
- no `select("*")` on profiles (email/auth_user_id/token become unreadable for the public key)
- profile e-mail is read server-side only, for logged-in callers / the owner
- resend uses the service client; status uses get_email_status (no address)
- join_room uses join_room_with_invite and needs a session
- the migration file keeps its safety properties (static checks)
The SQL behaviour itself is tested on postgres:17 by sql/tests/run_w44_local.sh.
"""
import pathlib
import re
from types import SimpleNamespace

import pytest

from auth import magic_link as ml
from core.profiles import crud, email as email_mod
from core import connections
from enterprise.members import invites

ROOT = pathlib.Path(__file__).resolve().parent.parent
MIGRATION = ROOT / "sql/security_fixes/2026-10-26_w44_19_20_hardening.sql"
ROLLBACK = ROOT / "sql/security_fixes/2026-10-26_w44_19_20_hardening_rollback.sql"


class FakeQuery:
    def __init__(self, client, table):
        self.client, self.table, self.op = client, table, "select"
        self.cols = None
        self.payload = None
        self.filters = []

    def select(self, cols="*"):
        self.cols = cols
        return self

    def eq(self, col, val):
        self.filters.append((col, val))
        return self

    def insert(self, payload):
        self.op, self.payload = "insert", payload
        return self

    def update(self, payload):
        self.op, self.payload = "update", payload
        return self

    def execute(self):
        self.client.calls.append(("table", self.table, self.op, self.cols, self.payload, tuple(self.filters)))
        data = self.client.table_data.get((self.table, self.op), [])
        return SimpleNamespace(data=data)


class FakeRpc:
    def __init__(self, client, fn, params):
        self.client, self.fn, self.params = client, fn, params

    def execute(self):
        self.client.calls.append(("rpc", self.fn, self.params))
        return SimpleNamespace(data=self.client.rpc_data.get(self.fn))


class FakeClient:
    def __init__(self, name, table_data=None, rpc_data=None):
        self.name = name
        self.calls = []
        self.table_data = table_data or {}
        self.rpc_data = rpc_data or {}

    def table(self, name):
        return FakeQuery(self, name)

    def rpc(self, fn, params=None):
        return FakeRpc(self, fn, params or {})


def capture_tools(module):
    tools = {}

    class Mcp:
        def tool(self, fn):
            tools[fn.__name__] = fn
            return fn

    module.register_tools(Mcp())
    return tools


REG_ARGS = dict(name="Ann Example", role="Developer", skills="Python, SQL", offers="Reviews",
                seeks="Testers", email="ann@example.com")


# ---------- register_profile ----------

def test_register_uses_rpc_with_service_client(monkeypatch):
    anon = FakeClient("anon")
    service = FakeClient("service", rpc_data={"register_profile": {"success": True, "profile_id": "ann_example"}})
    monkeypatch.setattr(crud, "get_supabase", lambda: anon)
    monkeypatch.setattr(crud, "get_service_client", lambda: service)
    r = capture_tools(crud)["register_profile"](**REG_ARGS)
    assert r.get("success") is True and r["profile_id"] == "ann_example"
    rpc = [c for c in service.calls if c[0] == "rpc"]
    assert rpc and rpc[0][1] == "register_profile"
    params = rpc[0][2]
    assert params["p_id"] == "ann_example" and params["p_email"] == "ann@example.com"
    assert params["p_skills"] == ["Python", "SQL"]
    # nothing the caller could use to self-verify or claim an auth user
    assert not any(k in params for k in ("email_verified", "p_email_verified", "auth_user_id", "p_auth_user_id"))
    assert not any(c[0] == "table" and c[2] == "insert" for c in anon.calls + service.calls)


def test_register_reports_sql_refusal(monkeypatch):
    service = FakeClient("service", rpc_data={"register_profile": {"success": False, "error": "This e-mail already has a profile."}})
    monkeypatch.setattr(crud, "get_supabase", lambda: FakeClient("anon"))
    monkeypatch.setattr(crud, "get_service_client", lambda: service)
    r = capture_tools(crud)["register_profile"](**REG_ARGS)
    assert r == {"error": "This e-mail already has a profile."}


def test_register_fails_closed_without_service_client(monkeypatch):
    anon = FakeClient("anon")
    monkeypatch.setattr(crud, "get_supabase", lambda: anon)
    monkeypatch.setattr(crud, "get_service_client", lambda: None)
    r = capture_tools(crud)["register_profile"](**REG_ARGS)
    assert "unavailable" in r["error"]
    assert not any(c[0] == "table" and c[2] == "insert" for c in anon.calls)


# ---------- no select * on profiles, no e-mail reads with the public key ----------

PY_FILES = [p for p in ROOT.rglob("*.py") if ".venv" not in p.parts and "tests" not in p.parts]


def test_no_select_star_on_profiles():
    offenders = []
    for p in PY_FILES:
        src = p.read_text(encoding="utf-8")
        if re.search(r'table\("profiles"\)\.select\("\*"\)', src) or "/rest/v1/profiles?select=*" in src:
            offenders.append(str(p.relative_to(ROOT)))
    assert offenders == []


def test_no_public_key_read_of_profile_email():
    for p in PY_FILES:
        src = p.read_text(encoding="utf-8")
        for m in re.finditer(r'get_supabase(?:_with_auth)?\(\)\.table\("profiles"\)\.select\(\s*"([^"]*)"', src):
            cols = {c.strip() for c in m.group(1).split(",")}
            assert not cols & {"email", "auth_user_id", "email_verification_token", "*"}, (p, m.group(1))
    app = (ROOT / "app.py").read_text(encoding="utf-8")
    assert "select=id,name,email," not in app and "rpc/get_email_status" in app


def test_profile_updates_request_only_id_back():
    for rel in ("core/profiles/crud.py", "core/profiles/quality.py"):
        src = (ROOT / rel).read_text(encoding="utf-8")
        for line in src.splitlines():
            if '.table("profiles").update(' in line:
                assert '.select("id")' in line, (rel, line.strip())


# ---------- get_profile e-mail ----------

def test_get_profile_email_only_for_logged_in(monkeypatch):
    row = {"id": "ann", "name": "Ann", "bio": ""}
    anon = FakeClient("anon", table_data={("profiles", "select"): [dict(row)]})
    monkeypatch.setattr(crud, "get_supabase", lambda: anon)
    monkeypatch.setattr(crud, "log_profile_view", lambda *a, **k: None)
    monkeypatch.setattr(crud, "get_profile_email", lambda pid: "ann@example.com")
    get_profile = capture_tools(crud)["get_profile"]

    monkeypatch.setattr(crud, "_caller_is_logged_in", lambda: False)
    r = get_profile("ann")
    assert r["profile"]["email"] is None
    assert anon.calls[0][3] == crud.PUBLIC_PROFILE_COLUMNS
    assert "email," not in crud.PUBLIC_PROFILE_COLUMNS.replace("email_verified", "")

    monkeypatch.setattr(crud, "_caller_is_logged_in", lambda: True)
    anon.table_data[("profiles", "select")] = [dict(row)]
    assert get_profile("ann")["profile"]["email"] == "ann@example.com"


# ---------- e-mail tools ----------

def test_resend_uses_service_client(monkeypatch):
    anon = FakeClient("anon")
    service = FakeClient("service", rpc_data={"resend_verification_email": {"success": True, "message": "sent"}})
    monkeypatch.setattr(email_mod, "get_supabase", lambda: anon)
    monkeypatch.setattr(email_mod, "get_service_client", lambda: service)
    r = capture_tools(email_mod)["resend_verification_email"]("ann")
    assert r["success"] is True
    assert service.calls == [("rpc", "resend_verification_email", {"p_profile_id": "ann"})]
    assert anon.calls == []


def test_email_status_uses_flags_rpc(monkeypatch):
    anon = FakeClient("anon", rpc_data={"get_email_status": {
        "found": True, "profile_id": "ann", "name": "Ann", "has_email": True,
        "email_verified": False, "notifications_enabled": True, "verification_sent": True}})
    monkeypatch.setattr(email_mod, "get_supabase", lambda: anon)
    r = capture_tools(email_mod)["check_email_verification_status"]("ann")
    assert r["status"] == "PENDING" and r["has_email"] is True
    assert "@" not in str(r)
    assert anon.calls == [("rpc", "get_email_status", {"p_profile_id": "ann"})]


# ---------- respond_to_request share_email ----------

def _request_client():
    return FakeClient("anon", table_data={
        ("connection_requests", "select"): [{"id": "r1", "status": "pending", "from_user": "bob", "to_user": "ann"}],
        ("connection_requests", "update"): [{"id": "r1"}],
        ("profiles", "select"): [{"name": "Bob"}],
    })


@pytest.mark.parametrize("owned,expected", [("ann@example.com", {"email": "ann@example.com"}), ("", {})])
def test_share_email_only_when_caller_owns_profile(monkeypatch, owned, expected):
    client = _request_client()
    monkeypatch.setattr(connections, "get_supabase", lambda: client)
    monkeypatch.setattr(connections, "owned_profile_email", lambda pid: owned if pid == "ann" else "")
    capture_tools(connections)["respond_to_request"]("r1", True, "", True)
    upd = [c for c in client.calls if c[1] == "connection_requests" and c[2] == "update"]
    assert upd and upd[0][4]["contact_shared"] == expected
    assert not any(c[1] == "profiles" and c[3] and "email" in c[3].split(", ") for c in client.calls)


# ---------- join_room ----------

def test_join_room_requires_session(monkeypatch):
    monkeypatch.setattr(invites, "get_supabase", lambda: FakeClient("anon"))
    monkeypatch.setattr(ml, "get_session", lambda: None)
    r = capture_tools(invites)["join_room"]("tok", "ann")
    assert "Not authenticated" in r["error"]


def test_join_room_uses_rpc(monkeypatch):
    auth_client = FakeClient("auth", rpc_data={"join_room_with_invite": {
        "success": True, "status": "pending", "room_id": "r", "room_name": "Room", "room_type": "enterprise"}})
    monkeypatch.setattr(invites, "get_supabase", lambda: FakeClient("anon"))
    monkeypatch.setattr(invites, "get_supabase_with_auth", lambda: auth_client)
    monkeypatch.setattr(ml, "get_session", lambda: {"email": "ann@example.com"})
    r = capture_tools(invites)["join_room"]("tok", "ann")
    assert r["success"] is True and r["status"] == "pending"
    assert auth_client.calls == [("rpc", "join_room_with_invite", {"p_invite_token": "tok", "p_profile_id": "ann"})]
    assert not any(c[0] == "table" for c in auth_client.calls)


def test_join_room_passes_refusal(monkeypatch):
    auth_client = FakeClient("auth", rpc_data={"join_room_with_invite": {
        "success": False, "error": "Re-joining this room needs the room admin"}})
    monkeypatch.setattr(invites, "get_supabase", lambda: FakeClient("anon"))
    monkeypatch.setattr(invites, "get_supabase_with_auth", lambda: auth_client)
    monkeypatch.setattr(ml, "get_session", lambda: {"email": "x@example.com"})
    assert "admin" in capture_tools(invites)["join_room"]("tok", "ann")["error"]


# ---------- migration file (static) ----------

def _sql(path):
    return path.read_text(encoding="utf-8")


def test_migration_header_says_not_applied():
    head = _sql(MIGRATION)[:400]
    assert "NOT APPLIED" in head and "@ciso" in head and "pchaj" in head


def test_migration_revokes_resend_from_public_and_anon():
    src = _sql(MIGRATION)
    assert re.search(r"REVOKE ALL ON FUNCTION public\.resend_verification_email\(text\) FROM PUBLIC, anon, authenticated;", src)
    assert re.search(r"GRANT EXECUTE ON FUNCTION public\.resend_verification_email\(text\) TO service_role;", src)


def test_migration_new_table_has_explicit_grants():
    src = _sql(MIGRATION)
    assert "CREATE TABLE public.email_send_log" in src
    assert "ALTER TABLE public.email_send_log ENABLE ROW LEVEL SECURITY" in src
    assert "REVOKE ALL ON public.email_send_log FROM PUBLIC, anon, authenticated" in src
    assert "GRANT SELECT, INSERT, DELETE ON public.email_send_log TO service_role" in src


def test_migration_profiles_privileges():
    src = _sql(MIGRATION)
    assert 'DROP POLICY "Anyone can create profile"' in src
    assert "REVOKE INSERT, UPDATE, SELECT, DELETE, REFERENCES, TRIGGER ON public.profiles FROM PUBLIC, anon, authenticated" in src
    grant_select = re.search(r"GRANT SELECT \(([^)]*)\)\s+ON public\.profiles TO anon, authenticated", src).group(1)
    grant_update = re.search(r"GRANT UPDATE \(([^)]*)\)\s+ON public\.profiles TO authenticated", src).group(1)
    sel = {c.strip() for c in grant_select.split(",")}
    upd = {c.strip() for c in grant_update.split(",")}
    assert not sel & {"email", "auth_user_id", "email_verification_token"}
    assert not upd & {"id", "name", "email_verified", "email_verification_token", "email_verification_sent_at", "auth_user_id"}
    # the app's column list = the granted list
    from utils import PUBLIC_PROFILE_COLUMNS
    assert {c.strip() for c in PUBLIC_PROFILE_COLUMNS.split(",")} == sel


def test_migration_functions_pin_search_path_and_guard():
    src = _sql(MIGRATION)
    heads = re.findall(r"CREATE (?:OR REPLACE )?FUNCTION ([^\(]+)\(.*?(?:AS \$)", src, flags=re.S)
    assert len(heads) >= 17
    for block in re.split(r"CREATE (?:OR REPLACE )?FUNCTION ", src)[1:]:
        header = block.split("AS $", 1)[0]
        assert "search_path" in header, header[:80]
    assert "changed since 2026-10-26" in src  # md5 drift guard
    assert src.count("md5_before") >= 2


def test_migration_room_members_self_insert_limits():
    src = _sql(MIGRATION)
    pol = src.split("CREATE POLICY room_members_insert", 1)[1].split(");", 1)[0]
    for needle in ("status = 'pending'", "role = 'member'", "tb_can_self_join(room_id, invite_token, invited_by)",
                   "offboarded_at IS NULL"):
        assert needle in pol
    assert "m.status IN ('offboarded', 'suspended')" in src


def test_mail_functions_have_no_raw_user_values():
    """In the rewritten mail functions every profile/room/message value goes through tb_html."""
    src = _sql(MIGRATION).split("-- ---------- 7. mail functions ----------", 1)[1].split("-- ---------- 8.", 1)[0]
    # subjects are plain text (tb_subject strips control chars); everything else must be escaped
    src = "\n".join(line for line in src.splitlines() if "tb_subject(" not in line)
    raw = re.findall(r"' \|\| (NEW\.(?:name|role|location|message|response_message|subject|body|token|email)"
                     r"|sender_name|recipient_name|recipient_linkedin|inviter_name|room_name|member_name"
                     r"|profile_record\.name|match_record\.\w+) \|\| '", src)
    assert raw == []


def test_rollback_restores_live_bodies():
    rb = _sql(ROLLBACK)
    snap = _sql(ROOT / "sql/security_fixes/2026-10-26_w44_live_snapshot.sql")
    body = snap[snap.index("CREATE OR REPLACE FUNCTION public.send_verification_email"):]
    assert body in rb
    assert "RE-OPENS" in rb[:400]


# ---------- @ciso review 2026-10-26 (W1, W2, W3, W6, W8) ----------

VERIFY = ROOT / "sql/security_fixes/2026-10-26_w44_verify_after_apply.sql"


def _code_lines(src):
    return [l.strip() for l in src.splitlines() if l.strip() and not l.strip().startswith("--")]


def test_w2_migration_and_rollback_are_explicit_transactions():
    for path in (MIGRATION, ROLLBACK):
        lines = _code_lines(_sql(path))
        assert lines[0] == "BEGIN;" and lines[-1] == "COMMIT;", path.name


def test_w1_join_checks_assistant_owner():
    fn = _sql(MIGRATION).split("CREATE FUNCTION public.join_room_with_invite", 1)[1].split("END $$;", 1)[0]
    assert "a.human_profile_id = p_profile_id" in fn
    assert fn.index("human_profile_id = p_profile_id") < fn.index("INSERT INTO room_members")


def test_w6_delete_policy_blocks_own_offboarded_row():
    src = _sql(MIGRATION)
    pol = src.split("CREATE POLICY room_members_delete", 1)[1].split(";", 1)[0]
    assert "status NOT IN ('offboarded', 'suspended')" in pol and "owns_profile(r.owner_id)" in pol
    rb = _sql(ROLLBACK)
    assert "CREATE POLICY room_members_delete" in rb and "OR owns_profile(profile_id));" in rb


def test_w8_rollback_restores_exact_live_acl():
    rb = _sql(ROLLBACK)
    assert "GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO anon, authenticated;" in rb
    assert "REFERENCES, TRIGGER ON public.profiles" not in rb


def test_w3_verify_file_reads_pg_catalog_only():
    src = _sql(VERIFY)
    code = "\n".join(_code_lines(src)).lower()
    assert "information_schema" not in code
    assert "proacl" in code and "relacl" in code and "aclexplode" in code
    for name in ("tb_html", "tb_subject", "tb_safe_url", "tb_email_send_allowed", "tb_can_self_join",
                 "register_profile", "get_email_status", "join_room_with_invite", "email_send_log"):
        assert name in code, name
    no_literals = re.sub(r"'[^']*'", "''", code)
    assert not re.search(r"\b(insert|update|delete|grant|revoke|create|drop|alter|truncate)\b", no_literals), \
        "verify file must be read-only"
