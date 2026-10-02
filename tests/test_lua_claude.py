"""Mock tests of the companion scripts lua/claude/*.lua (tests/lua_mock/claude_mock.lua, needs lua5.4)."""
import json
import shutil
import subprocess

import pytest

from helpers import ROOT

LUA = shutil.which("lua5.4")
MOCK = ROOT / "tests" / "lua_mock" / "claude_mock.lua"
CLAUDE = ROOT / "lua" / "claude"

pytestmark = pytest.mark.skipif(not LUA or not CLAUDE.is_dir(), reason="lua5.4 or lua/claude missing")


def run(script, *args, tmp_path, setup="", env=None, timeout=10):
    """Run lua/claude/<script>.lua under the mock; returns (stdout, CompletedProcess)."""
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    (home / "state").mkdir(exist_ok=True)
    e = {"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home), "MOCK_HOME": str(home)}
    if setup:
        sf = tmp_path / "setup.lua"
        sf.write_text(setup, encoding="utf-8")
        e["MOCK_SETUP"] = str(sf)
    e.update(env or {})
    r = subprocess.run([LUA, str(MOCK), str(CLAUDE / f"{script}.lua"), *map(str, args)], capture_output=True,
                       timeout=timeout, env=e)
    return r.stdout.decode("utf-8"), r


def one_json(out):
    return json.loads(out)


# ---------------------------------------------------------------- BUG-403
def test_handel_scan_empty_needle_returns_usage_and_does_not_hang(tmp_path):
    for needle in ("", "   "):
        out, r = run("handel", "scan", needle, tmp_path=tmp_path, timeout=5)
        assert r.returncode == 0
        assert one_json(out) == {"abort": "scan <text>", "ok": False}


def test_handel_scan_finds_all_occurrences(tmp_path):
    out, _ = run("handel", "scan", "ABC", tmp_path=tmp_path, setup="MOCK_SCREEN = { 'abc def abc', 'xx' }")
    j = one_json(out)
    assert j["ok"] and [(h["x"], h["y"]) for h in j["hits"]] == [(0, 0), (8, 0)]
