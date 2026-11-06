"""Round 33 (misc): BUG-536 `plan propose` drafts a depot again once the old one was toppled (and a parked one never counts), BUG-538
`seal at=last` never offers a hatch on a stair no builder can reach. (The Lua sides: tests/lua/test_bug535_gem_forms.lua,
test_bug536_538_runner.lua, test_water.lua, test_water_m1.lua.)"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths       # noqa: E402

from dfpilot import bp, cmd, files, plan, wake                                      # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _bp(save, pid, doc):
    (save / "bp").mkdir(parents=True, exist_ok=True)
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), encoding="utf-8")


def _events(save, evs):
    p = save / "events.jsonl"
    if not p.exists():
        p.write_text("", encoding="utf-8")
    append_events(save, evs)


# ---------------------------------------------------------------- BUG-536
def test_a_finished_depot_that_was_toppled_is_no_depot(save, monkeypatch):
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: {"v": 2, "depot": [84, 78, 139]})
    _bp(save, "y380s1b0", {"tpl": "depot", "id": "y380s1b0", "anchor": [82, 76, 139], "params": {}})
    _events(save, [ev(10, "PROJECT_DONE", "done", {"proj": "y380s1b0", "tpl": "depot"})])
    assert plan.depot_lost(save) is False
    assert plan.depot_planned(save, None) is True
    _events(save, [ev(20, "BUILDING_TOPPLED", "Trade Depot toppled", {"what": "Trade Depot", "by": "a cave dragon", "pos": [84, 78, 139]})])
    assert plan.depot_lost(save) is True
    assert plan.depot_planned(save, None) is False, "old: the manifest and the finished project said a depot stood"
    fort = plan.fort_facts(save, files.read_state(save))
    assert fort["depot"] is False and fort["depot_lost"] is True


def test_a_depot_project_that_runs_counts_a_parked_one_does_not(save, monkeypatch):
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: {"v": 2})
    _bp(save, "y389s0b2", {"tpl": "depot", "id": "y389s0b2", "anchor": [65, 74, 141], "params": {}})
    _events(save, [ev(30, "DEPOT_MISSING", "caravan and no trade depot stands", {"civ": "x"})])
    assert plan.depot_lost(save) is True
    assert plan.depot_planned(save, None) is True, "placed and running: a second one would double it"
    parked = {"proj": [["y389s0b2", "build", 0, "parked: build_lost"]]}
    assert plan.depot_planned(save, parked) is False, "parked for good (build_lost spent): nothing stands on it"
    assert plan._parked_ids(parked) == {"y389s0b2"}
    _events(save, [ev(40, "PROJECT_DONE", "done", {"proj": "y389s0b2", "tpl": "depot"})])
    assert plan.depot_lost(save) is False, "a depot finished after the loss"


def test_propose_drafts_the_depot_again_with_the_reason(save):
    full = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": False, "depot_lost": True,
            "trade_pile": True}
    s = files.read_state(save)
    s["phase"] = "P0"
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)}, fort=full)
    tpls = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
    assert "depot" in tpls, tpls
    assert "BUG-536" in doc["notes"] and "toppled" in doc["notes"], doc["notes"]


# ---------------------------------------------------------------- BUG-538
# z0 the walled-in stair level, z1 a room level with a floor beside the stair, z2 the same stair walled again
BOX = ["###", "#X#", "###"]
ROOM = ["...", ".X.", "..."]


def put_snap(save, levels, tick=100):
    s = {**tiny(levels), "id": f"s{tick}", "tick": tick, "purpose": "sites"}
    files.write_json_atomic(save / "snap" / f"{s['id']}.json", s)


def put_ents(save, ents, utick=5000):
    e = {"n": 7, "tick": utick, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready",
         "d": {"fails": ["open_perimeter"], "routes": len(ents), "open": len(ents), "ents": ents, "traps": 0}}
    (save / "events.jsonl").write_text(json.dumps(e) + "\n", encoding="utf-8")


def test_stair_piece_reads_the_eight_neighbours_and_the_levels_above():
    s = tiny([BOX, ROOM])
    assert cmd.stair_piece(s, 1, 1, 1) == ("ok",)
    assert cmd.stair_piece(s, 1, 1, 0) == ("moved", 1, "stair_updown")
    wall = ["###", "###", "###"]
    assert cmd.stair_piece(tiny([BOX, BOX, wall]), 1, 1, 0) == ("boxed",)
    assert cmd.stair_piece(tiny([BOX, BOX]), 1, 1, 0) == ("ok",), "the snapshot ends above it: unknown, as given"
    assert cmd.stair_piece(tiny([BOX, ["###", "#+#", "###"]]), 1, 1, 0) == ("closed", 1)
    assert cmd.stair_piece(tiny([BOX, ["???", "?X?", "???"]]), 1, 1, 0) == ("ok",), "a hidden level: unknown, as given"


def test_seal_at_last_moves_a_hatch_off_a_walled_in_stair_up_the_same_stair(save):
    put_snap(save, [BOX, ROOM, ["###", "###", "###"]])
    put_ents(save, ["1,1,0 stair_updown"])
    at, notes = cmd.seal_openings(save, "last")
    assert at.startswith("1,1,1 stair_updown"), at
    assert any("walled in on its level" in n and "hatch moved to 1,1,1" in n for n in notes), notes


def test_seal_at_last_leaves_out_a_stair_walled_in_on_every_level(save):
    put_snap(save, [BOX, BOX, ["###", "###", "###"]])
    put_ents(save, ["1,1,0 stair_updown"])
    with pytest.raises(cmd.SealClosed, match="no builder can reach a hatch there"):
        cmd.seal_openings(save, "last")


def test_a_named_tile_is_taken_as_given(save):
    put_snap(save, [BOX, BOX, ["###", "###", "###"]])
    put_ents(save, [])
    at, _ = cmd.seal_openings(save, "1,1,0 stair_updown")
    assert at.startswith("1,1,0 stair_updown"), at


def test_hospital_supply_wake_line_names_the_gaps_and_the_first_command():
    d = {"id": "hospital_supply", "q": "hospital with 2 patient(s) lacks splints", "gaps": ["no_table", "no_splints"],
         "cmds": ["dfllm cmd order.add '{\"job\":\"ConstructSplint\",\"amount\":4}'"]}
    assert "ConstructSplint" in wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "no_table, no_splints" in wake.hospital_supply_hint(d)
    assert "ConstructSplint" in wake.hospital_supply_hint(d) and "decide yourself" in wake.hospital_supply_hint(d)
