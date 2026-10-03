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


# ---------------------------------------------------------------- BUG-413 (pilot_batch; one copy since BUG-420)
@pytest.mark.parametrize("script", [ROOT / "lua" / "pilot_batch.lua"])
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


# ---------------------------------------------------------------- BUG-415 (whole-map scanners: time budget)
CLOCK = """
local t = 0
dfhack.getTickCount = function() t = t + 600; return t end     -- every clock read = 600 ms later
dfhack.maps.getTileSize = function() return 32, 32, 10 end
dfhack.maps.getBlock = function(bx, by, bz) return { block_events = {}, map_pos = { x = bx * 16, y = by * 16, z = bz } } end
"""


def test_ores_stops_after_budget_and_says_how_to_continue(tmp_path):
    out, r = run("ores", tmp_path=tmp_path, setup=CLOCK)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert j["unvollstaendig"] is True and j["weiter"].startswith("claude/ores 0 ")
    lo, hi = j["z_bereich"]
    assert hi == 9 and 0 < lo <= 9 and j["weiter"] == f"claude/ores 0 {lo - 1}"


def test_ores_small_range_completes(tmp_path):
    out, _ = run("ores", 3, 4, "--budget", 100000, tmp_path=tmp_path, setup=CLOCK)
    j = one_json(out)
    assert "unvollstaendig" not in j and j["z_bereich"] == [3, 4]


def test_is_write_treats_whole_map_scanners_as_heavy():
    from df_llm_helper.client import is_write
    for c in ("claude/ores", "claude/geo", "claude/zugaenge", "claude/kohle run 10", "claude/erzdig ALL 104 132 60 --dry",
              "claude/pilot_perimeter scan 100 101 130 100 140"):
        assert is_write(c) is True, c


# ---------------------------------------------------------------- BUG-411 (laeuft/running booleans)
def test_kohle_and_raster_report_laeuft_false_when_not_scheduled(tmp_path):
    out, _ = run("kohle", "status", tmp_path=tmp_path)
    assert one_json(out) == {"laeuft": False}
    out, _ = run("raster", "status", tmp_path=tmp_path,
                 setup="dfhack.maps.getTileSize = function() return 32, 32, 10 end")
    assert one_json(out)["laeuft"] is False


# ---------------------------------------------------------------- BUG-408 / BUG-410 (area, felder, muell)
AREA = ("dfhack.maps.getTileSize = function() return 192, 192, 153 end\n"
        "dfhack.units.getCitizens = function() return {} end\n")


def test_area_x_without_y_prints_usage(tmp_path):
    out, r = run("area", 130, 80, tmp_path=tmp_path, setup=AREA)
    assert r.returncode == 0, r.stderr
    assert out.startswith("Aufruf: claude/area")


@pytest.mark.parametrize("w,h", [(0, 0), (-5, -5)])
def test_area_size_at_least_one(tmp_path, w, h):
    out, r = run("area", 130, 80, 90, w, h, tmp_path=tmp_path, setup=AREA)
    assert r.returncode == 0, r.stderr
    assert out.splitlines()[0].startswith("z=130  x=80..80  y=90..90")


@pytest.mark.parametrize("script,args", [("felder", ["foo"]), ("felder", ["set"]), ("muell", ["foo"])])
def test_felder_muell_errors_are_json(tmp_path, script, args):
    out, r = run(script, *args, tmp_path=tmp_path)
    assert r.returncode == 0 and "error" in one_json(out)


# ---------------------------------------------------------------- BUG-412 (+ BUG-400 end to end on gefahr status)
def test_gefahr_status_selftest_sees_a_stopped_scan_and_fps_is_valid_json(tmp_path):
    out, r = run("gefahr", "status", tmp_path=tmp_path, setup="df.global.enabler.fps = 250.0",
                 env={"MOCK_DECIMAL_COMMA": "1"})
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert j["fps"] == 250.0
    assert any(p.startswith("ALARMSYSTEM") for p in j["selbsttest"])


@pytest.mark.parametrize("args", [["sim", 99999, 1, 1, 1], ["fire"], ["firetest", 5]])
def test_gefahr_sim_fire_check_unit_and_arguments(tmp_path, args):
    out, r = run("gefahr", *args, tmp_path=tmp_path)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert "error" in j and "aktionen" not in j
    assert not list((tmp_path / "home" / "tools").glob("*.flag"))


# ---------------------------------------------------------------- BUG-416 (config aquifer, log rotation, positions)
def test_append_log_rotates(tmp_path):
    log = tmp_path / "x.log"
    code = (f"local util = reqscript('claude/util')\n"
            f"for i = 1, 30 do util.append_log('{log}', string.rep('a', 9), 50) end\n")
    run_snippet(code, tmp_path)
    assert log.stat().st_size <= 60 and (tmp_path / "x.log.1").exists()


def test_config_aquifer_box_argument_is_used(tmp_path):
    setup = ("dfhack.maps.getTileSize = function() return 192, 192, 153 end\n"
             "local function blk(z)\n"
             "  local des = {}\n"
             "  for i = 0, 15 do des[i] = {} for j = 0, 15 do des[i][j] = { hidden = false, water_table = (z == 120) } end end\n"
             "  return { designation = des }\n"
             "end\n"
             "dfhack.maps.getBlock = function(bx, by, z) return blk(z) end\n")
    out, r = run("config", "aquifer", 0, 0, 15, 15, 118, 121, tmp_path=tmp_path, setup=setup)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert j["box"] == [0, 0, 15, 15, 118, 121] and j["aquifer_gesehen_z"] == ["120=256"]
    out, _ = run("config", "aquifer", 1, 2, tmp_path=tmp_path, setup=setup)
    assert "usage" in one_json(out)["error"]



# ---------------------------------------------------------------- BUG-418 (lint de-duplication)
def test_lint_paths_reports_nested_dirs_once():
    from df_llm_helper.lint import lint_paths
    once = lint_paths([ROOT / "lua"])
    twice = lint_paths([ROOT / "lua" / "claude", ROOT / "lua"])
    assert sorted(map(str, once)) == sorted(map(str, twice))
    assert not any(f.file.endswith("bauprog.lua") for f in once)


# ---------------------------------------------------------------- BUG-419 (map-specific values from config)
def test_bauprog_has_no_run3_phases_by_default(tmp_path):
    out, r = run("bauprog", "status", tmp_path=tmp_path, setup="dfhack.maps.getTileSize = function() return 32, 32, 10 end")
    assert r.returncode == 0, r.stderr
    assert one_json(out)["phasen"] == []


def test_geo_without_known_geo_index_errors(tmp_path):
    out, _ = run("geo", tmp_path=tmp_path, setup="dfhack.maps.getTileSize = function() return 32, 32, 10 end")
    assert "geo_index" in one_json(out)["error"]


def test_no_run3_coordinates_left_in_scripts():
    import re
    pats = {"muell.lua": r"z <= 131 and x >= 40", "kohle.lua": r"x - 99\)", "sperre.lua": r"\{ 136, 169",
            "zugaenge.lua": r"ZMIN, ZMAX = 100, 136|CORE=\{100,101,130\}", "geo.lua": r"or 110\b|or 97\b"}
    for name, pat in pats.items():
        assert not re.search(pat, (CLAUDE / name).read_text(encoding="utf-8")), name


# ---------------------------------------------------------------- pilot_perimeter enclave filter (threshold from config)
def test_perimeter_enclave_filter_threshold_from_config(tmp_path):
    from df_llm_helper.features._grid import Grid
    g = Grid.from_file(ROOT / "fixtures" / "v3" / "grid" / "perimeter_j109_open.grid")
    gp = tmp_path / "grid.json"
    gp.write_text(json.dumps(g.to_mock()))
    (tmp_path / "tools" / "out").mkdir(parents=True)

    def entries(mincomp):
        r = subprocess.run([LUA, str(GRID), str(ROOT / "lua" / "pilot_perimeter.lua"), "scan", "100", "101", "130", "100",
                            "136"], capture_output=True, text=True, timeout=120,
                           env={"PATH": "/usr/bin:/bin", "MOCK_GRID": str(gp), "MOCK_HOME": str(tmp_path),
                                "MOCK_MAP": "130,110,140", "MOCK_MINCOMP": str(mincomp)})
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout.splitlines()[0])["entries"]
    assert entries(1)                      # no filter: the openings of the fixture are found
    assert entries(100000) == []           # every outside area of the small fixture counts as an enclave


# ---------------------------------------------------------------- tile map mock (dig, erzdig spur, zugaenge)
# SHAPE/HIDDEN/OUTSIDE/GROUP keyed 'x,y,z'; tiletype values ARE the shape names; READS records tiletype reads of hidden tiles.
MAP = """
MAP_W, MAP_H, MAP_ZMIN, MAP_ZMAX = MAP_W or 32, MAP_H or 32, MAP_ZMIN or 0, MAP_ZMAX or 9
SHAPE, HIDDEN, OUTSIDE, GROUP, READS, EVENTS = SHAPE or {}, HIDDEN or {}, OUTSIDE or {}, GROUP or {}, {}, EVENTS or {}
local function K(x, y, z) return x .. ',' .. y .. ',' .. z end
dfhack.maps.getTileSize = function() return MAP_W, MAP_H, MAP_ZMAX + 1 end
df.global.world.map.x_count, df.global.world.map.y_count, df.global.world.map.z_count = MAP_W, MAP_H, MAP_ZMAX + 1
df.tile_dig_designation = { No = 0, Default = 1, UpDownStair = 2, Channel = 3, Ramp = 4, UpStair = 5, DownStair = 6 }
df.tiletype = { attrs = setmetatable({}, { __index = function(_, k) return { shape = k, material = 'STONE' } end }) }
df.tiletype_shape = setmetatable({}, { __index = function(_, k) return k end })
df.tiletype_material = setmetatable({}, { __index = function(_, k) return k end })
local blocks = {}
function MOCK_BLOCK(bx, by, z)
  if bx < 0 or by < 0 or bx * 16 >= MAP_W or by * 16 >= MAP_H or z < MAP_ZMIN or z > MAP_ZMAX then return nil end
  local k = K(bx, by, z)
  if blocks[k] then return blocks[k] end
  local b = { map_pos = { x = bx * 16, y = by * 16, z = z }, flags = {}, block_events = EVENTS[k] or {}, designation = {}, tiletype = {} }
  for i = 0, 15 do
    b.designation[i] = {}
    b.tiletype[i] = setmetatable({}, { __index = function(_, j)
      local t = K(bx * 16 + i, by * 16 + j, z)
      if HIDDEN[t] then READS[#READS + 1] = t end
      return SHAPE[t] or 'WALL'
    end })
    for j = 0, 15 do
      local t = K(bx * 16 + i, by * 16 + j, z)
      b.designation[i][j] = { dig = 0, hidden = HIDDEN[t] or false, water_table = false, outside = OUTSIDE[t] or false, flow_size = 0 }
    end
  end
  blocks[k] = b
  return b
end
dfhack.maps.getBlock = MOCK_BLOCK
dfhack.maps.getTileBlock = function(x, y, z)
  if x < 0 or y < 0 or x >= MAP_W or y >= MAP_H then return nil end
  return MOCK_BLOCK(x // 16, y // 16, z)
end
dfhack.maps.getTileType = function(x, y, z)
  local b = dfhack.maps.getTileBlock(x, y, z)
  return b and b.tiletype[x % 16][y % 16]
end
dfhack.maps.getWalkableGroup = function(p)
  local t = K(p.x, p.y, p.z)
  if GROUP[t] then return GROUP[t] end
  return (not HIDDEN[t] and SHAPE[t] == 'FLOOR') and 1 or 0
end
function DIG_AT(x, y, z) return dfhack.maps.getTileBlock(x, y, z).designation[x % 16][y % 16].dig end
"""


def map_setup(pre="", post=""):
    """pre: globals before the map mock (SHAPE/HIDDEN/...), post: Lua after it (config overrides etc.)."""
    return pre + "\n" + MAP + "\n" + post


# ---------------------------------------------------------------- BUG-418 (claude/dig: undiscovered tiles blind)
def test_dig_designates_hidden_tiles_blindly_without_reading_their_shape(tmp_path):
    pre = ("SHAPE = { ['1,0,5'] = 'EMPTY', ['3,0,5'] = 'EMPTY' }\n"
           "HIDDEN = { ['2,0,5'] = true, ['3,0,5'] = true }\n")      # 2 = hidden wall, 3 = hidden open tile
    after = tmp_path / "after.lua"
    after.write_text("print(DIG_AT(0,0,5), DIG_AT(1,0,5), DIG_AT(2,0,5), DIG_AT(3,0,5), #READS)\n")
    out, r = run("dig", 5, 0, 0, 3, 0, tmp_path=tmp_path, setup=map_setup(pre), env={"MOCK_AFTER": str(after)})
    assert r.returncode == 0, r.stderr
    lines = out.splitlines()
    j = json.loads(lines[0])
    assert (j["gesetzt"], j["uebersprungen"], j["blind"]) == (3, 1, 2)
    # revealed wall designated, revealed open tile skipped, hidden wall and hidden open tile treated the same;
    # no tiletype read of a hidden tile at all
    assert lines[1].split() == ["1", "0", "1", "1", "0"]


def test_dig_header_documents_blind_designation():
    head = (CLAUDE / "dig.lua").read_text(encoding="utf-8").split("local util")[0]
    assert "blindly" in head and "open decision" not in head


# ---------------------------------------------------------------- BUG-407 (no argument = one round, documented)
@pytest.mark.parametrize("script", ["essen", "arbeit", "trinken", "material", "orders", "ueberwacher"])
def test_round_scripts_document_the_no_argument_default(script):
    head = (CLAUDE / f"{script}.lua").read_text(encoding="utf-8").split("local util")[0]
    assert "No argument" in head and "ONE" in head


# ---------------------------------------------------------------- BUG-416 (metrics.csv at most once per game day)
def test_daily_row_is_written_once_per_game_date(tmp_path):
    csv = tmp_path / "metrics.csv"
    code = (f"local util = reqscript('claude/util')\n"
            f"local p = '{csv}'\n"
            f"print(util.append_daily_row(p, 'echtzeit;spieldatum;a', table.pack('t1', '1. Granite, Jahr 118', 5)))\n"
            f"print(util.append_daily_row(p, 'echtzeit;spieldatum;a', table.pack('t2', '1. Granite, Jahr 118', 6)))\n"
            f"print(util.append_daily_row(p, 'echtzeit;spieldatum;a', table.pack('t3', '2. Granite, Jahr 118', nil)))\n")
    assert run_snippet(code, tmp_path).split() == ["true", "false", "true"]
    assert csv.read_text().splitlines() == ["echtzeit;spieldatum;a", "t1;1. Granite, Jahr 118;5", "t3;2. Granite, Jahr 118;"]


def test_report_uses_the_daily_row():
    src = (CLAUDE / "report.lua").read_text(encoding="utf-8")
    assert "append_daily_row" in src and "io.open(path, 'a')" not in src
    assert "ONCE PER IN-GAME DAY" in src.split("local util")[0]


# ---------------------------------------------------------------- BUG-420 (live-only features ported, duplicates removed)
@pytest.mark.parametrize("script", ["muell", "kohle", "bauprog", "geo", "zugaenge", "schacht"])
def test_optional_scripts_say_what_they_need(script):
    """BUG-419: the optional map scripts stay; each header names its purpose and config keys."""
    text = (CLAUDE / f"{script}.lua").read_text(encoding="utf-8")
    assert "Used for:" in text and "config keys" in text


def test_pilot_duplicates_removed_from_lua_claude():
    assert not list(CLAUDE.glob("pilot_*.lua"))
    assert (ROOT / "lua" / "pilot_batch.lua").exists() and (ROOT / "lua" / "pilot_wd.lua").exists()


MIL = """
df.global.plotinfo.group_id = 7
local function vec()
  return setmetatable({ n = 0 }, { __len = function(t) return t.n end, __index = {
    erase = function(t, i) for k = i, t.n - 2 do t[k] = t[k + 1] end t[t.n - 1] = nil t.n = t.n - 1 end,
    insert = function(t, _, x) t[t.n] = x t.n = t.n + 1 end } })
end
SQ = { id = 3, entity_id = 7, ammo = { ammunition = vec(), update = {} } }
SQ.ammo.ammunition:insert('#', { amount = 5, flags = {}, delete = function() DELETED = true end })
df.squad.find = function(id) if id == 3 then return SQ end end
df.squad_ammo_spec = { new = function() return { flags = {} } end }
df.item_type.AMMO = 'AMMO'
"""


def test_mil_ammo_dry_and_apply(tmp_path):
    after = tmp_path / "after.lua"
    after.write_text("local a = SQ.ammo.ammunition print(#a, a[0].amount, a[0].item_subtype, a[0].flags.use_training,"
                     " tostring(df.global.plotinfo.equipment.update.quiver == true), tostring(DELETED))\n")
    out, r = run("mil", "ammo", 3, 40, tmp_path=tmp_path, setup=MIL, env={"MOCK_AFTER": str(after)})
    assert r.returncode == 0, r.stderr
    lines = out.splitlines()
    assert json.loads(lines[0]) == {"squad": 3, "amount": 40, "subtype": 0, "vorhanden": 1, "dry": True}
    assert lines[1].split() == ["1", "5", "nil", "nil", "false", "nil"]          # dry run: nothing changed
    out, r = run("mil", "ammo", 3, 40, 2, "--apply", tmp_path=tmp_path, setup=MIL, env={"MOCK_AFTER": str(after)})
    lines = out.splitlines()
    assert json.loads(lines[0])["applied"] is True
    assert lines[1].split() == ["1", "40", "2", "true", "true", "true"]
    out, _ = run("mil", "ammo", 99, tmp_path=tmp_path, setup=MIL)
    assert "usage: ammo" in one_json(out)["error"]


def test_handel_keep_checker_holds_back_the_reserve(tmp_path):
    code = ("df.global.world.items.other.WEAPON = { { flags = {} }, { flags = {} }, { flags = { trader = true } } }\n"
            "local h = reqscript('claude/handel')\n"
            "local ok = h.keep_checker({ keep = { WEAPON = 1 } })\n"
            "print(ok({ type = 'WEAPON' }), ok({ type = 'WEAPON' }), ok({ type = 'ARMOR' }))\n")
    assert run_snippet(code, tmp_path).split() == ["true", "false", "true"]


ORE = """
-- corridor y=5 (x 2..10) reachable; HEMATITE tile at (6,8): two walls (y 6/7) between -> 3-tile tunnel
SHAPE = {}
for x = 2, 10 do SHAPE[x .. ',5,5'] = 'FLOOR' end
local bits = {}
for i = 0, 15 do bits[i] = 0 end
bits[8] = 1 << 6
EVENTS = { ['0,0,5'] = { { _mineral = true, inorganic_mat = 1, tile_bitmask = { bits = bits } } } }
df.block_square_event_mineralst = { is_instance = function(_, e) return e._mineral end }
df.inorganic_raw.find = function() return { id = 'HEMATITE', material = { flags = {} }, metal_ore = { mat_index = { 1 } } } end
"""
ORE_CFG = """
local c = reqscript('claude/config')
c.FORT_REFS = { { 2, 5, 5 } }
c.DIG_MIN_Z = 0
c.SURFACE_Z = 9
"""


@pytest.mark.parametrize("hidden,tiles", [("", 3), ("HIDDEN = {} for x = 0, 15 do HIDDEN[x .. ',6,5'] = true end", 0)])
def test_erzdig_spur_designates_a_short_tunnel_over_discovered_walls(tmp_path, hidden, tiles):
    after = tmp_path / "after.lua"
    after.write_text("local n = 0 for x = 0, 15 do for y = 0, 15 do if DIG_AT(x, y, 5) ~= 0 then n = n + 1 end end end print(n)\n")
    for dry, expect in (("--dry", 0), (None, tiles)):
        args = ["spur", "HEMATITE", 5, 5, 100] + ([dry] if dry else [])
        out, r = run("erzdig", *args, tmp_path=tmp_path, setup=map_setup(ORE + hidden, ORE_CFG),
                     env={"MOCK_AFTER": str(after)})
        assert r.returncode == 0, r.stderr
        lines = out.splitlines()
        j = json.loads(lines[0])
        assert j["tiles"] == tiles and j["plaene"] == (1 if tiles else 0)
        assert int(lines[1]) == expect                          # --dry designates nothing


MUELL = """
df.building_type = { Civzone = 1, Stockpile = 2 }
df.civzone_type = { [5] = 'Dump' }
df.global.world.buildings.all = { { type = 5, x1 = 10, x2 = 12, y1 = 10, y2 = 12, z = 5, getType = function() return 1 end } }
df.item_type = setmetatable({}, { __index = function(_, k) return k end })
df.global.plotinfo.race_id = 1
local function item(t, x, y, race) return { flags = { on_ground = true }, pos = { x = x, y = y, z = 5 }, race = race,
                                            getType = function() return t end } end
ITEMS = { item('CORPSE', 11, 11, 2), item('CORPSE', 15, 15, 2), item('CORPSE', 13, 13, 2), item('CORPSE', 25, 25, 2),
          item('CORPSE', 14, 14, 1), item('BOULDER', 3, 3) }
df.global.world.items.all = ITEMS
dfhack.items.getPosition = function(it) return it.pos.x, it.pos.y, it.pos.z end
dfhack.maps.getWalkableGroup = function(p) return p.x < 20 and 1 or 2 end
"""


def test_muell_status_counts_dump_zone_items_separately(tmp_path):
    out, r = run("muell", "status", tmp_path=tmp_path, setup=MUELL)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    assert (j["lose_stapel"], j["auf_stapelpunkt_entsorgt"], j["dump_zonen"]) == (5, 1, 1)


def test_muell_dump_marks_nearest_reachable_corpses_only(tmp_path):
    after = tmp_path / "after.lua"
    after.write_text("local s = {} for i, it in ipairs(ITEMS) do s[#s + 1] = tostring(it.flags.dump == true) end print(table.concat(s, ' '))\n")
    out, r = run("muell", "dump", 1, tmp_path=tmp_path, setup=MUELL, env={"MOCK_AFTER": str(after)})
    assert r.returncode == 0, r.stderr
    lines = out.splitlines()
    j = json.loads(lines[0])
    assert j["marked"] == 1 and j["kandidaten_erreichbar"] == 2 and j["naechster_rest_dist"] == 8
    assert j["uebersprungen"] == {"dwarf": 1, "unreachable": 1}
    # only the corpse at 13,13 (nearest, reachable); not the one already on the dump, not the dwarf, not the unreachable one
    assert lines[1].split() == ["false", "false", "true", "false", "false", "false"]


ZUG = """
MAP_W, MAP_H, MAP_ZMIN, MAP_ZMAX = 10, 10, 0, 0
SHAPE, OUTSIDE = {}, {}
for x = 0, 9 do for y = 0, 9 do SHAPE[x .. ',' .. y .. ',0'] = 'FLOOR' OUTSIDE[x .. ',' .. y .. ',0'] = x <= 3 end end
"""


@pytest.mark.parametrize("mincomp,clusters", [(40, 1), (41, 0)])
def test_zugaenge_enclave_filter_reads_perimeter_mincomp(tmp_path, mincomp, clusters):
    post = f"reqscript('claude/config').PERIMETER_MINCOMP = {mincomp}\n"
    out, r = run("zugaenge", 9, 9, 0, 0, 0, tmp_path=tmp_path, setup=map_setup(ZUG, post))
    assert r.returncode == 0, r.stderr
    assert f"Einstiegscluster gesamt\t{clusters}" in out      # 40 outside tiles: an enclave only below the threshold


# ---------------------------------------------------------------- BUG-422 item 4 (answer sizes: compact default, --full)
GESUND = """
local function cit(id, stress)
  return { id = id, status = { current_soul = { personality = { stress = stress, longterm_stress = 0, emotions = {}, needs = {} } },
           labors = {} }, job = {}, counters2 = { sleepiness_timer = 0 } }
end
CITS = {}
for i = 1, 20 do CITS[i] = cit(i, i * 5000) end          -- stress 5000 .. 100000; LOW = 45000 -> ids 9..20
dfhack.units.getCitizens = function() return CITS end
dfhack.units.isAlive = function() return true end
dfhack.units.isAdult = function() return true end
local g = reqscript('claude/gesund')
"""


def test_gesund_status_and_gedanken_are_compact_by_default(tmp_path):
    code = GESUND + ("local r = g.gedanken() print(#r.buerger, r.buerger_anzahl, r.buerger[1].stress)\n"
                     "print(#g.gedanken(true).buerger)\n"
                     "g.cli({ 'status' })\n"
                     "g.cli({ 'status', '--full' })\n")
    lines = run_snippet(code, tmp_path).splitlines()
    assert lines[0].split() == ["15", "20", "100000"] and lines[1] == "20"
    compact, full = json.loads(lines[2]), json.loads(lines[3])
    assert compact["buerger_anzahl"] == full["buerger_anzahl"] == 20
    assert sorted(u["id"] for u in compact["buerger"]) == list(range(9, 21)) and len(full["buerger"]) == 20


def test_mood_plan_compact_keeps_only_risky_skills(tmp_path):
    code = ("local m = reqscript('claude/mood')\n"
            "local full = {\n"
            "  { id = 1, name = 'A', skills = { { skill = 'CARPENTRY', rating = 8, werkstatt = 'Carpenters', status = 'vorhanden',\n"
            "                                    material = 'holz', vorrat = 3, min = 14 },\n"
            "                                  { skill = 'MECHANICS', rating = 5, werkstatt = 'Mechanics', status = 'vorhanden' } } },\n"
            "  { id = 2, name = 'B', skills = { { skill = 'MASONRY', rating = 6, werkstatt = 'Masons', status = 'vorhanden',\n"
            "                                    material = 'stein', vorrat = 900, min = 5 } } },\n"
            "  { id = 3, name = 'C', skills = { { skill = 'BOWYER', rating = 2, werkstatt = 'Bowyers', status = 'FEHLT' } } },\n"
            "}\n"
            "local r, ok, mat = m.plan_compact(full)\n"
            "util = reqscript('claude/util') util.emit({ r = r, ok = ok, mat = mat })\n")
    j = json.loads(run_snippet(code, tmp_path))
    assert j["ok"] == 1 and j["mat"] == {"holz": "3/14", "stein": "900/5"}
    assert j["r"] == [{"id": 1, "name": "A", "risiko": ["CARPENTRY:8 Carpenters holz 3/14"]},
                      {"id": 3, "name": "C", "risiko": ["BOWYER:2 Bowyers FEHLT"]}]


def test_pilot_tools_status_leaves_names_out_unless_full(tmp_path):
    from test_remote import _lua as remote_lua
    out, _ = remote_lua(tmp_path, "pilot_tools.lua", "status")
    assert out["citizens"] and not any("name" in c for c in out["citizens"])
    out, _ = remote_lua(tmp_path, "pilot_tools.lua", "status", "--full")
    assert all(c.get("name") for c in out["citizens"])


# ---------------------------------------------------------------- BUG-220 (Lua side)
def test_material_stock_counts_mechanisms_and_blocks(tmp_path):
    setup = """
local function item(t, n, flags)
  return { pos = { x = 1, y = 1, z = 1 }, flags = flags or {}, stack_size = n,
           getType = function() return t end, subtype = nil }
end
df.item_type = setmetatable({ [10] = 'TRAPPARTS', [11] = 'BLOCKS' }, { __index = function(_, k) return k end })
df.global.world.items.all = { item(10, 1), item(10, 1), item(11, 4), item(11, 3, { forbid = true }) }
"""
    out, r = run("material", "status", tmp_path=tmp_path, setup=setup)
    assert r.returncode == 0, r.stderr
    st = one_json(out)["stock"]
    assert st["mechanism"] == 2 and st["blocks"] == 4                  # forbidden blocks are not free


def test_mood_minimum_matches_the_live_game():
    src = (CLAUDE / "mood.lua").read_text(encoding="utf-8")
    assert "rohgem = 12, schliffgem = 10" in src and "holz = 14" in src and "seide = 3" in src


# ---------------------------------------------------------------- BUG-125: drinks in forbidden barrels
_FORBID_SETUP = """
df.item_type = { DRINK = 'DRINK', FOOD = 'FOOD', MEAT = 'MEAT', FISH = 'FISH', CHEESE = 'CHEESE', EGG = 'EGG',
  PLANT = 'PLANT', PLANT_GROWTH = 'PLANT_GROWTH', SEEDS = 'SEEDS', WOOD = 'WOOD', BOULDER = 'BOULDER', BAR = 'BAR',
  CLOTH = 'CLOTH', BARREL = 'BARREL', BIN = 'BIN', BED = 'BED' }
local function item(t, n, forbid, cont)
  return { flags = { forbid = forbid or false }, _t = t, _n = n, _in = cont,
           getType = function(s) return s._t end, getStackSize = function(s) return s._n end }
end
local list = {}
for i = 1, 10 do
  local b = item('BARREL', 1, MOCK_FORBID)
  list[#list + 1] = b
  list[#list + 1] = item('DRINK', 25, false, b)
end
list[#list + 1] = item('FOOD', 30, false)
df.global.world.items.other.IN_PLAY = list
dfhack.items.getContainer = function(it) return it._in end
local u = { pos = { x = 1, y = 1, z = 1 }, job = {} }
dfhack.units.getCitizens = function() return { u } end
dfhack.units.getStressCategory = function() return 3 end
dfhack.units.isChild = function() return false end
dfhack.units.isBaby = function() return false end
"""


@pytest.mark.parametrize("forbid", [True, False])
def test_bug125_status_does_not_count_drinks_in_forbidden_barrels(tmp_path, forbid):
    setup = f"MOCK_FORBID = {'true' if forbid else 'false'}\n" + _FORBID_SETUP
    out, r = run("status", tmp_path=tmp_path, setup=setup)
    assert r.returncode == 0, r.stderr
    j = one_json(out)
    st = j["stock"]
    if forbid:
        assert (st["drink"], st["drink_forbidden"], j["drink_days"]) == (0, 250, 0)
        assert "Drinks forbidden: 250 (not drinkable)" in j["alerts"]
    else:
        assert (st["drink"], st["drink_forbidden"]) == (250, 0)
        assert not [a for a in j["alerts"] if "forbidden" in a]
    assert st["food"] == 30 and st["food_forbidden"] == 0


def test_bug125_util_forbidden_follows_nested_containers(tmp_path):
    code = ("local util = reqscript('claude/util')\n"
            "local wagon = { flags = { forbid = true } }\n"
            "local barrel = { flags = { forbid = false }, _in = wagon }\n"
            "local drink = { flags = { forbid = false }, _in = barrel }\n"
            "dfhack.items.getContainer = function(it) return it._in end\n"
            "print(util.forbidden(drink), util.forbidden(wagon), util.forbidden({ flags = { forbid = false } }))\n")
    assert run_snippet(code, tmp_path).split() == ["true", "true", "false"]
