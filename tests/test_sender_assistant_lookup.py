"""ROADMAP #29: send_room_message resolves from_assistant_id from from_assistant_name.

Live cause: "@ceo" was passed to ilike against the stored "CEO", nothing matched,
from_assistant_id stayed NULL and the sender got its own broadcast. The lookup now
trims, drops a leading "@" and compares case-insensitively, exactly (no wildcards).
"""
from types import SimpleNamespace

import pytest

ROOM = "6daf8274-cd26-4109-ae44-8e2bf9e4d591"
ME = "przemek_(snow)"
CEO_ID = "11111111-1111-1111-1111-111111111111"


def _exec(data):
    return SimpleNamespace(execute=lambda: SimpleNamespace(data=data))


@pytest.fixture
def send(monkeypatch):
    from enterprise.messaging import send as mod
    captured = {}
    state = SimpleNamespace(assistants=[], rpc_calls=[], table_filters=[])

    class Mcp:
        def tool(self, fn):
            captured[fn.__name__] = fn
            return fn

    class Query:
        def __init__(self, table):
            self.table, self.filters = table, []

        def select(self, cols):
            self.filters.append(("select", cols))
            return self

        def eq(self, col, val):
            self.filters.append(("eq", col, val))
            return self

        def ilike(self, *a):  # must not be used any more
            raise AssertionError("ilike used for assistant lookup")

        def limit(self, n):
            self.filters.append(("limit", n))
            return self

        def execute(self):
            state.table_filters.append((self.table, list(self.filters)))
            if self.table == "assistant_profiles":
                owner = [f[2] for f in self.filters if f[0] == "eq" and f[1] == "human_profile_id"]
                rows = [r for r in state.assistants if r["human_profile_id"] in owner]
                return SimpleNamespace(data=[{"id": r["id"], "name": r["name"]} for r in rows])
            return SimpleNamespace(data=[{"id": "r1"}])

    class Client:
        def rpc(self, name, params):
            state.rpc_calls.append((name, params))
            if name == "is_room_member":
                return _exec(True)
            return _exec("msg-1")

        def table(self, name):
            return Query(name)

    mod.register_tools(Mcp())
    monkeypatch.setattr(mod, "get_supabase", lambda: object())
    monkeypatch.setattr(mod, "get_supabase_with_auth", lambda: Client())
    state.assistants = [
        {"id": CEO_ID, "name": "CEO", "human_profile_id": ME},
        {"id": "22222222-2222-2222-2222-222222222222", "name": "MIND", "human_profile_id": ME},
        {"id": "33333333-3333-3333-3333-333333333333", "name": "CEO", "human_profile_id": "someone_else"},
    ]
    return captured["send_room_message"], state


def _sent_params(state):
    return [p for n, p in state.rpc_calls if n == "send_room_message"][0]


@pytest.mark.parametrize("name", ["@ceo", "CEO", "  @ceo ", "ceo", "@CEO"])
def test_name_variants_resolve_sender_assistant(send, name):
    fn, state = send
    r = fn(ROOM, ME, "subj", "body", from_assistant_name=name)
    assert r.get("success"), r
    params = _sent_params(state)
    assert params["p_from_assistant_id"] == CEO_ID
    # display name is passed on as given (sanitised), not rewritten
    assert params["p_from_assistant_name"] == name.strip()


def test_lookup_scoped_to_sender_profile(send):
    fn, state = send
    fn(ROOM, ME, "subj", "body", from_assistant_name="@ceo")
    lookups = [f for t, f in state.table_filters if t == "assistant_profiles"]
    assert lookups == [[("select", "id, name"), ("eq", "human_profile_id", ME)]]


@pytest.mark.parametrize("name", ["C%", "%", "C_O", "___", "C*", "*"])
def test_wildcard_characters_do_not_match_other_assistants(send, name):
    fn, state = send
    r = fn(ROOM, ME, "subj", "body", from_assistant_name=name)
    assert r.get("success"), r
    assert "p_from_assistant_id" not in _sent_params(state)


def test_literal_wildcard_name_matches_only_itself(send):
    fn, state = send
    state.assistants.append({"id": "44444444-4444-4444-4444-444444444444", "name": "C_O", "human_profile_id": ME})
    fn(ROOM, ME, "subj", "body", from_assistant_name="@c_o")
    assert _sent_params(state)["p_from_assistant_id"] == "44444444-4444-4444-4444-444444444444"


@pytest.mark.parametrize("name", ["", "   ", "@", " @ "])
def test_empty_name_after_normalisation_skips_lookup(send, name):
    fn, state = send
    r = fn(ROOM, ME, "subj", "body", from_assistant_name=name)
    assert r.get("success"), r
    assert "p_from_assistant_id" not in _sent_params(state)
    assert not [t for t, _ in state.table_filters if t == "assistant_profiles"]


def test_unknown_name_leaves_assistant_id_unset(send):
    fn, state = send
    fn(ROOM, ME, "subj", "body", from_assistant_name="@cmo")
    assert "p_from_assistant_id" not in _sent_params(state)


def test_other_humans_assistant_never_matched(send):
    fn, state = send
    state.assistants = [a for a in state.assistants if a["human_profile_id"] != ME]
    fn(ROOM, ME, "subj", "body", from_assistant_name="@ceo")
    assert "p_from_assistant_id" not in _sent_params(state)
