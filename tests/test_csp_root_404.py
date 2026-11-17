"""
CSP on the landing page and on the 404 page (2026-11-17). Static checks of docs/_headers against what
docs/index.html, docs/404.html and docs/widget.js load. Browser check: tests/csp_root_404/run_headless.mjs.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
HEADERS = (DOCS / "_headers").read_text(encoding="utf-8")
INDEX = (DOCS / "index.html").read_text(encoding="utf-8")
NOT_FOUND = (DOCS / "404.html").read_text(encoding="utf-8")
WIDGET = (DOCS / "widget.js").read_text(encoding="utf-8")
WEBHOOK = "https://3w7nw22j1d.execute-api.us-east-1.amazonaws.com/webhook/feedback"
BASELINE = ("default-src 'none'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
LANDING = ("default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self'; "
           f"connect-src {WEBHOOK}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")


def _rules():
    rules, cur = [], None
    for raw in HEADERS.splitlines():
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        if not raw[0].isspace():
            cur = {"path": raw.strip(), "set": [], "unset": []}
            rules.append(cur)
        elif raw.strip().startswith("! "):
            cur["unset"].append(raw.strip()[2:].strip())
        else:
            k, v = raw.strip().split(":", 1)
            cur["set"].append((k.strip(), v.strip()))
    return rules


def test_baseline_is_the_first_rule_and_strict():
    first = _rules()[0]
    assert first["path"] == "/*"
    assert first["set"] == [("Content-Security-Policy", BASELINE)]
    assert "script-src" not in BASELINE and "connect-src" not in BASELINE


def test_every_other_csp_detaches_the_baseline_and_sets_one_policy():
    # Without the detach Pages appends both values and the browser enforces the intersection.
    for r in _rules()[1:]:
        csp = [v for k, v in r["set"] if k == "Content-Security-Policy"]
        assert len(csp) <= 1, r["path"]
        if csp:
            assert r["unset"] == ["Content-Security-Policy"], r["path"]
        else:
            assert not r["unset"], r["path"]


def test_landing_policy():
    root = next(r for r in _rules() if r["path"] == "/")
    assert ("Content-Security-Policy", LANDING) in root["set"]
    assert any(k == "Link" for k, _ in root["set"])


def test_landing_loads_only_what_the_policy_allows():
    # no executable inline script: the only inline <script> is JSON-LD data
    scripts = re.findall(r"<script([^>]*)>", INDEX)
    assert scripts == [' async src="/widget.js"', ' type="application/ld+json"']
    assert not re.search(r" on[a-z]+=", INDEX)
    # every src/href that the browser fetches is same-origin (og:/twitter: images and the JSON-LD links are not fetched)
    fetched = re.findall(r'<(?:link|script|img|iframe|source)[^>]*(?:src|href)="([^"]+)"', INDEX)
    assert fetched and all(not re.match(r"https?://|//", u) for u in fetched), fetched
    assert "<iframe" not in INDEX and "<form" not in INDEX and "url(" not in INDEX
    # the widget: one outside connection, no images, no frames, no eval
    assert re.findall(r"https?://[^\s'\"]+", WIDGET) == [WEBHOOK]
    for sink in ("eval(", "new Function", "<iframe", "<img", "<form", "XMLHttpRequest", "sendBeacon", "WebSocket"):
        assert sink not in WIDGET, sink


def test_404_page_needs_nothing_beyond_the_baseline():
    assert "<script" not in NOT_FOUND and not re.search(r" on[a-z]+=", NOT_FOUND)
    fetched = re.findall(r'(?:src|href)="([^"]+)"', NOT_FOUND)
    assert all(u.startswith("/") for u in fetched), fetched
