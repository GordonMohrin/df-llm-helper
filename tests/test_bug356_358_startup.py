"""Run 16a-d (new forts, y372/373, 04.11.2026).
BUG-356: the first year hung on the fortcore in every new fort: 'Kueche/Still abgelehnt (Fortcore noch nicht gegraben)', drink
3 d -> 0 (i1), 'rooms open from the dug Z4 floor' (i3), workshops missing and 16 orders stuck (i4). `workshops surface=1`
is the startup set: Still, Kitchen, Carpenters, Masons on open surface floor beside the wagon, nothing dug, no door, no
burrow, no fort manifest needed; plan propose drafts it in year 1 beside the fortcore's stage 1.
BUG-358: three fortcore projects at once (i4), a plan's beside the one placed by hand (i1, i2): a second stage 1 is refused.
(BUG-357, the door that only a carpenter makes: tests/lua/test_bug357_door_shop.lua.)"""
from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
from cli_v2_helpers import RUNTIME, SAVE, make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema
from dfpilot.bp import rooms, sites

X0, Y0, Z = 100, 100, 130
W, H = 60, 40


def _snap(trees=(), far=()) -> dict:
    """60x40 open surface at z130 under open sky (z131 '_'), rock below; trees ('T') at `trees` tiles."""
    rows = [["." for _ in range(W)] for _ in range(H)]
    for x, y in trees:
        rows[y - Y0][x - X0] = "T"
    sky = ["_" * W for _ in range(H)]
    rock = ["#" * W for _ in range(H)]
    snap = {"v": 2, "id": "s356", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": rock, f"z{Z}": ["".join(r) for r in rows], f"z{Z + 1}": sky}, "marks": {}}
    if far:
        wg = [list("1" * W) for _ in range(H)]
        for x, y in far:
            wg[y - Y0][x - X0] = "0"
        snap["wg"] = {"home": 7, "rows": {f"z{Z}": ["".join(r) for r in wg]}}
    return snap


# ---------------------------------------------------------------- BUG-356: the template and its sites
def test_surface_workshops_default_to_the_four_startup_shops_and_dig_nothing():
    doc = bp.emit("workshops", {"surface": 1}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert [st["mode"] for st in doc["stages"]] == ["build"]
    assert sorted(w["type"] for w in doc["manifest"]["workshops"]) == ["Carpenters", "Kitchen", "Masons", "Still"]
    assert "zones" not in doc["manifest"] and not doc["manifest"].get("rooms")
    keys = {c[3] for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]}
    assert not keys & {"d", "a"}, keys                       # no doorway, no burrow paint
    assert schema.validate("bp", dict(doc, id="y1s0b2", site="S1")) == []
    assert bp.validate(dict(doc, id="y1s0b2")) == []
    # the plain template is unchanged: a dug room with a door and every moodable shop
    room = bp.emit("workshops", {}, {"id": "S1", "anchor": [110, 110, Z - 5], "rot": 0})
    assert [st["mode"] for st in room["stages"]][0] == "dig" and len(room["manifest"]["workshops"]) == 12


def test_surface_workshops_take_an_explicit_type_list_and_refuse_the_big_shops():
    doc = bp.emit("workshops", {"surface": 1, "skip": ",".join(n for n in rooms.MOODABLE_TYPES if n != "Masons"),
                                "add": "Still"}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert sorted(w["type"] for w in doc["manifest"]["workshops"]) == ["Masons", "Still"]
    with pytest.raises(ValueError, match="no 5x5 shops"):
        bp.emit("workshops", {"surface": 1, "add": "Kennels"}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})


def test_surface_sites_need_no_manifest_and_lie_on_open_flat_floor():
    snap = _snap()
    found = bp.rank(snap, "workshops", {"surface": 1}, n=3)           # no manifest: a room template would raise
    assert found and "open surface floor" in found[0]["why"]
    with pytest.raises(ValueError, match="zones.Z4"):
        bp.rank(snap, "workshops", {}, n=3)
    doc = bp.emit("workshops", {"surface": 1}, found[0])
    xs = [t for ch in doc["stages"][0]["chunks"] for t in [ch["pos"]]]
    assert all(p[2] == Z for p in xs)


def test_a_tree_in_the_block_moves_the_site():
    free = bp.rank(_snap(), "workshops", {"surface": 1}, n=1)[0]
    # trees on every tile of the best block's box: it must move
    box = sites._surface_shops(_snap(), rooms_checked({"surface": 1}), {})
    best = max(box, key=lambda c: c["score"])
    b = best["box"]
    trees = [(x, y) for x in range(b[0], b[3] + 1) for y in range(b[1], b[4] + 1)]
    moved = bp.rank(_snap(trees=trees), "workshops", {"surface": 1}, n=1)[0]
    assert moved["anchor"] != free["anchor"] or moved["rot"] != free["rot"]
    mb = sites._surface_shops(_snap(trees=trees), rooms_checked({"surface": 1}), {})
    assert all(not (c["box"][0] <= tx <= c["box"][3] and c["box"][1] <= ty <= c["box"][4]) for c in mb for tx, ty in trees[:1])


def rooms_checked(p):
    from dfpilot.bp.emit import check_params
    return check_params("workshops", p)


def test_the_site_follows_near_and_keeps_to_the_citizens_walk_group():
    snap = _snap()
    west = bp.rank(snap, "workshops", {"surface": 1}, n=1, near=[105, 110, Z], within=12)[0]
    east = bp.rank(snap, "workshops", {"surface": 1}, n=1, near=[150, 130, Z], within=12)[0]
    assert west["anchor"][0] < east["anchor"][0] - 20, (west, east)
    # another walk group: every tile of the west half is another group's
    far = [(x, y) for x in range(X0, X0 + 30) for y in range(Y0, Y0 + H)]
    only = bp.rank(_snap(far=far), "workshops", {"surface": 1}, n=3)
    assert only and all(s["anchor"][0] >= X0 + 28 for s in only), [s["anchor"] for s in only]
    assert all(s["walk"] == 7 for s in only)


def test_the_fortcore_keep_out_tiles_are_left_alone():
    man = {"v": 2, "edge": [[130, 120, Z]], "rooms": [], "workshops": []}
    for s in bp.rank(_snap(), "workshops", {"surface": 1}, manifest=man, n=3):
        b = sites._surface_shops(_snap(), rooms_checked({"surface": 1}), man)
        assert b
        box = next(c["box"] for c in b if c["anchor"] == s["anchor"] and c["rot"] == s["rot"])
        assert not (box[0] <= 132 and 128 <= box[3] and box[1] <= 122 and 118 <= box[4]), (s, box)


# ---------------------------------------------------------------- BUG-356: placing it beside the planned fortcore
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = _snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    yield d
    reset_paths()


def _core(save, pid, stage=1, anchor=(110, 105, Z), params=None, cancelled=False):
    doc = json.loads((RUNTIME / SAVE / "bp" / "y3s0b0.json").read_text("utf-8"))
    doc.update(id=pid, tpl="fortcore", site="S1", anchor=list(anchor), rot=0, params=params or {"stage": stage},
               manifest={"v": 2, "workshops": [{"type": "Still", "pos": [150, 100, Z - 4]},
                                               {"type": "Kitchen", "pos": [150, 104, Z - 4]}]})
    d = save / "bp" / (".cancelled" if cancelled else "")
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{pid}.json").write_text(json.dumps(doc), "utf-8")


def test_the_startup_shops_keep_still_and_kitchen_the_fortcore_plans_in_its_undug_core(save):
    _core(save, "c1a1a6a000000000aa")
    doc = cmd.emit_bp(save, "workshops", {"surface": 1}, "S1", "c1a1a6a000000000bb", write=False)
    assert sorted(w["type"] for w in doc["manifest"]["workshops"]) == ["Carpenters", "Kitchen", "Masons", "Still"]
    # `only` names the same set
    doc2 = cmd.emit_bp(save, "workshops", {"surface": 1, "only": "Still,Kitchen"}, "S1", "c1a1a6a000000000cc", write=False)
    assert sorted(w["type"] for w in doc2["manifest"]["workshops"]) == ["Kitchen", "Still"]
    # not on the fortcore's tiles
    from dfpilot.cmd import footprint
    assert not footprint(doc) & footprint(json.loads((save / "bp" / "c1a1a6a000000000aa.json").read_text("utf-8")))


def test_no_site_hint_for_the_startup_shops_does_not_send_the_player_to_the_fortcore():
    hint = cmd.no_site_hint(Path("."), "workshops", "s1", 0, [], {"surface": 1})
    assert "flat block of open surface floor" in hint and "Z4" not in hint


# ---------------------------------------------------------------- BUG-356: plan propose in year 1
def _p0_state(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P0"
    s["proj"] = []
    return s


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_year_one_drafts_the_startup_shops_beside_the_core_and_only_once(save):
    s = _p0_state(save)
    for fort in ({"z4": False, "core_any": False, "core_dig": False}, {"z4": False, "core_any": True, "core_dig": True}):
        doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set() if not fort["core_any"] else {("fortcore", 1)},
                           fort=fort)
        startup = [b for b in _builds(doc) if b["tpl"] == "workshops"]
        assert startup == [{"tpl": "workshops", "site": "S1", "p": {"surface": 1}}], _builds(doc)
        assert "BUG-356" in doc["notes"] and schema.validate("plan", doc) == []
        assert plan.build_kind(startup[0]) == "supply"            # no open seal pauses the first year's drink
    again = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)},
                         fort={"z4": False, "core_any": True, "core_dig": True, "startup": True})
    assert all(b["tpl"] != "workshops" for b in _builds(again))
    # a dug floor: the usual draft, no startup set
    full = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)},
                        fort={"z4": True, "core_any": True, "core_dig": False, "startup": False})
    assert not any((b.get("p") or {}).get("surface") == 1 for b in _builds(full))


def test_startup_placed_sees_a_surface_workshops_project(save):
    assert plan.startup_placed(save) is False
    doc = cmd.emit_bp(save, "workshops", {"surface": 1}, "S1", "c1a1a6a000000000dd", write=True)
    assert plan.startup_placed(save) is True
    assert doc["params"]["surface"] == 1


# ---------------------------------------------------------------- BUG-358: one fortcore
def test_a_second_fortcore_stage_one_is_refused_and_the_message_names_the_first(save):
    _core(save, "c1a1a6a000000000aa", anchor=(110, 105, Z))
    for label in ("S1", "A140_120_130_0"):
        with pytest.raises(cmd.BpError) as e:
            cmd.emit_bp(save, "fortcore", {"stage": 1}, label, "y372s0b0", write=False, snap=_snap())
        m = str(e.value)
        assert "c1a1a6a000000000aa" in m and "bp.cancel" in m and "[110, 105, 130]" in m, m


def test_other_stages_retrofit_and_the_same_project_are_not_refused(save):
    _core(save, "c1a1a6a000000000aa", anchor=(110, 105, Z))
    # stage 2 at the stage 1 anchor ('same'): the way the plan builds a core
    doc = cmd.emit_bp(save, "fortcore", {"stage": 2}, "same", "y372s0b1", write=False)
    assert doc["params"]["stage"] == 2
    assert cmd.first_core(save, skip="c1a1a6a000000000aa") is None            # re-placing itself
    # a retrofit is no second core
    _core(save, "c1a1a6a000000000ab", params={"stage": 1, "retrofit": 1}, anchor=(120, 120, Z))
    assert cmd.first_core(save)[0] == "c1a1a6a000000000aa"


def test_a_cancelled_core_is_no_core(save):
    _core(save, "c1a1a6a000000000aa", cancelled=True)
    assert cmd.first_core(save) is None
    doc = cmd.emit_bp(save, "fortcore", {"stage": 1}, "S1", "y372s0b0", write=False, snap=_snap())
    assert doc["tpl"] == "fortcore"
