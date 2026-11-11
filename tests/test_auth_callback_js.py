"""ROADMAP #21 points 5-8: runs the node:test unit tests of docs/auth-callback.js (skipped without node)."""
import shutil
import subprocess
from pathlib import Path

import pytest

TESTS = Path(__file__).parent / "auth_callback" / "parse.test.cjs"


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_auth_callback_js_unit():
    proc = subprocess.run(
        ["node", "--test", str(TESTS)], capture_output=True, text=True, timeout=60
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
