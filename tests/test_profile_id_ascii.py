"""
Regression tests for profile ID generation (2026-10-17, triage unknownews #9 → @cto, review @ciso).

A display name with a Cyrillic look-alike used to produce a different profile ID that
renders like an existing one ("przemеk_(snow)" vs "przemek_(snow)").
"""
import pytest

from utils.validation import profile_id_from_name


@pytest.mark.parametrize("name, expected", [
    ("Przemek (SNOW)", "przemek_(snow)"),   # existing production ID must stay the same
    ("SNOW", "snow"),
    ("Jan-Kowalski", "jan_kowalski"),
    ("Paweł", "pawel"),                     # Polish ł has no NFKD decomposition
    ("Łukasz Żółć", "lukasz_zolc"),
    ("José", "jose"),
    ("Søren", "soren"),
])
def test_latin_names_fold_to_ascii(name, expected):
    pid, err = profile_id_from_name(name)
    assert err == ""
    assert pid == expected


@pytest.mark.parametrize("name", [
    "przemеk (snow)",   # Cyrillic е (U+0435)
    "рrzemek",          # Cyrillic р (U+0440)
    "Przemek​",         # zero-width space
    "Ｐｒｚｅｍｅｋ (SNOW)",  # fullwidth letters fold via NFKD, so they are accepted below
])
def test_non_latin_lookalikes_rejected(name):
    pid, err = profile_id_from_name(name)
    if name.startswith("Ｐ"):
        # NFKD maps fullwidth to ASCII: same ID as the original, which the
        # "already exists" check then refuses. No new look-alike ID is created.
        assert pid == "przemek_(snow)"
        return
    assert pid == ""
    assert err


@pytest.mark.parametrize("name", ["Admin", "support", "The Backroom", "the-backroom", "(admin)"])
def test_reserved_names_refused(name):
    pid, err = profile_id_from_name(name)
    assert pid == ""
    assert "reserved" in err


@pytest.mark.parametrize("name", ["", "   ", "a/b", "x;drop"])
def test_invalid_names_rejected(name):
    pid, err = profile_id_from_name(name)
    assert pid == ""
    assert err
