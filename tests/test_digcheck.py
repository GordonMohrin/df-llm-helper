"""Spec v3-02 dig safety checker: R1..R6 each with a positive (and negative) case, unrevealed tiles reported not
judged, blocks of 500 with pauses, inputs (rect, quickfort CSV, stages.lua), --strip, gamelog correlation.
Grid fixtures dig_*.grid are SYNTHETIC (see their headers); stages come from the real lua/claude/stages.lua."""
import json
import os
import shutil
import subprocess
import time

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import digcheck as D
from df_llm_helper.features._grid import Grid
from df_llm_helper.store import Store
from df_llm_helper.water import DEFAULTS as WATER
from helpers import ROOT

LUA = shutil.which("lua5.4") or shutil.which("lua")
GRID = ROOT / "fixtures" / "v3" / "grid"
MOCK = ROOT / "tests" / "lua_mock" / "grid_mock.lua"
NOWATER = {"use_water_boxes": False}


def grid(name):
    return Grid.from_file(GRID / name)


def check(name, rect, cfg=None, **kw):
    return D.check_targets(grid(name), D.parse_rect(rect), cfg, **kw)


def rules(rep):
    return set(rep.rules())


def test_r2_north_opening_reports_outside_contact_with_coordinates():
    """Acceptance 1: the stage that produced the north opening (z131, y70..77) -> R2 with coordinates."""
    rep = check("dig_north_opening.grid", "131 100 70 122 77")
    assert rep.result == "refused" and rules(rep) == {"R2"}
    r2 = rep.rules()["R2"]
    assert {f.xyz[1] for f in r2} == {70, 71}                         # roof/wall thickness 2 at z >= 130
    assert (100, 70, 131) in {f.xyz for f in r2}
    assert any("R2 outside contact within 2: x100..122 y70..71 z131 (46 tiles)" in ln for ln in rep.lines())
    assert check("dig_north_opening.grid", "131 100 72 122 77").result == "ok"
    # below the surface level thickness 1 is enough
    assert check("dig_north_opening.grid", "131 100 71 122 77", {"surface_z": 140}).result == "ok"
    # allowed access (perimeter allow-list) next to the outside tile -> no R2
    assert check("dig_north_opening.grid", "131 110 70 110 70", allow=[(110, 68, 131)]).result == "ok"


def test_r3_diagonal_water_at_access_f():
    """Acceptance 2: F=(184,43,z128) - water only diagonal -> R3 'diagonal'."""
    rep = check("dig_river_diagonal.grid", "128 184 43 184 43", NOWATER)
    assert rules(rep) == {"R3"}
    assert rep.findings[0].text == "Water diagonal (1,-1,0)"
    assert check("dig_river_diagonal.grid", "128 183 44 183 44", NOWATER).result == "ok"
    rep = check("dig_river_diagonal.grid", "128 180 44 180 44", NOWATER)    # aquifer wall diagonal below
    assert rules(rep) == {"R3"} and rep.findings[0].text.startswith("aquifer wall slanted z-1")


def test_r4_blocked_box_from_water_and_config():
    """Acceptance 3: stage inside a blocked box (water.forbid_dig) -> R4."""
    rep = check("dig_river_diagonal.grid", "128 183 44 183 44", forbid_boxes=WATER["forbid_dig"])
    assert rules(rep) == {"R4"} and "181, 42, 127, 189, 49, 128" in rep.findings[0].text
    rep = check("dig_north_opening.grid", "131 108 77 113 77", {"forbid_boxes": [[110, 77, 131, 111, 77, 131]]})
    assert rules(rep) == {"R4"} and len(rep.findings) == 2


def test_r1_level_limits():
    rep = check("dig_cavern_unreachable.grid", "103 60 73 66 73")
    assert "R1" in rules(rep) and rep.rules()["R1"][0].text == "z103 outside 104..140"
    assert "R1" not in rules(check("dig_cavern_unreachable.grid", "107 60 73 66 73"))
    assert "R1" in rules(check("dig_cavern_unreachable.grid", "107 60 73 66 73", {"z_max": 106}))


def test_r5_cavern_void_and_box():
    rep = check("dig_cavern_unreachable.grid", "107 67 66 69 66")
    assert "R5" in rules(rep) and "underground open space" in rep.rules()["R5"][0].text
    rep = check("dig_cavern_unreachable.grid", "107 60 73 66 73", {"cavern_boxes": [[60, 75, 107, 66, 80, 107]]})
    assert "R5" in rules(rep) and "cavern box" in rep.rules()["R5"][0].text
    assert "R5" not in rules(check("dig_cavern_unreachable.grid", "107 60 73 66 73"))
    # one channel/stair hole is not a cavern
    g = Grid.from_text("@origin 0 0\nz 5\n.##\nz 4\n#V#\n")
    assert "R5" not in rules(D.check_targets(g, D.parse_rect("5 1 0 1 0")))


def test_r6_unreachable_and_inappropriate():
    """Acceptance 4: unreachable targets and undiggable tiles -> R6 (source of 'Inappropriate dig square')."""
    rep = check("dig_cavern_unreachable.grid", "104 62 62 64 62")
    assert rules(rep) == {"R6"} and len(rep.findings) == 3 and "no walkable neighbor" in rep.findings[0].text
    rep = check("dig_cavern_unreachable.grid", "107 63 72 63 72")
    assert rules(rep) == {"R6"} and "already dug/open" in rep.findings[0].text
    rep = check("dig_cavern_unreachable.grid", "107 67 72 67 72")
    assert "construction" in rep.findings[0].text
    # a long row that touches the corridor at one end is reachable as a group
    assert check("dig_cavern_unreachable.grid", "107 60 73 66 73").result == "ok"
    # down stairs below a walkable tile count as reachable
    g = Grid.from_text("@origin 0 0\nz 6\n.\nz 5\n#\n")
    assert D.check_targets(g, {(0, 0, 5): "j"}, {"z_min": 0}).result == "ok"
    assert D.check_targets(g, {(0, 0, 5): "d"}, {"z_min": 0}).result == "refused"


def test_gamelog_inappropriate_dig_square_counts():
    lines = (GRID / "gamelog_run5_cancels.txt").read_text(encoding="utf-8").splitlines()
    assert D.inappropriate_cancels(lines) == (41, 29)
    assert D.inappropriate_cancels([]) == (0, 0)


def test_unrevealed_tiles_reported_not_judged():
    """Acceptance 6: unrevealed targets are listed, never judged; hidden neighbors make a target 'uncertain'."""
    rep = check("dig_cavern_unreachable.grid", "108 60 59 63 59")
    assert rep.result == "unsafe" and rep.findings == [] and len(rep.unrevealed) == 4
    assert "4 unrevealed not judged" in rep.summary()
    assert any(ln.startswith("unrevealed (not judged): 4 tiles") for ln in rep.lines())
    rep = check("dig_cavern_unreachable.grid", "108 60 61 63 61")        # revealed wall, hidden tiles 2 rows north
    assert rep.result == "ok"
    rep = check("dig_cavern_unreachable.grid", "107 60 59 60 59")        # hidden tile directly above
    assert rep.result == "unsafe" and rep.uncertain == [(60, 59, 107)]


def test_blocks_of_500_with_pause_and_max_cells(tmp_path):
    """Acceptance 5: 3000 tiles -> 6 dump calls of <= 500 targets with a pause in between; > max_cells refused."""
    clock = FakeClock(0)
    calls = []

    def dump(cmd):
        p = [int(v) for v in cmd.split()[2:]]
        calls.append(p)
        x1, y1, z1, x2, y2, z2 = p
        assert (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1) <= 20000
        # natural wall everywhere, an access corridor along y=50 on z111
        lv = {str(z): [("." if (z == 111 and y == 50) else "#") * (x2 - x1 + 1) for y in range(y1, y2 + 1)]
              for z in range(z1, z2 + 1)}
        return json.dumps({"ok": True, "origin": [x1, y1], "levels": lv})
    m = MockClient({}, clock=clock)
    m.prefix_handlers.append(("claude/pilot_digcheck dump", dump))
    dc = D.DigCheck(m, Store(), clock, NOWATER)
    targets = D.parse_rect("111 0 0 59 49")                              # 3000 tiles, corridor y=50 next to them
    t0 = time.perf_counter()
    rep = dc.check(targets, "N_perf")
    assert time.perf_counter() - t0 < 3.0
    assert rep.cells == 3000 and rep.blocks == 6 and len(calls) == 6
    assert clock.now().epoch == pytest.approx(5 * D.DEFAULTS["pause_s"])  # 5 pauses between 6 blocks
    assert rep.result == "ok", rep.lines()
    assert m.write_calls == []
    big = dc.check(D.parse_rect("111 0 0 60 49"), "too_big")
    assert big.result == "refused" and "max_cells" in big.error and len(calls) == 6
    acts = dc.store.actions()
    assert [a["action"] for a in acts] == ["check", "check"] and acts[0]["ok"] == 1 and acts[1]["ok"] == 0
    bad = D.DigCheck(MockClient({}, clock=clock), Store(), clock, NOWATER).check(D.parse_rect("111 0 0 1 1"))
    assert bad.result == "refused" and "not readable" in bad.error


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_lua_dump_matches_fixture(tmp_path):
    g = grid("dig_cavern_unreachable.grid")
    gp = tmp_path / "g.json"
    gp.write_text(json.dumps(g.to_mock()))

    def run(*args):
        r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_digcheck.lua"), *map(str, args)],
                           capture_output=True, text=True, timeout=30, env={**os.environ, "MOCK_GRID": str(gp)})
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout.splitlines()[0])
    j = run("dump", 58, 56, 104, 82, 78, 108)
    g2 = Grid.from_dump(j)
    for p, ch in g.tiles.items():
        assert g2.get(p) == ch, p
    assert run("dump", 0, 0, 0, 199, 199, 0)["ok"] is False             # 40000 tiles > 20000
    assert run("bogus")["ok"] is False
    # end to end through the client
    m = MockClient({})
    m.prefix_handlers.append(("claude/pilot_digcheck", lambda cmd: json.dumps(run(*cmd.split()[1:]))))
    rep = D.DigCheck(m, Store(), FakeClock(0), NOWATER).check(D.parse_rect("108 60 59 63 59"))
    assert rep.result == "unsafe" and len(rep.unrevealed) == 4


def test_inputs_csv_and_stages():
    csv = "#dig label(t)\nd,d,,h\n,j\n#>\nd\n"
    t = D.parse_qf_csv(csv, (10, 20, 131))
    assert t == {(10, 20, 131): "d", (11, 20, 131): "d", (13, 20, 131): "h", (11, 21, 131): "j", (10, 20, 130): "d"}
    assert D.parse_qf_csv("#build\nCw\n", (0, 0, 0)) == {}
    stages = (ROOT / "examples" / "windrings" / "stages.lua").read_text(encoding="utf-8")
    t, rects = D.parse_stages(stages, "N11")
    assert rects == [(116, 80, 85, 118, 94), (116, 99, 102, 99, 106)]
    assert len(t) == 39 * 10 + 5
    assert D.parse_stages(stages, "N11_Wohn1")[1] == rects
    with pytest.raises(ValueError):
        D.parse_rect("1 2 3")
    assert D.parse_rect("claude/dig 128 1 1 2 1 h") == {(1, 1, 128): "h", (2, 1, 128): "h"}


def test_strip_drops_problem_rows():
    targets = D.parse_rect("131 100 70 122 77")
    rep = D.check_targets(grid("dig_north_opening.grid"), targets)
    cmds = D.strip_commands(targets, rep)
    assert cmds == [f"claude/dig 131 100 {y} 122 {y}" for y in range(72, 78)]


def test_cli_and_alias_and_check_hook(tmp_path, capsys, monkeypatch):
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(0)
    cfg = load_config(overrides={"paths": {"tools": str(tmp_path / "tools"), "scopes": str(tmp_path / "s")}})
    pil = Pilot(cfg, MockClient({}, clock=clock), store=Store(), clock=clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: pil)
    g = str(GRID / "dig_north_opening.grid")
    assert cli.main(["digcheck", "131", "100", "70", "122", "77", "--grid", g, "--strip"]) == 2
    out = capsys.readouterr().out
    assert "refused" in out and "R2" in out and "claude/dig 131 100 72 122 72" in out
    assert cli.main(["dig", "check", "131", "100", "72", "122", "77", "--grid", g]) == 0
    assert "ok (138 tiles)" in capsys.readouterr().out
    assert cli.main(["digcheck", "104", "62", "62", "64", "62", "--grid", str(GRID / "dig_cavern_unreachable.grid"),
                     "--gamelog", str(GRID / "gamelog_run5_cancels.txt")]) == 2
    assert "41x 'Inappropriate dig square' (29 dwarves)" in capsys.readouterr().out
    assert D.check_hook(pil, None, False) == []                          # BUG-204: offline --grid stores nothing
    D.DigCheck(pil.client, pil.store, clock).check(D.parse_rect("104 62 62 64 62"), "rect 104 62 62 64 62",
                                                   grid=Grid.from_file(GRID / "dig_cavern_unreachable.grid"))
    lines = D.check_hook(pil, None, False)
    assert len(lines) == 1 and lines[0].startswith("digcheck rect 104 62 62 64 62: refused") and len(lines[0]) <= 120
    assert D.check_hook(pil, None, False) == []                          # reported once
    assert cli.main(["digcheck"]) == 2                                   # no input
