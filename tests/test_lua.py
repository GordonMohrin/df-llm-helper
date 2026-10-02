"""SPEC 8.3: Lua structure check and mock-DFHack test of the new Lua scripts."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from helpers import ROOT

sys.path.insert(0, str(ROOT / "tools"))
from luacheck_min import check_file, check_source, main as luacheck_main  # noqa: E402

NEW_LUA = sorted((ROOT / "lua").glob("*.lua"))
OLD_LUA = sorted((ROOT / "lua" / "claude").glob("*.lua"))
LUA = shutil.which("lua5.4") or shutil.which("lua")


def test_new_lua_files_pass_structure_check():
    assert NEW_LUA
    for f in NEW_LUA:
        assert check_file(f) == [], f


@pytest.mark.skipif(not OLD_LUA, reason="companion scripts lua/claude/ not next to df-llm-helper (public version)")
def test_existing_lua_runs_through_without_crash():
    for f in OLD_LUA:
        assert isinstance(check_file(f), list)


@pytest.mark.parametrize("src,needle", [
    ("local function f()\n  if x then\n  end\n", "'function' not closed"),
    ("end\n", "'end' without an open block"),
    ("local t = { 1, 2 ]\n", "unexpected ']'"),
    ("print('open\n", "string without end"),
    ("--[[ open\n", "block comment without end"),
    ("until x\n", "'until' without 'repeat'"),
    ("dfhack.run_command('createitem', 'x')\n", "createitem"),
    ("it.flags.foreign = false\n", "foreign"),
    ("local s = [[ open\n", "long string without end"),
])
def test_structure_check_finds_errors(src, needle):
    assert any(needle in f for f in check_source(src))


@pytest.mark.parametrize("src", [
    "local x = 'end' -- end\nlocal y = [[ function ]]\n",
    "for i = 1, 3 do\n  while true do break end\nend\n",
    "repeat local a = 1 until a\n",
    "do local x = 1 end\nlocal f = function() return {a = (1)} end\n",
    "if a then elseif b then else end\n",
    "--[==[ lang\n comment ]==]\nprint(\"a\\\"b\")\n",
])
def test_structure_check_accepts_valid(src):
    assert check_source(src) == []


def test_luacheck_main(capsys, tmp_path):
    good = tmp_path / "g.lua"
    good.write_text("print(1)\n")
    bad = tmp_path / "b.lua"
    bad.write_text("if x then\n")
    assert luacheck_main([str(good)]) == 0
    assert luacheck_main([str(good), str(bad)]) == 1
    assert "1 with findings" in capsys.readouterr().out


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_luac_agrees_on_new_files():
    luac = shutil.which("luac5.4")
    if not luac:
        pytest.skip("luac5.4 missing")
    for f in NEW_LUA:
        assert subprocess.run([luac, "-p", str(f)], capture_output=True).returncode == 0


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
@pytest.mark.parametrize("args,expect,state", [
    (["mode", "Stonecutters", "OnlySelectedDoesThis", "--apply"], {"applied": True, "before": "EverybodyDoesThis"},
     "OnlySelectedDoesThis"),
    (["mode", "Stonecutters", "OnlySelectedDoesThis"], {"dry": True}, "EverybodyDoesThis"),
    (["mode", "Foo", "OnlySelectedDoesThis", "--apply"], {"error": 'no work detail "Foo"'}, "EverybodyDoesThis"),
    (["mode", "Stonecutters", "Nonsense"], None, "EverybodyDoesThis"),
])
def test_pilot_wd_with_mock_dfhack(args, expect, state):
    r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"), str(ROOT / "lua" / "pilot_wd.lua"),
                        *args], capture_output=True, text=True, timeout=20)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.strip().splitlines()
    out = json.loads(lines[0])
    if expect is None:
        assert "error" in out
    else:
        for k, v in expect.items():
            assert out[k] == v
    assert json.loads(lines[-1].removeprefix("STATE "))["Stonecutters"] == state
