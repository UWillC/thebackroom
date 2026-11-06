"""
Web interface on Cloudflare Pages (2026-11-05): static checks of docs/app, the /app CSP and the mail-link migration.
Browser behaviour (XSS with hostile data, fragment link, production read-only run): tests/e2e_app/run_e2e.mjs.
SQL behaviour on postgres:17: sql/tests/run_mail_links_local.sh.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "docs/app"
JS = (APP / "app.js").read_text(encoding="utf-8")
HTML = (APP / "index.html").read_text(encoding="utf-8")
HEADERS = (ROOT / "docs/_headers").read_text(encoding="utf-8")
SEC = ROOT / "sql/security_fixes"
MIG = (SEC / "2026-11-05_mail_links_to_pages.sql").read_text(encoding="utf-8")
RB = (SEC / "2026-11-05_mail_links_to_pages_rollback.sql").read_text(encoding="utf-8")
VER = (SEC / "2026-11-05_mail_links_to_pages_verify_after_apply.sql").read_text(encoding="utf-8")
RUNNER = (ROOT / "sql/tests/run_mail_links_local.sh").read_text(encoding="utf-8")
SUPABASE = "https://ifofgblilanwjhypzvdb.supabase.co"
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self'; "
       f"connect-src {SUPABASE}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")


def _code(src):
    return "\n".join(l for l in src.splitlines() if not l.strip().startswith("//"))


def test_js_never_writes_html():
    code = _code(JS)
    for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function",
                 ".href", ".src", "srcdoc", "DOMParser", "createContextualFragment"):
        assert sink not in code, sink
    assert re.findall(r"setAttribute\(([^,]+),", code) == ["'aria-selected'"]


def test_js_talks_only_to_supabase_with_the_publishable_key():
    assert f"const SUPABASE_URL = '{SUPABASE}';" in JS
    assert re.findall(r"https?://[^\s'\"]+", _code(JS)) == [SUPABASE]
    assert "sb_publishable_" in JS and "sb_secret_" not in JS and "service_role" not in JS
    assert "credentials: 'omit'" in JS


def test_js_reads_the_same_profile_columns_as_app_py():
    app_py = (ROOT / "app.py").read_text(encoding="utf-8")
    py_cols = "".join(re.findall(r'"([^"]*)"', app_py.split("PUBLIC_PROFILE_COLUMNS = (", 1)[1].split(")", 1)[0]))
    js_cols = "".join(re.findall(r"'([^']*)'", JS.split("const PUBLIC_PROFILE_COLUMNS =", 1)[1].split(";", 1)[0]))
    assert py_cols == js_cols and "email," not in js_cols.replace("email_verified", "").replace("email_verification_sent_at", "")


def test_fragment_link_is_cleared_and_never_auto_verifies():
    assert "history.replaceState(null, '', window.location.pathname + window.location.search)" in JS
    init = JS.split("const frag = parseFragment(window.location.hash);", 1)[1]
    assert "verifyEmail(" not in init.split("if (document.readyState", 1)[0]


def test_html_has_no_inline_script_style_or_third_party():
    assert "<style" not in HTML and " style=" not in HTML
    assert re.findall(r"<script[^>]*>", HTML) == ['<script defer src="/app/app.js">']
    assert not re.search(r" on[a-z]+=", HTML)
    externals = re.findall(r'(?:src|href)="(https?://[^"]+)"', HTML)
    assert externals == ["https://github.com/UWillC/thebackroom"]


def test_app_csp_in_headers_for_both_paths():
    for path in ("/app", "/app/*"):
        block = HEADERS.split("\n" + path + "\n", 1)[1].split("\n\n", 1)[0]
        assert f"Content-Security-Policy: {CSP}" in block, path
        assert "Referrer-Policy: no-referrer" in block and "X-Content-Type-Options: nosniff" in block
    assert "unsafe-inline" not in HEADERS.split("\n/app\n", 1)[1]


def test_no_space_link_left_in_published_files():
    for f in ("index.html", "llms.txt", "QUICKSTART.md", "QUICKSTART-EN.md"):
        assert "huggingface" not in (ROOT / "docs" / f).read_text(encoding="utf-8"), f
    assert not list((ROOT / "docs").glob(".wrangler"))
    assert ".wrangler/" in (ROOT / ".gitignore").read_text(encoding="utf-8")


def _rows(src):
    return re.findall(r"\('([a-z_]+\([a-z]*\))',\s+'([0-9a-f]{32})', (\d), (\d), '([0-9a-f]{32})'\)", src)


def test_migration_is_a_guarded_transaction_and_md5s_line_up():
    for src in (MIG, RB):
        lines = [l.strip() for l in src.splitlines() if l.strip() and not l.strip().startswith("--")]
        assert lines[0] == "BEGIN;" and lines[-1] == "COMMIT;"
        assert src.count("RAISE EXCEPTION") >= 3
    mig, rb = _rows(MIG), _rows(RB)
    assert len(mig) == 9 and len(rb) == 9
    # rollback = the migration reversed
    assert {(s, a, v, h, b) for s, b, v, h, a in mig} == set(rb)
    # verify file expects the migration's output; the local runner starts from the migration's input
    for sig, before, _, _, after in mig:
        name = sig.split("(")[0]
        assert f"('{name}', '{after}'," in VER, name
        assert f"{name}|{before}" in RUNNER, name
    assert sum(int(v) for _, _, v, _, _ in mig) == 2 and sum(int(h) for _, _, _, h, _ in mig) == 7


def test_migration_only_swaps_two_literals():
    assert "'https://huggingface.co/spaces/UWillC/thebackroom?verify='" in MIG
    assert "'https://www.thebackroom.ai/app/#verify='" in MIG
    assert """'href="https://huggingface.co/spaces/UWillC/thebackroom"'""" in MIG
    assert """'href="https://www.thebackroom.ai/app/"'""" in MIG
    code = "\n".join(l for l in MIG.splitlines() if not l.strip().startswith("--"))
    assert "GRANT" not in code and "REVOKE" not in code and "DROP" not in code and "ALTER" not in code
    assert "EXECUTE new_def;" in code


def test_privacy_policy_names_the_new_interface_and_not_hugging_face():
    policy = (ROOT / "docs/privacy.html").read_text(encoding="utf-8")
    # Hugging Face only in the transitional paragraph (@ciso W5), which goes when the Space is deleted
    hf = [p for p in policy.split("<p>") if "hugging" in p.lower()]
    assert len(hf) == 1 and hf[0].startswith("Until November 8, 2026, links in e-mails we sent before November 6, 2026")
    assert "VERIFY" not in policy
    assert "use our web interface at www.thebackroom.ai/app" in policy
    assert "<h3>Web interface</h3>" in policy and 'after a "#" sign' in policy
    assert "Hosts this website, including our web interface," in policy
