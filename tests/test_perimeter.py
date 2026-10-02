"""Spec v3-01 access watcher: run-5 J109 accesses (north opening z131 with 23 tiles, stub stair (96,88), trap stair
T1 (99,94,z132) = only allowed one), clustering, allow-list tolerance, change-only reports, stairs rule, seal with what-if.
Grid fixtures perimeter_j109_*.grid are SYNTHETIC (rebuilt from the run-5 notes, see their headers)."""
import json
import os
import shutil
import subprocess
from types import SimpleNamespace

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import perimeter as P
from df_llm_helper.features import reach as R
from df_llm_helper.features._grid import Grid
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from helpers import ROOT

LUA = shutil.which("lua5.4") or shutil.which("lua")
GRID = ROOT / "fixtures" / "v3" / "grid"
MOCK = ROOT / "tests" / "lua_mock" / "grid_mock.lua"
CORE = (100, 101, 130)
ZR = P.DEFAULTS["z_range"]


def grid(name):
    return Grid.from_file(GRID / name)


def per(tmp_path, clock=None, client=None, cfg=None):
    clock = clock or FakeClock(1_790_840_000.0)
    tools = ToolsDir(tmp_path / "tools", clock)
    (tmp_path / "tools").mkdir(parents=True, exist_ok=True)
    (tmp_path / "tools" / "zugang-erlaubt.txt").write_text("99,94,132  trap stair T1 (only allowed access)\n",
                                                           encoding="utf-8")
    return P.Perimeter(client or MockClient({}, clock=clock), tools, Store(), clock, cfg or {})


def lua_run(g, tmp_path, *args):
    tmp_path.mkdir(parents=True, exist_ok=True)
    gp = tmp_path / "grid.json"
    gp.write_text(json.dumps(g.to_mock()))
    (tmp_path / "tools" / "out").mkdir(parents=True, exist_ok=True)
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / f"{args[0]}.lua"), *map(str, args[1:])], capture_output=True,
                       text=True, timeout=120, env={**os.environ, "MOCK_GRID": str(gp), "MOCK_HOME": str(tmp_path),
                                                    "MOCK_MAP": "130,110,140"})
    assert r.returncode == 0, r.stderr
    return r.stdout, r.stderr


def test_j109_three_accesses_two_forbidden_then_only_t1(tmp_path):
    """Acceptance 1: before sealing 3 accesses to the core, 2 forbidden; after sealing only (99,94)."""
    pe = per(tmp_path)
    acc, wake, line = pe.evaluate(P.scan_grid(grid("perimeter_j109_open.grid"), CORE, ZR))
    core = [a for a in acc if a.core]
    assert len(core) == 3
    bad = [a for a in core if a.forbidden]
    assert len(bad) == 2
    assert {a.center for a in bad} == {(111, 70, 131), (96, 88, 132)}
    t1 = next(a for a in core if a.allowed)
    assert t1.tiles == [(99, 94, 132)] and not t1.notrap                  # the trap path really runs through the traps
    assert all(a.notrap for a in bad)                                     # both holes bypass the traps
    assert len(wake) == 2 and all(w.startswith("WAKE perimeter: forbidden access to the core at") for w in wake)
    assert line.startswith("Accesses: 1 allowed, 2 forbidden (checked ")
    acc2, wake2, line2 = pe.evaluate(P.scan_grid(grid("perimeter_j109_sealed.grid"), CORE, ZR))
    assert [a.tiles for a in acc2 if a.core] == [[(99, 94, 132)]]
    assert wake2 == ["WAKE perimeter: all forbidden accesses closed (only allowed ones open)"]
    assert line2.startswith("Accesses: 1 allowed, 0 forbidden (checked ")
    acts = [a for a in pe.store.actions() if a["source"] == "perimeter"]
    assert [a["ok"] for a in acts] == [0, 1]
    assert any(w["key"] == "perimeter:forbidden" and w["level"] == "crit" for w in pe.store.take_warnings())


def test_north_opening_23_tiles_is_one_finding():
    """Acceptance 2: the 23 entry tiles of the north opening form ONE cluster."""
    acc = P.build_accesses(P.scan_grid(grid("perimeter_j109_open.grid"), CORE, ZR), [(99, 94, 132)])
    north = [a for a in acc if a.center[2] == 131]
    assert len(north) == 1 and north[0].n == 23 and north[0].label() == "(111,70,z131) 23 tiles"


def test_stairs_rule_walls_on_inside_floor_not_on_the_stair(tmp_path):
    """Acceptance 3: access via a stair -> wall proposal on the adjacent inside floor tile, no build order on the stair."""
    g = grid("perimeter_j109_open.grid")
    acc = P.build_accesses(P.scan_grid(g, CORE, ZR), [(99, 94, 132)])
    stub = next(a for a in acc if a.center == (96, 88, 132))
    walls, notes = P.seal_walls(g, stub)
    assert walls == [(96, 89, 132)] and notes == []
    assert (96, 88, 132) not in walls
    north = next(a for a in acc if a.center[2] == 131)
    assert P.seal_walls(g, north)[0] == [(x, 70, 131) for x in range(100, 123)]
    csv, cur = P.seal_csv([(96, 89, 132)] + [(x, 70, 131) for x in range(100, 123)])
    assert cur == (96, 70, 132)
    # map the CSV back to coordinates: exactly the walls, nothing on the stair
    cells, z, y = set(), cur[2], cur[1]
    for ln in csv.splitlines()[1:]:
        if ln == "#>":
            z, y = z - 1, cur[1]
            continue
        for i, c in enumerate(ln.split(",")):
            if c == "Cw":
                cells.add((cur[0] + i, y, z))
        y += 1
    assert cells == {(96, 89, 132)} | {(x, 70, 131) for x in range(100, 123)}
    assert csv.startswith("#build label(df_llm_helper_seal)")
    # a ramp entry is treated like a stair
    g2 = Grid.from_text("@origin 0 0\nz 5\n#.#\n.^.\n#.#\n")
    assert P.seal_walls(g2, P.Access([(1, 1, 5)], True, True))[0] == [(0, 1, 5), (1, 0, 5), (1, 2, 5), (2, 1, 5)]
    g3 = Grid.from_text("@origin 0 0\nz 5\nD\n")
    assert P.seal_walls(g3, P.Access([(0, 0, 5)], True, True))[1][0].startswith("building on entry tile")


@pytest.mark.parametrize("shift,allowed", [(0, True), (3, True), (4, True), (5, False), (6, False)])
def test_allowlist_tolerance(shift, allowed):
    """Acceptance 4: shifted by 3 tiles stays allowed, by 6 not (tolerance +-4 xy / +-2 z)."""
    assert P.is_allowed((99 + shift, 94, 132), [(99, 94, 132)]) is allowed
    assert P.is_allowed((99, 94 - shift, 132), [(99, 94, 132)]) is allowed
    ents = [(99 + shift, 94, 132, True, False)]
    assert P.build_accesses(ents, [(99, 94, 132)])[0].allowed is allowed


def test_allowlist_z_tolerance_and_file(tmp_path):
    assert P.is_allowed((99, 94, 134), [(99, 94, 132)]) and not P.is_allowed((99, 94, 135), [(99, 94, 132)])
    f = tmp_path / "a.txt"
    f.write_text("# comment\n99,94,132  T1\n 10 , 20 , 30 x\nbad line\n", encoding="utf-8")
    assert P.load_allow(f) == [(99, 94, 132), (10, 20, 30)]
    assert P.load_allow(tmp_path / "missing.txt") == []


def test_no_output_on_unchanged_second_run(tmp_path):
    """Acceptance 5: two runs without a change = 0 lines; a new opening = 1 line."""
    pe = per(tmp_path)
    sealed = P.scan_grid(grid("perimeter_j109_sealed.grid"), CORE, ZR)
    assert pe.evaluate(sealed)[1] == []                                   # first run, nothing forbidden
    assert pe.evaluate(sealed)[1] == []
    opened = P.scan_grid(grid("perimeter_j109_open.grid"), CORE, ZR)
    assert len(pe.evaluate(opened)[1]) == 2
    assert pe.evaluate(opened)[1] == []                                   # unchanged -> silent
    partly = [e for e in opened if e[2] != 131]                           # north row closed, stub stair still open
    assert pe.evaluate(partly)[1] == ["perimeter: 1 forbidden access(es) closed, 1 still open"]


def test_digest_line_format(tmp_path):
    """Acceptance 6: 'Accesses: 1 allowed, 0 forbidden (checked 20:05)'."""
    acc = P.build_accesses(P.scan_grid(grid("perimeter_j109_sealed.grid"), CORE, ZR), [(99, 94, 132)])
    assert P.digest_line(acc, "20:05") == "Accesses: 1 allowed, 0 forbidden (checked 20:05)"


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
@pytest.mark.parametrize("name", ["perimeter_j109_open.grid", "perimeter_j109_sealed.grid"])
def test_lua_scan_equals_python_reference(tmp_path, name):
    """pilot_perimeter.lua (sync scan and chunked start/result) == Python reference on the same grid."""
    g = grid(name)
    ref = [list(e[:3]) + [int(e[3]), int(e[4])] for e in P.scan_grid(g, CORE, ZR)]
    out, _ = lua_run(g, tmp_path, "pilot_perimeter", "scan", 100, 101, 130, 100, 136, 20000, 0)
    j = json.loads(out.splitlines()[0])
    assert j["done"] and sorted(j["entries"]) == sorted(ref) and j["traps"] == 2
    out, _ = lua_run(g, tmp_path, "pilot_perimeter", "scan", 100, 101, 130, 100, 136, 20000, 3000)
    assert json.loads(out.splitlines()[0])["entries"] == []               # enclave filter 3000: grid too small
    out, err = lua_run(g, tmp_path, "pilot_perimeter", "start", 100, 101, 130, 100, 136, 200, 0)
    assert json.loads(out)["started"] is True
    ticks = int(err.split("ticks=")[1].split()[0])
    assert ticks > 5                                                      # really chunked over several frames
    res = json.loads((tmp_path / "tools" / "out" / "perimeter_scan.json").read_text())
    assert sorted(res["entries"]) == sorted(ref)
    out, _ = lua_run(g, tmp_path, "pilot_perimeter", "result")
    assert sorted(json.loads(out)["entries"]) == sorted(ref)
    out, _ = lua_run(g, tmp_path, "pilot_perimeter", "bogus")
    assert json.loads(out)["ok"] is False


def _lua_client(g, tmp_path, clock):
    def run(cmd):
        parts = cmd.split()
        return lua_run(g, tmp_path, parts[0].split("/")[1], *parts[1:])[0]
    m = MockClient({}, clock=clock)
    m.prefix_handlers.append(("claude/pilot_", run))
    return m


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_check_hook_never_blocks_start_then_evaluate(tmp_path):
    """check: start chunked scan (no lines), next check evaluates (WAKE + digest), unchanged later scan -> silent."""
    clock = FakeClock(1_790_840_000.0)
    g = grid("perimeter_j109_open.grid")
    pe = per(tmp_path, clock, _lua_client(g, tmp_path, clock))
    pil = SimpleNamespace(cfg={"perimeter": {"min_outside": 0}}, client=pe.client, tools=pe.tools, store=pe.store, clock=clock)
    rep = SimpleNamespace(snapshot=SimpleNamespace(paused=False))
    assert P.check_hook(pil, rep, False) == []
    assert pe.store.get("perimeter.pending")
    out = P.check_hook(pil, rep, False)
    assert len(out) == 3 and out[-1].startswith("Accesses: 1 allowed, 2 forbidden")
    assert P.check_hook(pil, rep, False) == []                            # interval 1200 s
    clock.advance(1201)
    assert P.check_hook(pil, rep, False) == [] and P.check_hook(pil, rep, False) == []   # same holes: no new line
    clock.advance(1201)
    pe.tools.write_flag("alert", "enemies")
    assert P.check_hook(pil, rep, False) == [] and not pe.store.get("perimeter.pending")  # no scan during an alarm
    pe.tools.delete_flag("alert")
    assert P.check_hook(pil, SimpleNamespace(snapshot=SimpleNamespace(paused=True)), False) == []
    assert not pe.store.get("perimeter.pending")                          # game paused: no scan
    assert pe.client.write_calls == []
    assert P.check_hook(pil, rep, True) == []                             # dry: nothing


def _reach_for(g, store, clock, points):
    return R.ReachWatch(MockClient({}, clock=clock), store, clock, {}, points=points, start=CORE)


def test_seal_dry_run_writes_csv_apply_needs_what_if(tmp_path):
    """seal --dry-run writes the CSV; --apply runs quickfort only if what-if is safe or with an override."""
    clock = FakeClock(1_790_840_000.0)
    g = grid("perimeter_j109_open.grid")
    pe = per(tmp_path, clock, cfg={"blueprints_dir": str(tmp_path / "bp")})
    acc = pe.evaluate(P.scan_grid(g, CORE, ZR))[0]
    code, lines = pe.seal(acc, grid=g)
    assert code == 0 and lines[0].startswith("Seal proposal: 24 walls (Cw), cursor 96,70,132")
    assert (tmp_path / "tools" / "out" / "perimeter_seal.csv").read_text().count("Cw") == 24
    assert pe.client.write_calls == []
    # a mandatory farm plot on the north row: the seal walls would cover it -> refused
    pts = [R.Point("Farm plot north", (110, 70, 131), "farm", True), R.Point("Core hall", (98, 102, 130), "hospital", True)]
    reach = _reach_for(g, pe.store, clock, pts)
    code, lines = pe.seal(acc, apply=True, grid=g, reach=reach)
    assert code == 2 and any("would CUT OFF Farm plot north (110,70,z131)" in ln for ln in lines)
    assert any(ln.startswith("REFUSED") for ln in lines) and pe.client.write_calls == []
    code, lines = pe.seal(acc, apply=True, grid=g, reach=reach, override="player: yes, close the stub stair")
    assert code == 0 and pe.client.write_calls == ["quickfort run claude/df_llm_helper_seal.csv -c 96,70,132"]
    assert (tmp_path / "bp" / "claude" / "df_llm_helper_seal.csv").exists()
    acts = [(a["action"], a["ok"]) for a in pe.store.actions() if a["source"] == "perimeter"]
    assert ("seal-refused", 0) in acts and ("seal", 1) in acts and ("seal-plan", 1) in acts
    # without a cut mandatory point --apply goes through directly
    pe2 = per(tmp_path / "x", clock, cfg={"blueprints_dir": str(tmp_path / "bp2")})
    code, _ = pe2.seal(acc, apply=True, grid=g, reach=_reach_for(g, pe2.store, clock, pts[1:]))
    assert code == 0 and len(pe2.client.write_calls) == 1
    assert pe2.seal(acc, apply=True, grid=g, reach=None)[0] == 2          # never without what-if
    assert pe2.seal([], grid=g)[1][0].startswith("Seal: nothing to do")


def test_parse_scan_and_cli_offline(tmp_path, capsys, monkeypatch):
    assert P.parse_scan({"ok": True, "done": False}) is None
    assert P.parse_scan({"ok": True, "done": True, "entries": [[1, 2, 3, 1, 0], [1]]}) == [(1, 2, 3, True, False)]
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(1_790_840_000.0)
    cfg = load_config(overrides={"paths": {"tools": str(tmp_path / "tools"), "scopes": str(tmp_path / "s")}})
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(cfg, MockClient({}, clock=clock), store=Store(), clock=clock))
    assert cli.main(["perimeter", "scan", "--grid", str(GRID / "perimeter_j109_open.grid")]) == 1
    out = capsys.readouterr().out
    assert "Accesses: 1 allowed, 2 forbidden" in out and "(111,70,z131) 23 tiles" in out
    assert cli.main(["perimeter", "seal", "--grid", str(GRID / "perimeter_j109_open.grid")]) == 0
    assert "Cw" in capsys.readouterr().out
    assert cli.main(["perimeter", "allow", "120", "70", "131", "--note", "test"]) == 0
    assert "allowed: 120,70,131" in capsys.readouterr().out
    assert cli.main(["perimeter", "status"]) == 0
    assert cli.main(["perimeter", "scan"]) == 2                           # no DF: not readable
    assert "not readable" in capsys.readouterr().out


# ---- a building tile that blocks walking (statue/well, 'W') is no way in; workshops are (DF: walkable, live 02.10.)
STATUE_TXT = """@origin 0 0
@core 7 1 130
z 130
##########
#,,,W...##
##########
"""


def test_blocking_building_tile_is_not_an_access():
    g = Grid.from_text(STATUE_TXT)
    assert P.scan_grid(g, (7, 1, 130), ZR) == []                          # the statue plugs the only opening
    g2 = Grid.from_text(STATUE_TXT.replace("W", "."))
    assert [tuple(e[:3]) for e in P.scan_grid(g2, (7, 1, 130), ZR)] == [(4, 1, 130)]
    assert [tuple(e[:3]) for e in P.scan_grid(g2, (7, 1, 130), ZR) if e[3]] == [(4, 1, 130)]


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_lua_scan_blocking_building_equals_python(tmp_path):
    for txt, n in ((STATUE_TXT, 0), (STATUE_TXT.replace("W", "."), 1)):
        g = Grid.from_text(txt)
        out, _ = lua_run(g, tmp_path / str(n), "pilot_perimeter", "scan", 7, 1, 130, 100, 136, 20000, 0)
        j = json.loads(out.splitlines()[0])
        assert len(j["entries"]) == n


# ---- enclave filter (commit aefbb0f): a walled-in outside terrace (< min_outside tiles) is not the outside world
ENCLAVE_TXT = """@origin 0 0
@core 7 3 130
z 130
############
#,,,,,,,,..#
############
#,,........#
############
"""


def test_enclave_filter_python_reference():
    g = Grid.from_text(ENCLAVE_TXT)
    assert sorted(tuple(e[:3]) for e in P.scan_grid(g, (7, 3, 130), ZR)) == [(3, 3, 130), (9, 1, 130)]
    assert [tuple(e[:3]) for e in P.scan_grid(g, (7, 3, 130), ZR, min_outside=5)] == [(9, 1, 130)]
    assert P.scan_grid(g, (7, 3, 130), ZR, min_outside=9) == []           # 8 outside tiles < 9
    assert len(P.scan_grid(g, (7, 3, 130), ZR, min_outside=8)) == 1        # exactly 8 counts (>=)


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
@pytest.mark.parametrize("mincomp", [0, 5, 8, 9])
def test_lua_enclave_filter_equals_python(tmp_path, mincomp):
    g = Grid.from_text(ENCLAVE_TXT)
    ref = sorted(list(e[:3]) + [int(e[3]), int(e[4])] for e in P.scan_grid(g, (7, 3, 130), ZR, min_outside=mincomp))
    out, _ = lua_run(g, tmp_path, "pilot_perimeter", "scan", 7, 3, 130, 100, 136, 20000, mincomp)
    assert sorted(json.loads(out.splitlines()[0])["entries"]) == ref


def test_live_args_pass_min_outside(tmp_path):
    assert per(tmp_path)._args().endswith(" 20000 3000")
    assert per(tmp_path / "b", cfg={"min_outside": 0})._args().endswith(" 20000 0")
