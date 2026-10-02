"""Spec v3-11 reachability watcher: P1/P2 plugs cut farms/kitchens/stills, cause search, what-if, correlation.
Grid fixtures fixtures/v3/grid/reach_p1p2_*.grid are SYNTHETIC (rebuilt from the run-5 notes, see their headers);
the gamelog excerpt gamelog_run5_cancels.txt is synthetic with the real counts (493x / 43 dwarves)."""
import json
import os
import shutil
import subprocess
import time
from types import SimpleNamespace

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import reach as R
from df_llm_helper.features._grid import Grid
from df_llm_helper.store import Store
from helpers import ROOT

LUA = shutil.which("lua5.4") or shutil.which("lua")
GRID = ROOT / "fixtures" / "v3" / "grid"
MOCK = ROOT / "tests" / "lua_mock" / "grid_mock.lua"
MAND = R.DEFAULTS["mandatory"]
CORE = (100, 101, 130)


def load(name):
    g = Grid.from_file(GRID / name)
    start, pts = R.points_from_grid(g, MAND)
    return g, start, pts


def lua_client(grid, tmp_path, clock):
    """MockClient that answers claude/pilot_* by running the real Lua script on the grid mock."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    gp = tmp_path / "grid.json"
    gp.write_text(json.dumps(grid.to_mock()))
    (tmp_path / "tools" / "out").mkdir(parents=True, exist_ok=True)

    def run(cmd):
        parts = cmd.split()
        script = ROOT / "lua" / (parts[0].split("/")[1] + ".lua")
        r = subprocess.run([LUA, str(MOCK), str(script), *parts[1:]], capture_output=True, text=True, timeout=60,
                           env={**os.environ, "MOCK_GRID": str(gp), "MOCK_HOME": str(tmp_path),
                                "MOCK_MAP": "130,110,140"})
        assert r.returncode == 0, r.stderr
        return r.stdout
    m = MockClient({}, clock=clock)
    m.prefix_handlers.append(("claude/pilot_", run))
    return m


def test_p1p2_built_names_p1_as_cutting_construction():
    """Acceptance 1: F1, F3-F5, kitchens, stills unreachable; (101,99,z130) named."""
    g, start, pts = load("reach_p1p2_built.grid")
    assert start == CORE
    w = R.ReachWatch(MockClient({}), Store(), FakeClock(0), {}, points=pts, start=start)
    status, causes, lines = w.run(grid=g)
    bad = sorted(k for k, v in status.items() if v is False)
    assert bad == ["F1", "F3", "F4", "F5", "Kitchens", "Stills"]
    assert status["Hospital"] is True
    assert all(causes[n][0] == (101, 99, 130) for n in bad)
    assert causes["F1"] == [(101, 99, 130), (100, 94, 132)]                  # P2 lies behind P1 on the way to F1
    assert causes["F3"] == [(101, 99, 130)]
    assert lines[0] == "UNREACHABLE: F1, F3, F4, F5, Kitchens, Stills (cut at (101,99,z130))"
    assert len(lines[0]) <= R.LINE_MAX
    assert any("(101,99,z130), (100,94,z132)" in ln and "door" in ln for ln in lines)
    acts = w.store.actions()
    assert acts and acts[-1]["source"] == "reach" and acts[-1]["action"] == "measure" and acts[-1]["ok"] == 0
    assert any(x["key"] == "reach:unreachable" and x["level"] == "crit" for x in w.store.take_warnings())


def test_p1p2_removed_door_all_reachable():
    """Acceptance 2: P1 replaced by a door, P2 removed -> every mandatory point reachable."""
    g, start, pts = load("reach_p1p2_removed.grid")
    w = R.ReachWatch(MockClient({}), Store(), FakeClock(0), {}, points=pts, start=start)
    status, causes, lines = w.run(grid=g)
    assert all(status.values()) and causes == {}
    assert lines == ["Reachable: 7/7 mandatory points"]
    assert w.store.take_warnings() == []


def test_what_if_warns_before_building_p1():
    """Acceptance 3: what-if --wall 101 99 130 warns about cutting off the farms."""
    g, start, pts = load("reach_p1p2_removed.grid")
    st = Store()
    w = R.ReachWatch(MockClient({}), st, FakeClock(0), {}, points=pts, start=start)
    res = w.what_if([(101, 99, 130)], grid=g)
    assert not res.safe
    assert {p.name for p in res.cut} == {"F1", "F3", "F4", "F5", "Kitchens", "Stills"}
    assert res.lines()[0].startswith("!! what-if (101,99,z130): would CUT OFF F1 (106,92,z132)")
    assert w.what_if([(95, 103, 130)], grid=g).safe                       # corner of the core hall: harmless
    assert w.what_if([(100, 94, 132)], grid=g).cut                        # P2 alone cuts F1/kitchens/stills
    assert {p.name for p in w.what_if([(100, 94, 132)], grid=g).cut} == {"F1", "Kitchens", "Stills"}
    assert [a["action"] for a in st.actions()] == ["what-if"] * 4


def test_correlation_493_spawn_cancels_to_farm_points():
    """Acceptance 5: 493x 'Needs plump helmet spawn' -> farm points F3/F4/F5 (and F1), cause certain."""
    g, start, pts = load("reach_p1p2_built.grid")
    lines = (GRID / "gamelog_run5_cancels.txt").read_text(encoding="utf-8").splitlines()
    cs = R.correlate(lines, pts, {"F1", "F3", "F4", "F5", "Kitchens", "Stills"})
    farm = next(c for c in cs if c.cat == "farm")
    assert farm.count == 493 and farm.who == 43
    assert {"F3", "F4", "F5"} <= set(farm.points) and "certain" in farm.verdict
    assert not any("Needs logs" in j for c in cs for j in c.jobs)        # material shortages are not path problems
    depot = next(c for c in cs if c.cat == "depot")
    assert depot.count == 12 and depot.points == [] and "other cause" in depot.verdict
    # with the plugs removed the same cancels are 'other cause'
    assert "other cause" in next(c for c in R.correlate(lines, pts, set()) if c.cat == "farm").verdict
    w = R.ReachWatch(MockClient({}), Store(), FakeClock(0), {}, points=pts, start=start)
    _, _, out = w.run(grid=g, gamelog_lines=lines)
    assert any(ln.startswith("farm: 493x 'Plant Seeds: Needs plump helmet spawn' (43 dwarves) -> F1, F3, F4, F5")
               for ln in out)


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_live_path_through_lua_mock(tmp_path):
    """pilot_reach.lua check (canWalkBetween) + dump on the grid mock -> same result as the pure grid logic."""
    clock = FakeClock(0)
    g, start, pts = load("reach_p1p2_built.grid")
    m = lua_client(g, tmp_path, clock)
    w = R.ReachWatch(m, Store(), clock, {}, points=pts, start=start)
    status, causes, lines = w.run()
    assert status == R.measure_grid(g, start, pts)
    assert causes["F3"] == [(101, 99, 130)]
    assert lines[0].startswith("UNREACHABLE: F1, F3, F4, F5, Kitchens, Stills (cut at (101,99,z130))")
    assert m.write_calls == []                                            # read only
    g2, _, _ = load("reach_p1p2_removed.grid")
    w2 = R.ReachWatch(lua_client(g2, tmp_path / "b", clock), Store(), clock, {}, points=pts, start=start)
    res = w2.what_if([(101, 99, 130)])
    assert not res.safe and "F3" in {p.name for p in res.cut}
    # Lua dump == fixture characters
    j = json.loads(m.run("claude/pilot_reach dump 99 98 130 102 100 130").stdout)
    assert j["levels"]["130"] == ["##.#", "##C#", "...."]


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_runtime_20_points_under_1s(tmp_path):
    """Acceptance 4: one check call for 20 points <= 1 s (Lua mock incl. process start + Python evaluation)."""
    clock = FakeClock(0)
    g, start, pts = load("reach_p1p2_removed.grid")
    pts20 = [R.Point(f"P{i}", p.xyz, p.cat, True) for i, p in enumerate((pts * 3)[:20])]
    m = lua_client(g, tmp_path, clock)
    w = R.ReachWatch(m, Store(), clock, {}, points=pts20, start=start)
    t0 = time.perf_counter()
    status = w.measure()
    assert time.perf_counter() - t0 <= 1.0
    assert len(status) == 20 and all(status.values())
    assert len(m.calls) == 1


def test_parse_check_unreadable_and_digest_variants():
    pts = [R.Point("A", (1, 1, 1), "farm", True), R.Point("B", (2, 2, 2), "depot", False)]
    assert R.parse_check(None, pts) == {"A": None, "B": None}
    assert R.parse_check({"ok": True, "results": [True]}, pts) == {"A": True, "B": None}
    assert R.digest_line(pts, {"A": None}) == "Reachable: 0/1 mandatory points (1 not readable)"
    assert R.digest_line(pts, {"A": False}, {"A": None}) == "UNREACHABLE: A (cause unknown)"
    many = [R.Point(f"Very long point name {i}", (i, 0, 0), "farm", True) for i in range(12)]
    s = R.digest_line(many, {p.name: False for p in many}, {p.name: [(1, 2, 3)] for p in many})
    assert len(s) <= R.LINE_MAX and s.endswith("…")


def test_points_file_example_values():
    start, pts = R.load_points(ROOT / "data" / "reach.yaml", MAND)
    assert start == CORE
    by = {p.name: p for p in pts}
    assert by["Farm hall F1"].xyz == (106, 92, 132) and by["Farm hall F1"].mandatory
    assert by["Kitchens"].xyz == (106, 85, 132) and by["Stills"].xyz == (110, 89, 132)
    assert by["Depot"].mandatory is False and by["Well"].mandatory
    assert R.load_points(ROOT / "nope.yaml") == (None, [])


def _pilot(cfg_over, client, clock, store, gamelog=()):
    return SimpleNamespace(cfg={"reach": cfg_over}, client=client, clock=clock, store=store,
                           gamelog=lambda: SimpleNamespace(recent=lambda: list(gamelog)))


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_check_hook_interval_lines_and_recovery(tmp_path):
    clock = FakeClock(1000)
    g, start, pts = load("reach_p1p2_built.grid")
    pf = tmp_path / "pts.yaml"
    pf.write_text("start: [100, 101, 130]\npoints:\n" + "".join(
        f"  - {{name: \"{p.name}\", xyz: [{p.xyz[0]}, {p.xyz[1]}, {p.xyz[2]}], cat: {p.cat}}}\n" for p in pts))
    st = Store()
    m = lua_client(g, tmp_path, clock)
    p = _pilot({"points_file": str(pf)}, m, clock, st)
    out = R.check_hook(p, None, False)
    assert out[0].startswith("UNREACHABLE: F1, F3") and all(len(x) <= R.LINE_MAX for x in out)
    assert R.check_hook(p, None, False) == []                             # interval 300 s
    clock.advance(301)
    g2, _, _ = load("reach_p1p2_removed.grid")
    p.client = lua_client(g2, tmp_path / "b", clock)
    assert R.check_hook(p, None, False) == ["Reachable: 7/7 mandatory points (again)"]
    clock.advance(301)
    assert R.check_hook(p, None, False) == []                             # all good, unchanged -> silent
    assert R.check_hook(_pilot({"points_file": str(tmp_path / "none.yaml")}, m, clock, Store()), None, False) == []


def test_cli_reach_offline(capsys, tmp_path, monkeypatch):
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(0)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(load_config(overrides={"paths": {"tools": str(tmp_path)}}),
                                                          MockClient({}, clock=clock), store=Store(), clock=clock))
    assert cli.main(["reach", "--grid", str(GRID / "reach_p1p2_built.grid")]) == 1
    assert "cut at (101,99,z130)" in capsys.readouterr().out
    assert cli.main(["reach", "what-if", "--wall", "101", "99", "130", "--grid",
                     str(GRID / "reach_p1p2_removed.grid")]) == 1
    assert "would CUT OFF" in capsys.readouterr().out
    assert cli.main(["reach", "--grid", str(GRID / "reach_p1p2_removed.grid")]) == 0
    assert cli.main(["reach", "correlate", "--grid", str(GRID / "reach_p1p2_built.grid"), "--gamelog",
                     str(GRID / "gamelog_run5_cancels.txt")]) == 1
    assert "farm: 493x" in capsys.readouterr().out
    assert cli.main(["reach", "points"]) == 0
    assert "Farm hall F1 (106,92,z132)" in capsys.readouterr().out
