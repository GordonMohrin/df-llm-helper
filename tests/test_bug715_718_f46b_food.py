"""BUG-717 (Run 16c i3 Doorwings y377-y380, Wallfree y387-y432: 'farms: room sites need manifest zones.Z4', no plot for 68 seeds, no brewing, food 0 in the
winters): a farms room needs the dug Z4 floor of a fortcore; the plots stand on soil anywhere on the citizens' walk group (BUG-407). bp.place farms falls
back to them when the room has no site (no Z4, no soil level, no free place), and the refusal names both reasons.
BUG-718 (the decision that offers only what is refused): the wake line says 'NO FOOD SOURCE POSSIBLE' when the farm command is dropped and nothing that makes
food is left. (BUG-715 / BUG-716 are Lua: tests/lua/test_bug715_718_food.lua.)"""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, plan, wake

X0, Y0, Z = 300, 300, 148
W, H = 40, 30


def _snap(soil=True) -> dict:
    rows = ["." * W for _ in range(H)]
    marks = [[X0 + x, Y0 + y, Z] for y in range(H) for x in range(W)] if soil else []
    return {"v": 2, "id": "s717", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z, X0 + W - 1, Y0 + H - 1, Z],
            "rows": {f"z{Z}": rows}, "marks": {"soil": marks}}


def _man(z4=False) -> dict:
    zones = {"Z4": [[X0 + 1, Y0 + 1, Z - 3, X0 + 6, Y0 + 6, Z - 1]]} if z4 else {}
    return {"v": 2, "zones": zones, "edge": [], "rooms": [], "bridges": {}, "killboxes": [], "stairs": {}, "stations": {},
            "workshops": [], "depot": [X0 + 2, Y0 + 2, Z]}


@pytest.fixture(autouse=True)
def _surface_core_on(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: True)


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    yield d
    reset_paths()


def _fort(monkeypatch, snap, man):
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: man)


def test_farm_alt_is_for_a_farms_room_only():
    assert cmd.farm_alt("farms", {"plots": 2}) == {"plots": 2, "surface": 1}
    assert cmd.farm_alt("farms", {"surface": 1}) is None, "the surface variant is already asked for"
    assert cmd.farm_alt("bedrooms", {}) is None
    assert cmd.farm_alt("tombs", None) is None


def test_a_farms_room_without_a_z4_is_placed_on_soil_elsewhere(save, monkeypatch):
    snap = _snap()
    _fort(monkeypatch, snap, _man(z4=False))
    doc = cmd.place(save, "farms", {"plots": 1}, "S1", "y377s0b9", snap=snap, any_soil=True)
    assert doc["params"].get("surface") == 1
    assert cmd.PLACE_NOTES["y377s0b9"].startswith("BUG-717")


def test_a_fortcore_coming_does_not_hold_the_farm_back(save, monkeypatch):
    snap = _snap()
    _fort(monkeypatch, snap, _man(z4=False))
    monkeypatch.setattr(cmd, "first_core", lambda _d, skip="": ("c1", [310, 310, Z]))
    doc = cmd.place(save, "farms", {"plots": 1}, "S1", "y377s0b8", snap=snap, any_soil=True)
    assert doc["params"].get("surface") == 1, "food does not wait for the dig (a bedroom would)"


def test_a_z4_with_no_soil_level_falls_back_too_and_smaller_plots_still_apply(save, monkeypatch):
    snap = _snap()
    snap["marks"]["soil"] = [t for t in snap["marks"]["soil"] if not (t[0] % 4 == 3 and t[1] % 4 == 3)]      # speckled ground (BUG-696)
    _fort(monkeypatch, snap, _man(z4=True))
    doc = cmd.place(save, "farms", {"plots": 2}, "S1", "y377s0b7", snap=snap, any_soil=True)
    assert doc["params"].get("surface") == 1 and doc["params"].get("size", 0) > 0, doc["params"]
    note = cmd.PLACE_NOTES["y377s0b7"]
    assert note.startswith("BUG-717") and "BUG-696" in note, note


def test_no_soil_at_all_the_refusal_names_both_reasons(save, monkeypatch):
    snap = _snap(soil=False)
    _fort(monkeypatch, snap, _man(z4=False))
    with pytest.raises(cmd.BpError) as ei:
        cmd.place(save, "farms", {"plots": 1}, "S1", "y377s0b6", snap=snap, any_soil=True)
    msg = str(ei.value)
    assert "Z4" in msg and "BUG-717" in msg and "no soil and no mud floor" in msg, msg


def test_the_ranking_error_without_z4_says_a_farm_needs_none(save, monkeypatch):
    from dfpilot.bp import sites
    with pytest.raises(ValueError) as ei:
        sites.rank(_snap(), "farms", {}, {"v": 2})
    assert "BUG-717" in str(ei.value) and "surface=1" in str(ei.value)
    with pytest.raises(ValueError) as ej:
        sites.rank(_snap(), "bedrooms", {}, {"v": 2})
    assert "BUG-717" not in str(ej.value), "only farms"


def _put_mode(save, mode):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc["mode"] = mode
        p.write_text(json.dumps(doc), encoding="utf-8")


def test_a_hand_command_in_peace_falls_back_but_follow_and_other_modes_keep_the_error(save, monkeypatch):
    snap = _snap()
    _fort(monkeypatch, snap, _man(z4=False))
    args = {"tpl": "farms", "site": "S1", "p": {"plots": 1}}
    with pytest.raises(cmd.BpError):                                  # the plan check / follow path: no fallback of its own
        cmd.place(save, "farms", {"plots": 1}, "S1", "y377s0b5", snap=snap)
    _put_mode(save, "ALERT")
    with pytest.raises(cmd.BpError):
        cmd.send(save, "bp.place", dict(args), by="cli", wait_s=0, snap=snap)
    _put_mode(save, "PEACE")
    with pytest.raises(cmd.BpError):
        cmd.send(save, "bp.place", dict(args), by="follow", wait_s=0, snap=snap)
    cid, _ = cmd.send(save, "bp.place", dict(args), by="cli", wait_s=0, snap=snap)
    doc = json.loads((save / "bp" / f"{cid}.json").read_text("utf-8"))
    assert doc["params"].get("surface") == 1 and cmd.PLACE_NOTES[cid].startswith("BUG-717")


FARM = "dfllm cmd bp.place '{\"tpl\":\"farms\",\"site\":\"S1\",\"p\":{\"surface\":1}}'"
SITES = "dfllm bp sites farms surface=1 --near 94,51,146 --within 12 --fresh"


def test_the_famine_line_says_no_source_possible_when_only_the_caravan_is_left(monkeypatch, tmp_path):
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "none")
    d = {"id": "famine", "q": "food 29 d", "cmds": [FARM, SITES], "auto": ["gatherers", "fishers"]}
    h = wake.food_hint(d, tmp_path)
    assert "NO FOOD SOURCE POSSIBLE" in h and "no farm site" in h and "trade.want" in h, h
    assert "gatherers, fishers" in h and "do not retry" in h
    assert "tell Gordon, send the option he picks" not in h, "the old line promised an option that cannot work"


def test_with_a_source_left_the_old_line_stays(monkeypatch, tmp_path):
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "none")
    butcher = "dfllm cmd butcher.mark '{\"n\":2}'"
    d = {"id": "famine", "cmds": [FARM, butcher], "opts": ["farms", "butcher"]}
    h = wake.food_hint(d, tmp_path)
    assert "NO FOOD SOURCE POSSIBLE" not in h and butcher in h, h
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "surface")
    d2 = {"id": "famine", "cmds": [FARM]}
    h2 = wake.food_hint(d2, tmp_path)
    assert "NO FOOD SOURCE POSSIBLE" not in h2 and FARM in h2, "a farm site stands: the farm command is the option"
    assert wake.no_source_note({"id": "famine"}, [], []) == "", "nothing dropped: no claim"
    json.dumps(h)
