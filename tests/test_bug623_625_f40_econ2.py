"""Round 40 (economy leftovers; offline, live-untested): BUG-623 (a finished hospital project holds its own room: `hospital furnish=1`
is placed inside it), BUG-624 (flux in trade.want when the smelter lacks it), BUG-625 (explore says which rock each depth shows, and
looks further when the near probes found only soft rock). The Lua parts: tests/lua/test_economy_reach.lua,
tests/lua/test_water_m1.lua (BUG-623 command in the hospital_supply DECISION)."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths
from test_bug581_585_f37_econ import Z, _man, _snap

from dfpilot import bp, cmd, files, plan, wake


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    (d / "events.1.jsonl").unlink(missing_ok=True)
    box = {"snap": _snap(), "man": _man()}
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    yield d, box
    reset_paths()


def _room(save, pid="y373s2b1"):
    """The hospital room project (the older template), finished: its room is the manifest's hospital room."""
    doc = bp.emit("hospital", {}, {"id": "S1", "anchor": [95, 100, Z], "rot": 0})
    doc = dict(doc, id=pid)
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc))
    n = files.last_event_n(save) + 50
    append_events(save, [ev(n, "PROJECT_DONE", "", {"proj": pid}, tick=1)])
    return doc


# ---------------------------------------------------------------- BUG-623
def test_furnish_is_placed_inside_the_finished_hospital_room(world):
    save, _ = world
    _room(save)
    doc = cmd.place(save, "hospital", {"furnish": 1}, "S1", "y428s0b9")
    x, y, z = doc["anchor"]
    assert 95 <= x <= 101 and 101 <= y <= 105 and z == Z, doc["anchor"]
    assert [c[3] for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]] == ["t"]


def test_the_room_project_still_holds_other_templates_but_a_second_furnish_holds_its_tile(world):
    save, _ = world
    _room(save)
    first = cmd.place(save, "hospital", {"furnish": 1}, "S1", "y428s0b9")
    (save / "bp" / "y428s0b9.json").write_text(json.dumps(dict(first, id="y428s0b9")))
    occ = cmd.occupancy(save)
    assert "y428s0b9" in occ.furnish and "y373s2b1" not in occ.furnish
    again = bp.emit("hospital", {"furnish": 1}, {"id": "S0", "anchor": first["anchor"], "rot": 0})
    assert occ.clash(again) == ["y428s0b9"], "a second table on the same tile is held by the first furnish project"
    plain = bp.emit("hospital", {}, {"id": "S0", "anchor": [96, 102, Z], "rot": 0})
    assert "y373s2b1" in occ.clash(plain), "a whole hospital on the room is still held by the room's project"


def test_a_finished_holder_is_not_called_not_begun(world):
    save, _ = world
    _room(save)
    assert cmd._planned_only(save, "y373s2b1", "hospital") is False
    _ = files  # the project has no kernel row and a PROJECT_DONE: finished, no planned slot to cancel
    (save / "bp" / "y999s0b0.json").write_text(json.dumps({"tpl": "hospital", "anchor": [1, 1, Z], "rot": 0, "params": {}, "id": "y999s0b0"}))
    assert cmd._planned_only(save, "y999s0b0", "hospital") is True


def test_the_wake_line_names_the_furnish_command():
    d = {"id": "hospital_supply", "q": "hospital with 1 patient(s) lacks a table", "gaps": ["no_table"],
         "cmds": ['dfllm cmd bp.place \'{"tpl":"hospital","site":"S1","p":{"furnish":1}}\'']}
    line = wake.hospital_supply_hint(d)
    assert "furnish" in line and "build it inside" not in line, line



# ---------------------------------------------------------------- BUG-625
def test_the_explore_message_names_what_met_the_shaft_and_on_which_level():
    from dfpilot.bp import sites
    p = {"depth": 2, "arm": 0}
    geo = {(136, "open", 0): 268, (139, "open", -2): 85}
    msg = sites._explore_none(p, set(), [], (1205, 0, 0, 0, 353), geo)
    assert "level(s) z136, z139" in msg and "268 anchor(s) of z136: an open or built tile on the anchor level" in msg, msg
    assert "85 anchor(s) of z139: an open or built tile 2 level(s) below it (z137)" in msg, msg
    assert "BUG-625" not in sites._explore_none(p, set(), [], (1205, 0, 0, 0, 353)), "no geo: the old text"


def test_fail_why_names_the_first_refusal():
    from dfpilot.bp import mine, sites
    snap = _snap()
    bad = sites._Pref(snap, lambda c: c not in sites.GOOD)
    mk = sites._Pref(snap, points=[])
    rects = sites.explore_rects({"depth": 2, "arm": 0, "every": 3, "avoid": ""})
    assert mine.PARAMS["explore"]["arm"][0] == 6
    # the door row of an anchor at 96,100 lies in the room's floor (y 101): an open tile on the anchor level
    assert sites._fail_why(rects, 96, 100, Z, 0, bad, mk, None) == ("open", 0)
    # an anchor deep in the rock: nothing refuses (levels below the snapshot are unknown, allowed)
    assert sites._fail_why(rects, 105, 115, Z, 0, bad, mk, None) is None


def test_explore_rocks_per_depth_from_the_finished_probes(world):
    save, _ = world
    n = files.last_event_n(save) + 50
    append_events(save, [
        ev(n, "PROJECT_DONE", "", {"proj": "y428s0b0", "tpl": "explore",
                                   "rocks": ["LOAMY_SAND z139", "MUDSTONE z138-z134", "CLAYSTONE z133-z131", "LIMESTONE z130"]}, tick=1),
        ev(n + 1, "PROJECT_DONE", "", {"proj": "y429s0b0", "tpl": "explore", "rocks": ["LOAMY_SAND z139", "MUDSTONE z138-z137"]}, tick=2),
        ev(n + 2, "PROJECT_DONE", "", {"proj": "y430s0b0", "tpl": "seal", "rocks": ["GRANITE z1"]}, tick=3)])
    rocks = cmd.explore_rocks(save)
    assert rocks["MUDSTONE"] == [134, 138, 2] and rocks["LIMESTONE"] == [130, 130, 1] and "GRANITE" not in rocks, rocks
    note = cmd.explore_rock_note(save)
    assert "MUDSTONE z134-z138" in note and "none went below z130" in note, note
    assert "flux stone seen: LIMESTONE z130" in note, note
    assert cmd.explore_rock_note(save / "nowhere") == ""


def test_a_failed_explore_ranking_carries_the_rock_note(world, monkeypatch):
    save, _ = world
    n = files.last_event_n(save) + 50
    append_events(save, [ev(n, "PROJECT_DONE", "", {"proj": "y428s0b0", "tpl": "explore", "rocks": ["MUDSTONE z138-z134"]}, tick=1)])

    def boom(*a, **k):
        raise cmd.BpError("bp.sites.rank(explore): explore: no site at depth 2 arm 0; no free rock [1 anchor tile(s)]")
    monkeypatch.setattr(cmd, "_rank", boom)
    monkeypatch.setattr(cmd, "water_ctx", lambda *a, **k: None)
    with pytest.raises(cmd.BpError) as e:
        cmd.rank_sites(save, "explore", {"depth": 2})
    assert "explore: no site at depth 2" in str(e.value) and "the finished probes saw" in str(e.value) and "MUDSTONE z134-z138" in str(e.value)


def test_fit_explore_says_why_when_no_depth_has_a_site(world, monkeypatch):
    import copy
    save, _ = world
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [{"tpl": "explore", "site": "S1"}]}, {"build": []}, {"build": []}, {"build": []}]
    doc["notes"] = ""

    def rank(save_dir, tpl, params=None, snap=None, n=3, manifest=None):
        raise cmd.BpError("rank explore: explore: no site at depth 2 arm 0; no free rock [1205 anchor tile(s)] [BUG-625: explore starts only "
                          "from the public floor of the core, level(s) z136, z139; the shaft was refused by: 268 anchor(s) of z136: an open "
                          "or built tile on the anchor level]; the finished probes saw (PROJECT_DONE rocks): MUDSTONE z134-z138; none went "
                          "below z134; no flux stone and no ore seen: trade.want ore, bars, flux")
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_running", lambda *a, **k: [])
    line = plan.fit_explore(save, doc, prev)
    assert line.startswith("explore: no site at depth 2..12: not drafted (") and "268 anchor(s) of z136" in line, line
    assert "the finished probes saw (PROJECT_DONE rocks): MUDSTONE" in line and "268 anchor(s)" in doc["notes"]
