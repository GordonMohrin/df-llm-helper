"""Round 43 (seal): BUG-657 the phantom seal of a hatch on a HIDDEN tile (Lua: tests/lua/test_bug657_hidden_phantom.lua; here the plan side:
the phantom record does not age out in two years), BUG-658 an audit bypass wall on a tile no seal can be built on (a fortcore tile, a
tile of a finished seal) is not named, and `plan check` says why instead of 'seal project  builds the wall'. (The hospital furnish ERROR of Trumpetrealms y437-y441 is BUG-640, in the
base since Round 41; the last test here runs the drafted row through the whole check. BUG-659 and BUG-660 are not used.)"""
import copy
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths        # noqa: E402

from dfpilot import bp, cmd, files, plan, schema                               # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    yield d
    reset_paths()


# ---------------------------------------------------------------- BUG-657
MAN = {"v": 2, "refuge": {"anchor": [67, 46, 138], "burrow": "Tiefe+"}, "stairs": {"civ": [[67, 44, 138, 141]]},
       "zones": {"Z4": [[60, 40, 136, 75, 50, 141]]}}


def test_a_phantom_record_of_a_hidden_hatch_tile_counts_for_years(save, monkeypatch):
    """Wallfree y400-y404: the kernel cancels the seal of the hidden tile 67,44,139 ('x,y,z ?'); five game years later the plan must not
    draft the refuge hatch again (old window 2 years: the seal came back every year)."""
    files.write_json_atomic(save / "manifest.json", MAN)
    for p in (save / "snap").glob("*.json"):
        p.unlink()
    year = schema.TICKS["YEAR"]
    monkeypatch.setattr(files, "current_tick", lambda sd: 10 * year)
    append_events(save, [ev(files.last_event_n(save) + 1, "PROJECT_BLOCKED", "y400s0b0 (seal) cancelled: 67,44,139 ? is solid rock or never revealed",
                            {"proj": "y400s0b0", "tpl": "seal", "stage": "seal.build", "why": "build_lost", "ticks": 5,
                             "phantom": ["67,44,139 ?"]}, tick=5 * year)])
    assert cmd.phantom_tiles(save) == {"67,44,139"}
    rs = cmd.refuge_stair(save)
    assert (rs["state"], rs["head"]) == ("nostair", None), rs


# ---------------------------------------------------------------- BUG-658
def _corridor():
    """The edge tile 1,1,0 over the corridor 1..5,1 to the core tile 5,1,0; the trap hall lies on the other way (row 3)."""
    z0 = ["#######", "#.....#", "#######", "......#", "#######"]
    snap = tiny([z0])
    snap["traps"] = [[3, 3, 0, "W", 3, 1], [4, 3, 0, "W", 3, 1]]
    man = {"v": 2, "zones": {"Z2": [[3, 3, 0, 4, 3, 0]], "Z4": [[5, 1, 0, 5, 1, 0], [5, 3, 0, 5, 3, 0]]},
           "edge": [[1, 1, 0], [0, 3, 0]]}
    return snap, man


def _wall(res):
    fs = [f for f in res["fails"] if f.startswith("bypass: wall")]
    assert fs, res["fails"]
    return tuple(int(x) for x in fs[0].split("wall ")[1].split(" ")[0].split(","))


def test_the_audit_names_the_next_tile_when_the_first_lies_where_no_seal_is_built():
    snap, man = _corridor()
    first = _wall(bp.audit(snap, man))
    res = bp.audit(snap, man, avoid={first})
    second = _wall(res)
    assert second != first and second[1] == 1, (first, second)                     # old: the same tile in every audit, for years
    assert res["min_traps"] == bp.audit(snap, man)["min_traps"], "the traps count still assumes the route shut"


def test_every_tile_of_the_route_avoided_names_no_wall_but_the_route():
    snap, man = _corridor()
    avoid = {(x, 1, 0) for x in range(0, 7)}
    res = bp.audit(snap, man, avoid=avoid)
    assert res["bypass"] is True
    assert not [f for f in res["fails"] if f.startswith("bypass: wall")], res["fails"]
    assert [f for f in res["fails"] if f.startswith("bypass:")], res["fails"]       # the finding stays, without a tile no seal can take


def test_audit_avoid_holds_the_fortcore_footprint_and_the_tiles_of_a_finished_seal(save, monkeypatch):
    pid = "c1a1ac00000000001"
    files.write_json_atomic(save / "bp" / f"{pid}.json", {
        "tpl": "seal", "params": {"at": "6,2,0 floor wall"}, "anchor": [6, 2, 0], "rot": 0, "v": 2, "class": "defense", "site": "S1",
        "stages": [], "manifest": {"v": 2}, "materials": {}})
    monkeypatch.setattr(cmd, "core_cells", lambda sd: {(89, 100, 139): "y372s0b0"})
    n = files.last_event_n(save) + 1
    append_events(save, [ev(n, "PROJECT_DONE", "seal done", {"proj": pid, "tpl": "seal"}, tick=2000)])
    assert (6, 2, 0) not in cmd.audit_avoid(save, 2000 + cmd.WALL_BUILT_LAG - 1)   # a snapshot older than the build proves nothing
    got = cmd.audit_avoid(save, 2000 + cmd.WALL_BUILT_LAG)
    assert (89, 100, 139) in got and (6, 2, 0) in got, got


def test_plan_check_names_the_fortcore_when_the_audit_wall_lies_on_it():
    route = "bypass: wall 89,100,139 floor -> 88,101,139"
    a = {"routes": [route], "walls": ["89,100,139 floor wall"], "open": [], "pending": {}, "core": {"89,100,139 floor wall": "y372s0b0"},
         "fails": [route], "cut": [], "doored": {}, "built": {}, "jammed": {}, "via_built": {}}
    doc = {"phase_target": "P3", "year": 1, "seasons": [{"build": []}] * 4}
    errs, warn = plan.audit_gate(copy.deepcopy(doc), {"t": {"season": 0}, "phase": "P3"}, {"audit": a}, None)
    assert errs == [] and len(warn) == 1, (errs, warn)
    assert "y372s0b0" in warn[0] and "fort's own way" in warn[0] and "builds the wall" not in warn[0], warn


# ---------------------------------------------------------------- BUG-640 (regression, whole check)
def test_a_drafted_hospital_furnish_is_no_error_in_the_whole_plan_check_even_with_no_water_source(save, monkeypatch):
    """Trumpetrealms y437-y441: `plan propose` drafted `hospital furnish=1` (no_table) and `plan check` struck it as an ERROR every year
    (players deleted it by hand). BUG-640 fixed hospital_gate (R41); this runs the drafted row through check() as a whole."""
    s = files.read_state(save)
    s["water"] = {"src": [], "gaps": ["no_table"], "hosp": 4}
    monkeypatch.setattr(plan, "hospital_water", lambda st, fort=None: {"ok": False, "d": None, "why": "no valid site within 30 tiles of water"})
    doc = plan.propose(s, plan.load_phases(), None, applied=set(), fort={})
    doc["seasons"] = [{"build": [{"tpl": "hospital", "site": "S1", "p": {"furnish": 1}}]}, {"build": []}, {"build": []}, {"build": []}]
    errs, _ = plan.check(doc, s, tpls=plan.templates(), prev=None, fort={})
    assert not [e for e in errs if "hospital" in e or "thirst" in e], errs
    doc["seasons"][0]["build"] = [{"tpl": "hospital", "site": "S1"}]
    errs, _ = plan.check(doc, s, tpls=plan.templates(), prev=None, fort={})
    assert [e for e in errs if "would die of thirst" in e], errs                  # a NEW hospital without water is still refused
