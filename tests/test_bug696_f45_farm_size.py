"""BUG-696 (Run 16c i3 Wallfree y431-y433: `bp sites farms surface=1` 'no plot block fits' on 2836 soil tiles, 28 citizens starved): the soil of the
surface was speckled with non-soil floor tiles (the live snapshot: 11,344 blocks looked at, every one holds a non-soil tile; the largest solid
rectangle 6x4, 118 places for a 3x3 plot), and the 5x7 plot was the smallest the template knew. The farms template has a plot size (p.size: 5x7,
5x4, 4x4, 3x3, 2x2) for a surface farm, bp.place falls back to smaller sizes after fewer plots, the plan's farm site counts them, and the
refusal counts the blocks per cut condition. The snapshot below has the live shape: soil floor with a non-soil tile at every x % 4 == 3 AND
y % 4 == 3 (3-wide solid columns and 3-high solid rows)."""
from __future__ import annotations

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, plan, schema
from dfpilot.bp import render, rooms, sites
from dfpilot.bp.emit import check_params, emit


@pytest.fixture(autouse=True)
def _surface_core_on(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: True)


X0, Y0, Z = 300, 300, 148
W, H = 40, 30


def _snap(speck=True) -> dict:
    def c(x, y):
        return "." if not (speck and x % 4 == 3 and y % 4 == 3) else "."     # the speckle is a floor with no soil mark
    rows = ["".join(c(x, y) for x in range(W)) for y in range(H)]
    soil = [[X0 + x, Y0 + y, Z] for y in range(H) for x in range(W) if not (speck and x % 4 == 3 and y % 4 == 3)]
    return {"v": 2, "id": "s696", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z, X0 + W - 1, Y0 + H - 1, Z],
            "rows": {f"z{Z}": rows}, "marks": {"soil": soil}}


def _man() -> dict:
    return {"v": 2, "zones": {}, "edge": [], "rooms": [], "bridges": {}, "killboxes": [], "stairs": {}, "stations": {},
            "workshops": [], "depot": [X0 + 2, Y0 + 2, Z]}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap, man = _snap(), _man()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: man)
    yield d
    reset_paths()


def test_the_template_has_smaller_plots_for_a_surface_farm_only():
    assert rooms.PLOT_SIZES[0] == (5, 7) and rooms.PLOT_SIZES[3] == (3, 3)
    # the default is unchanged: two 5x7 plots, an 11 x 7 block
    assert rooms.plot_rects(check_params("farms", {"plots": 2, "surface": 1})) == [(0, 0, 4, 6, 0), (6, 0, 10, 6, 0)]
    # 3x3: plots at u 0-2 and 4-6, v 0-2; a second row at v 4-6
    p3 = check_params("farms", {"plots": 4, "surface": 1, "size": 3})
    assert rooms.plot_rects(p3) == [(0, 0, 2, 2, 0), (4, 0, 6, 2, 0), (0, 4, 2, 6, 0), (4, 4, 6, 6, 0)]
    doc = emit("farms", {"plots": 2, "surface": 1, "size": 3}, {"id": "S1", "anchor": [X0, Y0, Z], "rot": 0})
    assert schema.validate("bp", dict(doc, id="y431s0b0", site="S1")) == []
    assert doc["params"]["size"] == 3
    with pytest.raises(ValueError, match="surface"):
        emit("farms", {"plots": 1, "size": 3}, {"id": "S1", "anchor": [X0, Y0, Z - 3], "rot": 0})
    with pytest.raises(ValueError):
        check_params("farms", {"plots": 1, "surface": 1, "size": 5})


def test_a_small_plot_preview_has_no_simulation_errors():
    out = render.preview("farms", {"plots": 2, "surface": 1, "size": 3}, {"id": "S1", "anchor": [92, 87, Z], "rot": 1})
    assert "simulation errors" not in out, out


def test_speckled_soil_has_no_5x7_block_but_a_3x3_one():
    snap, man = _snap(), _man()
    assert sites.rank(snap, "farms", {"plots": 1, "surface": 1}, man) == []
    assert sites.rank(snap, "farms", {"plots": 1, "surface": 1, "size": 1}, man) == []
    assert sites.rank(snap, "farms", {"plots": 1, "surface": 1, "size": 2}, man) == []
    assert sites.rank(snap, "farms", {"plots": 1, "surface": 1, "size": 3}, man)
    two = sites.rank(snap, "farms", {"plots": 2, "surface": 1, "size": 3}, man)
    assert two and "plot tiles" in two[0]["why"]
    # solid soil: the 5x7 block is found as before
    assert sites.rank(_snap(False), "farms", {"plots": 1, "surface": 1}, man)


def test_the_refusal_counts_the_blocks_per_condition_and_names_the_size_that_fits(save):
    snap, man = _snap(), _man()
    msg = sites.farm_ground_why(snap, man, {"surface": 1})
    assert "no 5x7 plot block fits" in msg
    assert "blocks looked at" in msg and "no soil or mud" in msg, msg
    assert "a 3x3 plot fits in" in msg and "p.size=3" in msg, msg
    # the hint of `bp sites` / bp.place carries it
    assert "a 3x3 plot fits in" in cmd.farm_hint(save, "farms", {"surface": 1}, snap, 0)


def test_the_blocks_cut_by_the_forts_own_tiles_are_counted():
    snap, man = _snap(False), _man()
    man["rooms"] = [{"bbox": [X0, Y0, Z, X0 + W - 1, Y0 + H - 1, Z], "id": "r", "tpl": "workshops", "tier": 0, "use": "utility"}]
    msg = sites.farm_ground_why(snap, man, {"surface": 1})
    assert "overlap the fort's own tiles" in msg, msg


def test_smaller_plots_ladder_is_by_total_area():
    steps = cmd.smaller_plots("farms", {"surface": 1, "plots": 2})
    assert steps[0] == {"size": 1, "plots": 2}, steps                 # 2 x 5x4 = 40 tiles beats 2 x 4x4 = 32
    assert {"size": 3, "plots": 1} in steps and {"size": 4, "plots": 2} in steps
    areas = [o["plots"] * rooms.PLOT_SIZES[o["size"]][0] * rooms.PLOT_SIZES[o["size"]][1] for o in steps]
    assert areas == sorted(areas, reverse=True)
    assert cmd.smaller_plots("farms", {"plots": 2}) == []                 # a dug farm room keeps its plots
    assert cmd.smaller_plots("bedrooms", {"n": 4, "surface": 1}) == []
    assert [o["size"] for o in cmd.smaller_plots("farms", {"surface": 1, "plots": 1, "size": 3})] == [4]


def test_place_falls_back_to_smaller_plots_and_says_so(save):
    doc = cmd.place(save, "farms", {"surface": 1}, "S1", "f696")
    assert doc["params"]["surface"] == 1 and doc["params"]["size"] == 3
    note = cmd.PLACE_NOTES["f696"]
    assert "BUG-696" in note and "3x3" in note and "p.size=3" in note, note
    # the largest total area that has a site: 2 x 3x3 (a 7x3 block) beats 1 x 3x3
    assert doc["params"]["plots"] == 2, doc["params"]
    # a room farm (no surface) does not fall back
    with pytest.raises(cmd.BpError) as e:
        cmd.place(save, "farms", {}, "S1", "f696b")
    assert "BUG-696" not in str(e.value)
    k = cmd.smaller_plots_sites(save, "farms", {"surface": 1})
    assert k and k[0]["size"] == 3 and k[1]
    assert cmd.smaller_plots_sites(save, "farms", {"plots": 1}) is None


def test_place_with_no_fit_names_every_ladder(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = _snap()
    snap["marks"]["soil"] = [t for t in snap["marks"]["soil"] if (t[0] + t[1]) % 2]        # a chessboard: no 2x2 at all
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: _man())
    with pytest.raises(cmd.BpError) as e:
        cmd.place(d, "farms", {"surface": 1}, "S1", "f696c")
    assert "BUG-696" in str(e.value) and "BUG-316" in str(e.value)
    reset_paths()


def test_plan_farm_site_counts_smaller_plots_so_the_farm_command_stays(save, monkeypatch):
    from dfpilot import wake
    assert plan.farm_site(save, urgent=True) == "surface"
    d = {"id": "famine", "cmds": ['dfllm cmd bp.place \'{"tpl":"farms","site":"S1","p":{"surface":1}}\'']}
    cmds, dropped = wake.workable_food_cmds(d, save)
    assert any("farms" in c for c in cmds) and not dropped, (cmds, dropped)
    # no soil at all: the farm command is dropped as before
    empty = _snap()
    empty["marks"]["soil"] = []
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: empty)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: empty)
    assert plan.farm_site(save, urgent=True) == "none"
