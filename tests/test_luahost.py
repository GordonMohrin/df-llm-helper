"""tools/luahost.py: Lua 5.3 on DFHack's lua53.dll; runs every tests/lua/test_*.lua."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason=f"lua53.dll not found ({luahost.dll_path()})")


def run_src(tmp_path, src, *args, timeout=10.0, name="t.lua"):
    f = tmp_path / name
    f.write_text(src, encoding="utf-8")
    return luahost.run_file(f, list(args), timeout=timeout, paths=[LUA_TESTS])


@pytest.mark.parametrize("lua_file", sorted(LUA_TESTS.glob("test_*.lua")), ids=lambda p: p.name)
def test_lua_suite(lua_file):
    r = luahost.run_file(lua_file, timeout=60, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "not ok" not in r.out
    assert "# passed" in r.out


def test_exports_are_mangled_and_mapped():
    names = luahost.pe_exports(luahost.dll_path())
    assert any(n.startswith("?lua_pcallk@@") for n in names)
    assert luahost.demangle("?lua_settop@@YAXPEAUlua_State@@H@Z") == "lua_settop"
    assert luahost.demangle("plain") == "plain"


def test_print_args_exit_code(tmp_path):
    r = run_src(tmp_path, "print('a', 1, nil, ...) io.write('x', 2) os.exit(3)", "ä", "b c")
    assert r.code == 3
    assert r.out == "a\t1\tnil\tä\tb c\nx2"


def test_exit_true_false_and_normal_end(tmp_path):
    assert run_src(tmp_path, "os.exit(true)").code == 0
    assert run_src(tmp_path, "os.exit(false)").code == 1
    assert run_src(tmp_path, "local x = 1").code == 0


def test_runtime_error_has_traceback(tmp_path):
    r = run_src(tmp_path, "local function f() error('kaputt') end\nf()")
    assert r.code == 1
    assert "kaputt" in r.err and "traceback" in r.err


def test_syntax_error(tmp_path):
    r = run_src(tmp_path, "if then")
    assert r.code == 2
    assert "t.lua" in r.err


def test_timeout(tmp_path):
    r = run_src(tmp_path, "while true do end", timeout=0.5)
    assert r.code == luahost.TIMEOUT_EXIT
    assert "timeout" in r.err


def test_require_from_repo_lua(tmp_path):
    r = run_src(tmp_path, "local json = require('dfllm.util.json') print(json.encode({b=1,a={2}}))")
    assert r.ok, r.err
    assert r.out.strip() == '{"a":[2],"b":1}'


def test_natives(tmp_path):
    (tmp_path / "sub").mkdir()
    (tmp_path / "f.txt").write_text("x")
    p = tmp_path.as_posix()
    r = run_src(tmp_path, f"""
local l = luahost.listdir('{p}')
print(table.concat(l, ','))
print(luahost.isdir('{p}/sub'), luahost.isfile('{p}/f.txt'), luahost.isfile('{p}/nope'))
print(luahost.mkdir_recursive('{p}/a/b/c'), luahost.isdir('{p}/a/b/c'))
print(luahost.mtime('{p}/f.txt') > 0, luahost.mtime('{p}/nope'))
""")
    assert r.ok, r.err
    lines = r.out.splitlines()
    assert lines[0] == "f.txt,sub,t.lua"
    assert lines[1:] == ["true\ttrue\tfalse", "true\ttrue", "true\t-1"]


def test_lua_json_is_valid_python_json(tmp_path):
    """Lua encodes tricky values; Python's strict json must read them back exactly."""
    r = run_src(tmp_path, r"""
local json = require('dfllm.util.json')
os.setlocale('German_Germany.1252', 'numeric')
print(json.encode({s = 'Grüße "x" \\ \n\t\1 😀', bad = 'a\255b', f = 2.5, n = 1234567, neg = -3,
                   e = {}, o = json.object{}, nul = json.null, t = true}))
os.setlocale('C', 'numeric')
""")
    assert r.ok, r.err
    doc = json.loads(r.out)
    assert doc == {"s": 'Grüße "x" \\ \n\t\x01 😀', "bad": "a�b", "f": 3, "n": 1234567, "neg": -3,
                   "e": [], "o": {}, "nul": None, "t": True}


def test_python_json_decodes_in_lua(tmp_path):
    src = {"umlaut": "äöüß", "emoji": "😀", "esc": "a\"b\\c\n", "num": [1, -2, 3.5, 1e3], "nested": {"x": [None, {}]}}
    for ensure_ascii in (True, False):
        payload = json.dumps(src, ensure_ascii=ensure_ascii)
        f = tmp_path / "in.json"
        f.write_text(payload, encoding="utf-8")
        r = run_src(tmp_path, f"""
local json = require('dfllm.util.json')
local fh = io.open('{f.as_posix()}', 'rb') local s = fh:read('a') fh:close()
print(json.encode(json.decode(s)))
""")
        assert r.ok, r.err
        back = json.loads(r.out)
        assert back == {**src, "num": [1, -2, 4, 1000]}  # Lua writes integers only
