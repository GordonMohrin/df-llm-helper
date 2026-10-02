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


# ---------------------------------------------------------------- BUG-400 / BUG-401 / BUG-417 (util.emit)
def run_snippet(code, tmp_path, env=None):
    """Run a Lua snippet that can reqscript('claude/util') etc. from lua/claude."""
    f = tmp_path / "snippet.lua"
    f.write_text(code, encoding="utf-8")
    e = {"MOCK_SCRIPT_DIR": str(CLAUDE)}
    e.update(env or {})
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    r = subprocess.run([LUA, str(MOCK), str(f)], capture_output=True, timeout=10,
                       env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home), **e})
    assert r.returncode == 0, r.stderr.decode("utf-8", "replace")
    return r.stdout.decode("utf-8")


def test_mock_reproduces_the_decimal_comma_of_the_live_encoder(tmp_path):
    out = run_snippet("print(require('json').encode({ fps = 250.0 }))", tmp_path, {"MOCK_DECIMAL_COMMA": "1"})
    assert out.strip() == '{"fps":250,0}'


def test_emit_prints_floats_with_dot_under_german_locale(tmp_path):
    code = ("local util = reqscript('claude/util')\n"
            "util.emit({ fps = 250.0, g = 3.9375, list = { 1.5, 2, 0.25 }, n = 7, inf = math.huge })\n")
    out = run_snippet(code, tmp_path, {"MOCK_DECIMAL_COMMA": "1"})
    j = json.loads(out)
    assert j == {"fps": 250.0, "g": 3.9375, "list": [1.5, 2, 0.25], "n": 7, "inf": None}
    assert isinstance(j["n"], int)


def test_emit_converts_cp437_once_and_leaves_utf8_alone(tmp_path):
    # unit name as DF stores it (CP437: o-grave = 0x95) and as mil/gefahr/migranten already convert it (df2utf)
    code = ("local util = reqscript('claude/util')\n"
            "local raw = 'Rig\\149thrith \"Craftedbell\"'\n"
            "local t = { raw = raw, pre = dfhack.df2utf(raw), text = 'a\\nb\\tc' }\n"
            "util.emit(t)\n"
            "util.emit(t)\n")                       # emitting the same table twice must not convert twice
    lines = run_snippet(code, tmp_path).splitlines()
    for line in lines:
        j = json.loads(line)
        assert j["raw"] == j["pre"] == 'Rigòthrith "Craftedbell"'
        assert j["text"] == "a\nb\tc"               # BUG-417: no CP437 picture glyphs for control characters


def test_cut_never_splits_a_utf8_character(tmp_path):
    code = ("local util = reqscript('claude/util')\n"
            "local s = dfhack.df2utf('Stinth\\132d \\149nulfeb')\n"   # 'Stinthäd ònulfeb'
            "for n = 1, #s do assert(utf8.len(util.cut(s, n)), n) end\n"
            "print(util.cut(s, 7), util.cut('Stinth\\132d', 7) == 'Stinth\\132')\n")
    assert run_snippet(code, tmp_path).strip() == "Stinth\ttrue"


# ---------------------------------------------------------------- BUG-407
@pytest.mark.parametrize("script", ["essen", "arbeit", "trinken", "material", "orders", "ueberwacher"])
@pytest.mark.parametrize("word", ["foo", "--help", "stauts"])
def test_unknown_subcommand_prints_usage_and_runs_no_round(tmp_path, script, word):
    out, r = run(script, word, tmp_path=tmp_path)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert "unbekannter Befehl" in j["error"] and script in j["usage"]
    assert not list((tmp_path / "home" / "state").iterdir())          # no state written by a work round
    assert not list((tmp_path / "home" / "tools").glob("*.flag"))     # ueberwacher check() writes flags


def test_ueberwacher_status_is_a_pure_read(tmp_path):
    out, _ = run("ueberwacher", "status", tmp_path=tmp_path)
    assert one_json(out) == {"running": False}


@pytest.mark.parametrize("args", [[], ["--dry"]])
def test_erzdig_without_ore_prints_usage(tmp_path, args):
    out, _ = run("erzdig", *args, tmp_path=tmp_path)
    assert one_json(out)["error"] == "Erz fehlt"


def test_mil_update_and_refuge_need_apply(tmp_path):
    after = tmp_path / "after.lua"
    after.write_text("print('UPDATE ' .. tostring(rawget(df.global.plotinfo.equipment.update, 'weapon')))\n")
    out, _ = run("mil", "update", tmp_path=tmp_path, env={"MOCK_AFTER": str(after)})
    lines = out.splitlines()
    assert one_json(lines[0])["dry"] is True and lines[-1] == "UPDATE nil"
    out, _ = run("mil", "update", "--apply", tmp_path=tmp_path, env={"MOCK_AFTER": str(after)})
    assert out.splitlines()[-1] == "UPDATE true"
    out, _ = run("mil", "refuge", tmp_path=tmp_path)
    assert one_json(out.splitlines()[0])["dry"] is True


# ---------------------------------------------------------------- BUG-406 (classification on the Python side)
@pytest.mark.parametrize("cmd,write", [
    ("claude/trinken lager", True), ("claude/trinken status", False), ("claude/bauprog status", False),
    ("claude/raster status", False), ("claude/mil tabelle", False), ("claude/mil tabelle --file", True),
    ("claude/mil tabelle --say", True), ("claude/advance clock", False), ("claude/arbeit status", True),
    ("claude/ueberwacher status", True), ("claude/bauprog", True), ("claude/raster start", True),
])
def test_is_write_classification(cmd, write):
    from df_llm_helper.client import is_write
    assert is_write(cmd) is write


# ---------------------------------------------------------------- BUG-404 / BUG-405 (advance / timer)
SIM = """
local pending, nid = {}, 0
dfhack.timeout = function(n, unit, fn) nid = nid + 1; pending[nid] = { left = n, fn = fn }; return nid end
dfhack.timeout_active = function(id, ...) if select('#', ...) > 0 then pending[id] = nil end return pending[id] end
function SIM_FRAMES(factor, max_frames)
  for f = 1, max_frames do
    if df.global.pause_state then return f end
    df.global.cur_year_tick = df.global.cur_year_tick + factor
    local due = {}
    for id, t in pairs(pending) do
      t.left = t.left - 1
      if t.left <= 0 then pending[id] = nil; due[#due + 1] = t.fn end
    end
    for _, fn in ipairs(due) do fn() end
  end
end
"""


@pytest.mark.parametrize("factor", [1, 3, 9])
def test_timer_pauses_after_calendar_ticks_also_with_timestream(tmp_path, factor):
    code = SIM + (f"local timer = reqscript('claude/timer')\n"
                  f"local t0 = df.global.cur_year_tick\n"
                  f"df.global.pause_state = true\n"
                  f"timer.start(1200)\n"
                  f"SIM_FRAMES({factor}, 100000)\n"
                  f"print(df.global.cur_year_tick - t0, tostring(df.global.pause_state), tostring(timer.active()))\n")
    ran, paused, active = run_snippet(code, tmp_path).split()
    assert paused == "true" and active == "false"
    assert 1200 <= int(ran) < 1200 + factor


def test_advance_clock_and_errors_keep_popups(tmp_path):
    setup = ("local pops = {}\n"
             "for i = 0, 1 do pops[i] = { delete = function() end } end\n"
             "pops.n = 2\n"
             "df.global.world.status.popups = setmetatable(pops, { __len = function(t) return t.n end,\n"
             "  __index = { erase = function(t, i) t[i] = nil; t.n = t.n - 1 end } })\n"
             "df.global.pause_state = true\n")
    after = tmp_path / "after.lua"
    after.write_text("print('POPUPS ' .. #df.global.world.status.popups)\n")
    for args in (["clock"], [], ["foo"], ["0"]):
        out, r = run("advance", *args, tmp_path=tmp_path, setup=setup, env={"MOCK_AFTER": str(after)})
        assert r.returncode == 0, r.stderr
        assert out.splitlines()[-1] == "POPUPS 2", args
        assert "popups_dismissed" not in out
    out, _ = run("advance", "600", tmp_path=tmp_path, setup=setup, env={"MOCK_AFTER": str(after)})
    assert out.splitlines()[-1] == "POPUPS 0" and json.loads(out.splitlines()[0])["popups_dismissed"] == 2


# ---------------------------------------------------------------- BUG-402
@pytest.mark.parametrize("args", [["status"], []])
def test_schacht_status_without_cavern_barrier(tmp_path, args):
    out, r = run("schacht", *args, tmp_path=tmp_path)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert j["aktiv"] is False and j["kopf"] == {"state": "n/a"}


@pytest.mark.parametrize("cmd", ["open", "seal", "notzu", "bauen", "cancel"])
def test_schacht_write_commands_refuse_without_barrier(tmp_path, cmd):
    out, r = run("schacht", cmd, tmp_path=tmp_path)
    assert r.returncode == 0 and "keine Kavernen-Sperre" in one_json(out)["error"]
    assert not (tmp_path / "home" / "tools" / "schacht.offen").exists()


# ---------------------------------------------------------------- BUG-413 (pilot_batch, both copies)
@pytest.mark.parametrize("script", [ROOT / "lua" / "pilot_batch.lua", ROOT / "lua" / "claude" / "pilot_batch.lua"])
def test_pilot_batch_utf8_cut_bad_entries_and_bom(tmp_path, script):
    dmock = ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"
    req = tmp_path / "req.json"
    req.write_bytes(b"\xef\xbb\xbf" + json.dumps({"cmds": [123, ["utf8"], "claude/alert", [], ["claude/status"]],
                                                   "max_bytes": 51}).encode())
    r = subprocess.run([LUA, str(dmock), str(script), str(req)], capture_output=True, timeout=20)
    assert r.returncode == 0, r.stderr
    text = r.stdout.decode("utf-8")                        # strict: must be valid UTF-8
    out = json.loads(text.splitlines()[0])
    assert [e["ok"] for e in out] == [False, True, False, False, True]
    assert out[1]["out"].startswith("ä" * 25) and "(120 Bytes)" in out[1]["out"]
    assert out[4]["out"] == "out:claude/status"


# ---------------------------------------------------------------- BUG-409 / BUG-414 (pilot_* box handling)
GRID = ROOT / "tests" / "lua_mock" / "grid_mock.lua"


def grid_run(tmp_path, script, *args, mock=GRID):
    gp = tmp_path / "grid.json"
    gp.write_text("[]")
    r = subprocess.run([LUA, str(mock), str(ROOT / "lua" / f"{script}.lua"), *map(str, args)], capture_output=True,
                       text=True, timeout=30, env={"PATH": "/usr/bin:/bin", "MOCK_GRID": str(gp), "MOCK_MAP": "192,192,153",
                                                   "MOCK_HOME": str(tmp_path)})
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout.splitlines()[0])


@pytest.mark.parametrize("script", ["pilot_digcheck", "pilot_reach"])
@pytest.mark.parametrize("box", [(500, 500, 130, 600, 600, 130), (500, 0, 130, 600, 5, 130)])
def test_box_outside_the_map_is_an_error(tmp_path, script, box):
    j = grid_run(tmp_path, script, "dump", *box)
    assert j == {"ok": False, "error": "box outside the map"}


@pytest.mark.parametrize("script", ["pilot_digcheck", "pilot_reach"])
def test_fractional_coordinates_give_usage_not_traceback(tmp_path, script):
    j = grid_run(tmp_path, script, "dump", 1.5, 2.5, 130, 5, 5, 130)
    assert j["ok"] is False and "dump x1 y1 z1 x2 y2 z2" in j["error"]


def test_reach_check_results_aligned_with_arguments(tmp_path):
    j = grid_run(tmp_path, "pilot_reach", "check", 100, 96, 130, "101,96,130", "foo", "102,97,130+", "1.5,2,3")
    assert len(j["results"]) == len(j["via"]) == 4 and j["invalid"] == [1, 3]
    from df_llm_helper.features.reach import parse_check

    class P:
        def __init__(self, name):
            self.name = name
    pts = [P("a"), P("b"), P("c"), P("d")]
    parsed = parse_check(j, pts)
    assert parsed["b"] is None and parsed["d"] is None and parsed["a"] is not None


def test_siege_unknown_command_prints_usage(tmp_path):
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_siege.lua"), "foo"], capture_output=True, text=True,
                       timeout=30, env={"PATH": "/usr/bin:/bin", "MOCK_HOME": str(tmp_path), "MOCK_SCRIPT_DIR": str(CLAUDE)})
    assert "Usage: claude/pilot_siege" in r.stdout, r.stdout + r.stderr


@pytest.mark.parametrize("args,err", [
    (("scan", 0, 0, 0, 191, 191, 152), "box too large"),
    (("scan", 500, 500, 130, 600, 600, 130), "box outside the map"),
    (("near", 100, 96, 130, 1000), "radius 0..10"),
])
def test_pilot_water_caps(tmp_path, args, err):
    dmock = ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"
    r = subprocess.run([LUA, str(dmock), str(ROOT / "lua" / "pilot_water.lua"), *map(str, args)], capture_output=True,
                       text=True, timeout=30)
    assert err in json.loads(r.stdout.splitlines()[0])["error"]


def test_pilot_water_reversed_box_is_normalised(tmp_path):
    dmock = ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"
    tiles = tmp_path / "t.json"
    tiles.write_text(json.dumps([{"x": 85, "y": 85, "z": 130, "flow": 3}]))
    r = subprocess.run([LUA, str(dmock), str(ROOT / "lua" / "pilot_water.lua"), "scan", "90", "90", "130", "80", "80", "130"],
                       capture_output=True, text=True, timeout=30, env={"PATH": "/usr/bin:/bin", "MOCK_TILES": str(tiles)})
    assert json.loads(r.stdout.splitlines()[0])["water"] == 1
