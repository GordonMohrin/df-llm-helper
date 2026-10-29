"""BUG-316 (Run 15c Inkintense, live): `cmd bp.place tpl=farms site=S1 plots=1 surface=1` and `plan check` with that build
failed with `[92, 87, 133]: bp.emit(farms): min() iterable argument is empty` (emit put every room template into Z4 by
the bbox of its dug tiles; a surface farm digs nothing); at the default plots=2 (and plots=4) `bp sites farms surface=1`
ranked 0 because trees cut every 11-wide block on the surface by the entrance, and nothing fell back to fewer plots; plan
propose drafted farms p.surface=1 at the default plots that had no site. The snapshot below has the live shape: the
entrance level z133 under open sky, revealed soil floor with trees ('T') standing in it, the entrance (manifest edge) on
that level. Every test but the ranking guard fails on 9ef2ccb."""
from __future__ import annotations

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, plan, schema
from dfpilot.bp import render, sites
from dfpilot.bp.emit import emit

X0, Y0, Z = 300, 300, 133
EDGE = [320, 315, Z]


def _snap() -> dict:
    """40x30 soil floor at z133, trees ('T') every third tile but in a 6x8 clearing (x 306-311, y 306-313) and along
    the entrance row: one 5x7 plot fits in the clearing, an 11-wide block of two plots (or a 7-wide rotated plot) never
    does, as on Inkintense's surface."""
    w, h = 40, 30

    def c(x, y):
        clear = 6 <= x <= 11 and 6 <= y <= 13 or y == EDGE[1] - Y0
        return "." if clear or (x + y) % 3 else "T"
    rows = ["".join(c(x, y) for x in range(w)) for y in range(h)]
    soil = [[X0 + x, Y0 + y, Z] for y in range(h) for x in range(w) if rows[y][x] == "."]
    return {"v": 2, "id": "s316", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z, X0 + w - 1, Y0 + h - 1, Z],
            "rows": {f"z{Z}": rows}, "marks": {"soil": soil}}


def _man() -> dict:
    return {"v": 2, "zones": {"Z4": [[X0, Y0, Z - 3, X0 + 5, Y0 + 5, Z - 3]]}, "edge": [EDGE], "rooms": [],
            "bridges": {}, "killboxes": [], "stairs": {}, "stations": {}, "workshops": []}


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


def test_bug316_emit_surface_farm_at_the_live_site():
    doc = emit("farms", {"plots": 1, "surface": 1}, {"id": "S1", "anchor": [92, 87, 133], "rot": 1})
    assert [st["mode"] for st in doc["stages"]] == ["build"]
    assert "Z4" not in (doc["manifest"].get("zones") or {}), "a surface farm digs no rock: it joins no fort core"
    assert doc["manifest"]["rooms"][0]["tpl"] == "farms"
    full = dict(doc, id="y377s0b3", site="S1")
    assert schema.validate("bp", full) == []
    # a dug room farm still joins Z4 (unchanged)
    room = emit("farms", {"plots": 1}, {"id": "S1", "anchor": [92, 87, 120], "rot": 0})
    assert room["manifest"]["zones"]["Z4"]


def test_bug316_preview_of_a_surface_farm_has_no_simulation_errors():
    out = render.preview("farms", {"plots": 2, "surface": 1}, {"id": "S1", "anchor": [92, 87, 133], "rot": 1})
    assert "simulation errors" not in out, out
    assert out.count("p") >= 70


def test_bug316_trees_cut_the_two_plot_block_one_plot_fits():
    snap, man = _snap(), _man()
    assert sites.rank(snap, "farms", {"plots": 2, "surface": 1}, man) == []
    one = sites.rank(snap, "farms", {"plots": 1, "surface": 1}, man)
    assert one and all(s["rot"] in (0, 2) and 306 <= s["anchor"][0] <= 311 and 306 <= s["anchor"][1] <= 313
                       for s in one), one


def test_bug316_place_falls_back_to_fewer_plots_and_says_so(save):
    doc = cmd.place(save, "farms", {"surface": 1}, "S1", "f316")
    assert doc["params"]["plots"] == 1 and doc["params"]["surface"] == 1
    assert "plots=2" in cmd.PLACE_NOTES["f316"] and "placed plots=1" in cmd.PLACE_NOTES["f316"]
    doc4 = cmd.place(save, "farms", {"surface": 1, "plots": 4}, "S1", "f316b")
    assert doc4["params"]["plots"] == 1 and "plots=4" in cmd.PLACE_NOTES["f316b"]
    # a room farm (no surface) does not fall back; an explicit plots=1 that fits carries no note
    with pytest.raises(cmd.BpError) as e:
        cmd.place(save, "farms", {}, "S1", "f316c")
    assert "BUG-316" not in str(e.value)
    cmd.place(save, "farms", {"surface": 1, "plots": 1}, "S1", "f316d")
    assert "f316d" not in cmd.PLACE_NOTES
    k, free, _, _ = cmd.fewer_plots_sites(save, "farms", {"surface": 1})
    assert k == 1 and free
    assert cmd.fewer_plots_sites(save, "farms", {"surface": 1, "plots": 1}) is None
    assert cmd.fewer_plots("bedrooms", {"n": 4}) == [] and cmd.fewer_plots("farms", {"plots": 3, "surface": 1}) == [2, 1]


def test_bug316_food_draft_uses_the_plots_that_have_a_site(save):
    state = {"t": {"y": 377, "season": 0}, "mode": "PEACE", "stock": {"food_d": 21, "drink_d": 200}}
    ff = plan.farm_facts(save, state)
    assert ff["site"] == "surface" and ff["plots"] == 1, ff
    b, note = plan.food_draft(state, {"farms": ff}, [], None)
    assert b == {"tpl": "farms", "site": "S1", "p": {"surface": 1, "plots": 1}}
    assert "p.surface=1 p.plots=1" in note and "BUG-316" in note
    # the drafted build passes the placement plan check runs
    doc = cmd.place(save, b["tpl"], b["p"], b["site"], "y377s0b9")
    assert doc["params"]["plots"] == 1
