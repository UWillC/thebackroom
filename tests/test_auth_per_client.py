"""
Security regression tests for per-client MCP sessions (fix 2026-09-21).

Before the fix the server kept ONE global session: an anonymous client got
authenticated:true with the owner's email, and auth_verify_email(email) minted
a full session for any registered address. These tests pin the fixed behaviour
without touching the network.
"""
import inspect
from types import SimpleNamespace

import httpx
import pytest
from supabase import create_client
from supabase.lib.client_options import SyncClientOptions

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
    # One exception (W15, 2026-11-04): logout with the user's own JWT and the
    # anon key, scope local. Any other admin call, or another scope, fails here.
    allowed = 'client.auth.admin.sign_out(access_token, "local")'
    assert code.count(allowed) == 1
    assert ".admin." not in code.replace(allowed, "")


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


# ============== LOGOUT ENDS THE AUTH SESSION (@ciso W15, 2026-11-04) ==============
# Real supabase client, fake network: pins the request that really goes out.
# client.auth.sign_out() on our stateless client would send nothing at all.

def _wire_client(monkeypatch, handler):
    monkeypatch.setattr(ml, "_anon_client", lambda: create_client(
        "https://example.supabase.co",
        "test.anon.key",
        options=SyncClientOptions(
            httpx_client=httpx.Client(transport=httpx.MockTransport(handler)),
            auto_refresh_token=False,
            persist_session=False,
        ),
    ))


def test_logout_ends_only_this_session_before_deleting_the_row(remote, monkeypatch):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())
    calls = []

    def handler(request):
        # The row must still exist: if this call fails we keep nothing unsent.
        calls.append((request, len(remote.db.rows)))
        return httpx.Response(204)

    _wire_client(monkeypatch, handler)
    result = ml.auth_logout()

    assert len(calls) == 1
    request, rows_during_call = calls[0]
    assert rows_during_call == 1
    assert request.method == "POST"
    assert request.url.path == "/auth/v1/logout"
    assert request.url.params["scope"] == "local"
    assert request.headers["authorization"] == "Bearer jwt"
    assert request.headers["apikey"] == "test.anon.key"
    assert result["success"] is True
    assert result["server_session_ended"] is True
    assert remote.db.rows == {}


@pytest.mark.parametrize("failure", ["network", "http_500", "http_403"])
def test_logout_failure_on_server_does_not_block_local_logout(remote, monkeypatch, capsys, failure):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())

    def handler(request):
        if failure == "network":
            raise httpx.ConnectError("no route")
        return httpx.Response(int(failure[-3:]), json={"code": 0, "msg": "nope"})

    _wire_client(monkeypatch, handler)
    result = ml.auth_logout()

    assert result["success"] is True
    assert result["server_session_ended"] is False
    assert "did not confirm" in result["message"]
    assert remote.db.rows == {}
    assert ml.get_session() is None
    assert "jwt" not in capsys.readouterr().out


def test_logout_survives_client_construction_failure(remote, monkeypatch):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())

    def boom():
        raise RuntimeError("bad config")

    monkeypatch.setattr(ml, "_anon_client", boom)
    assert ml.auth_logout()["server_session_ended"] is False
    assert remote.db.rows == {}


def test_logout_leaves_other_clients_of_the_same_account_alone(remote, monkeypatch):
    remote.headers = {"authorization": "Bearer " + BEARER_B}
    other = dict(_session(), access_token="other-jwt")
    ml._save_session(other)
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())
    tokens = []

    def handler(request):
        tokens.append(request.headers["authorization"])
        return httpx.Response(204)

    _wire_client(monkeypatch, handler)
    ml.auth_logout()

    assert tokens == ["Bearer jwt"]
    remote.headers = {"authorization": "Bearer " + BEARER_B}
    assert ml.get_session()["access_token"] == "other-jwt"


def test_logout_refreshes_an_expired_token_first(remote, monkeypatch):
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(dict(_session(), access_token="old-jwt", expires_at=1))
    monkeypatch.setattr(ml, "_try_refresh", lambda s: dict(s, access_token="new-jwt"))
    tokens = []

    def handler(request):
        tokens.append(request.headers["authorization"])
        return httpx.Response(204)

    _wire_client(monkeypatch, handler)
    assert ml.auth_logout()["server_session_ended"] is True
    assert tokens == ["Bearer new-jwt"]


def test_logout_without_a_session_sends_nothing(remote, monkeypatch):
    def handler(request):
        raise AssertionError("no session, no request")

    _wire_client(monkeypatch, handler)
    remote.headers = {}
    result = ml.auth_logout()
    assert result["success"] is True
    assert result["server_session_ended"] is False
    assert "did not confirm" not in result["message"]


def test_logout_in_stdio_mode_removes_the_file_when_server_fails(monkeypatch, tmp_path):
    monkeypatch.delenv("MCP_TRANSPORT", raising=False)
    monkeypatch.setattr(ml, "CONFIG_DIR", tmp_path)
    monkeypatch.setattr(ml, "SESSION_FILE", tmp_path / "session.json")
    ml._save_session(_session())

    def handler(request):
        raise httpx.ConnectError("no route")

    _wire_client(monkeypatch, handler)
    assert ml.auth_logout()["server_session_ended"] is False
    assert not (tmp_path / "session.json").exists()


def test_refresh_does_not_bring_back_a_row_after_unconfirmed_logout(remote, monkeypatch):
    """Logout wins the race for the lock, server did not confirm: the row stays gone."""
    remote.headers = {"authorization": "Bearer " + BEARER_A}
    ml._save_session(_session())
    monkeypatch.setattr(ml, "_end_auth_session", lambda session: False)
    real_lock_for = ml._lock_for

    class LogoutFirst:
        """Logout runs right before refresh gets the lock."""

        def __enter__(self):
            monkeypatch.setattr(ml, "_lock_for", real_lock_for)
            assert ml.auth_logout()["server_session_ended"] is False
            assert remote.db.rows == {}

        def __exit__(self, *exc):
            return False

    monkeypatch.setattr(ml, "_lock_for", lambda key: LogoutFirst())
    monkeypatch.setattr(ml, "_try_refresh", lambda s: ml._save_session(s) and s)

    result = ml.refresh_session()

    assert result == {"success": False, "error": "No session to refresh"}
    assert remote.db.rows == {}
    assert ml.get_session() is None
