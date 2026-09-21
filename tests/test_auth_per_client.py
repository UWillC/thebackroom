"""
Security regression tests for per-client MCP sessions (fix 2026-09-21).

Before the fix the server kept ONE global session: an anonymous client got
authenticated:true with the owner's email, and auth_verify_email(email) minted
a full session for any registered address. These tests pin the fixed behaviour
without touching the network.
"""
import inspect
from types import SimpleNamespace

import pytest

from auth import magic_link as ml

BEARER_A = "a" * 64
BEARER_B = "b" * 64


class FakeQuery:
    def __init__(self, rows):
        self.rows = rows
        self.op = None
        self.payload = None
        self.filters = []

    def select(self, _cols):
        self.op = "select"
        return self

    def upsert(self, payload):
        self.op = "upsert"
        self.payload = payload
        return self

    def delete(self):
        self.op = "delete"
        return self

    def eq(self, col, val):
        self.filters.append(("eq", col, val))
        return self

    def lt(self, col, val):
        self.filters.append(("lt", col, val))
        return self

    def limit(self, _n):
        return self

    def _match(self, row):
        for kind, col, val in self.filters:
            if kind == "eq" and row.get(col) != val:
                return False
            if kind == "lt" and not (row.get(col) < val):
                return False
        return True

    def execute(self):
        if self.op == "upsert":
            self.rows[self.payload["client_key_hash"]] = dict(self.payload)
            return SimpleNamespace(data=[self.payload])
        if self.op == "delete":
            for key in [k for k, r in self.rows.items() if self._match(r)]:
                del self.rows[key]
            return SimpleNamespace(data=[])
        return SimpleNamespace(data=[r for r in self.rows.values() if self._match(r)])


class FakeServiceClient:
    def __init__(self):
        self.rows = {}

    def table(self, name):
        assert name == ml.CLIENT_SESSION_TABLE
        return FakeQuery(self.rows)


@pytest.fixture
def remote(monkeypatch):
    """Remote transport with an in-memory session table and settable headers."""
    state = SimpleNamespace(headers={}, db=FakeServiceClient())
    monkeypatch.setenv("MCP_TRANSPORT", "http")
    monkeypatch.setattr(ml, "_request_headers", lambda: state.headers)
    monkeypatch.setattr(ml, "_get_service_client", lambda: state.db)
    return state


def _session(email="owner@example.com"):
    return {
        "access_token": "jwt",
        "refresh_token": "rt",
        "user_id": "00000000-0000-0000-0000-000000000001",
        "email": email,
        "expires_at": 4102444800,  # year 2100: no refresh in tests
    }


def test_anonymous_client_never_sees_another_clients_session(remote):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    assert ml._save_session(_session()) is True
    assert ml.auth_status()["authenticated"] is True

    remote.headers = {}
    assert ml.get_session() is None
    status = ml.auth_status()
    assert status["authenticated"] is False
    assert "email" not in status


def test_sessions_are_isolated_between_clients(remote):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session("a@example.com"))
    remote.headers = {"authorization": "Bearer " + BEARER_B}
    assert ml.get_session() is None
    ml._save_session(_session("b@example.com"))
    assert ml.get_session()["email"] == "b@example.com"
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    assert ml.get_session()["email"] == "a@example.com"


def test_connection_id_identifies_a_client_without_bearer(remote):
    remote.headers = {"mcp-session-id": "c" * 32}
    ml._save_session(_session())
    assert ml.auth_status()["client_identity"] == "sid"
    remote.headers = {"mcp-session-id": "d" * 32}
    assert ml.get_session() is None


def test_short_bearer_is_not_an_identity(remote):
    remote.headers = {"authorization": "Bearer short"}
    assert ml._client_key() == (None, None)
    assert ml._save_session(_session()) is False


def test_only_a_hash_of_the_client_secret_is_stored(remote):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())
    stored = repr(remote.db.rows)
    assert BEARER_A not in stored


def test_logout_clears_only_the_calling_client(remote):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session("a@example.com"))
    remote.headers = {"authorization": "Bearer " + BEARER_B}
    ml._save_session(_session("b@example.com"))
    ml.auth_logout()
    assert ml.get_session() is None
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    assert ml.get_session()["email"] == "a@example.com"


def test_verify_email_never_creates_a_session(remote):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    result = ml.verify_auth_by_email("owner@example.com")
    assert result["authenticated"] is False
    assert result["session_created"] is False
    assert remote.db.rows == {}


def test_verify_email_confirms_only_the_callers_own_session(remote):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session("owner@example.com"))
    assert ml.verify_auth_by_email("Owner@Example.com")["authenticated"] is True
    assert ml.verify_auth_by_email("victim@example.com")["authenticated"] is False


def test_no_server_side_link_generation_left_in_the_module():
    source = inspect.getsource(ml)
    code = "\n".join(
        line for line in source.splitlines() if not line.strip().startswith(("#", '"', "any "))
    )
    assert "generate_link(" not in code
    assert ".admin." not in code


def test_authenticated_client_does_not_touch_auth_state():
    # set_session() rotates the refresh token behind our back (BUG-002b).
    assert ".set_session(" not in inspect.getsource(ml.get_authenticated_client)


def test_login_requires_a_client_identity(remote, monkeypatch):
    monkeypatch.setattr(ml, "_anon_client", lambda: object())
    remote.headers = {}
    result = ml.request_magic_link("owner@example.com")
    assert result["success"] is False


def test_link_without_token_is_rejected(remote, monkeypatch):
    monkeypatch.setattr(ml, "_anon_client", lambda: object())
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    result = ml.auth_complete_link("https://example.com/auth/v1/verify?type=magiclink")
    assert result["success"] is False
    assert remote.db.rows == {}


def test_link_token_is_verified_and_bound_to_the_caller(remote, monkeypatch):
    calls = {}

    class FakeAuth:
        def verify_otp(self, params):
            calls.update(params)
            return SimpleNamespace(
                session=SimpleNamespace(access_token="jwt", refresh_token="rt", expires_at=4102444800),
                user=SimpleNamespace(id="u1", email="owner@example.com"),
            )

    monkeypatch.setattr(ml, "_anon_client", lambda: SimpleNamespace(auth=FakeAuth()))
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    token = "t" * 56
    result = ml.auth_complete_link(
        "https://proj.supabase.co/auth/v1/verify?token=%s&type=magiclink&redirect_to=https://x" % token
    )
    assert result["success"] is True
    assert calls == {"token_hash": token, "type": "magiclink"}
    assert ml.get_session()["email"] == "owner@example.com"
    remote.headers = {}
    assert ml.get_session() is None


def test_local_stdio_mode_keeps_a_private_session_file(monkeypatch, tmp_path):
    monkeypatch.delenv("MCP_TRANSPORT", raising=False)
    monkeypatch.setattr(ml, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(ml, "SESSION_FILE", tmp_path / "session.json")
    assert ml._save_session(_session()) is True
    assert ml.get_session()["email"] == "owner@example.com"
    assert oct((tmp_path / "session.json").stat().st_mode)[-3:] == "600"
    ml.auth_logout()
    assert ml.get_session() is None


def test_real_client_construction_and_user_jwt_on_data_api(remote, monkeypatch):
    # No mocks for the Supabase client here: a wrong options class only
    # explodes at construction time (caught before the first deploy).
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_KEY", "test.anon.key")
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())
    client = ml.get_authenticated_client()
    assert client is not None
    builder = client.table("profiles").select("id")
    headers = {k.lower(): v for k, v in dict(builder.request.headers).items()}
    assert headers["authorization"] == "Bearer jwt"
    remote.headers = {}
    assert ml.get_authenticated_client() is None
