"""Round 37 (BUG-577 to BUG-580; offline, live-untested). The Lua sides are tested in tests/lua/test_bug577_580_audit_siege.lua (the siege /
drill traffic test: BUG-577 a bridge held for a citizen is no BREACH, BUG-580 the drill's clock restarts), test_military.lua (BUG-578 the
sortie odds), test_care_ghosts.lua and test_readiness.lua (BUG-579 no memorial slab on the audit route's tile). Here the plan layer of
BUG-579 (a seal that finished and is named again, a tile that holds a building, a hatch the route passes: not redrafted every year) and
the wake text of BUG-578."""
import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402

from dfpilot import cmd, files, plan, schema, wake                            # noqa: E402

FORT = [".............",
        ".............",
        "##+.##.##.###",
        "##..##.##.###",
        "#...........#",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 5
AT = "6,2,0"
BYPASS = f"bypass: wall {AT} floor -> 9,5,0"
VIA = "bypass: via door 6,2,0 -> 9,5,0"
PID = "c1a1ac00000000001"


def _save(tmp_path, events, params=None):
    d = tmp_path / "save"
    d.mkdir(parents=True, exist_ok=True)
    files.write_json_atomic(d / "snap" / "s100.json", {**tiny([FORT, ROOF]), "id": "s100", "tick": 100, "purpose": "sites"})
    lines = [json.dumps({"n": i + 1, "tick": t, "type": typ, "cls": "A", "msg": typ, "d": data}) for i, (t, typ, data) in enumerate(events)]
    (d / "events.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    files.write_json_atomic(d / "bp" / f"{PID}.json", {
        "tpl": "seal", "params": params or {"at": f"{AT} floor wall"}, "anchor": [6, 2, 0], "rot": 0, "v": 2, "class": "defense",
        "site": "S1", "stages": [], "manifest": {"v": 2}, "materials": {}})
    return d


def _audit(tick, route=BYPASS):
    return (tick, "AUDIT", {"ok": 0, "fails": [route], "min_traps": 35})


DONE = lambda tick: (tick, "PROJECT_DONE", {"proj": PID, "tpl": "seal"})                      # noqa: E731
OCC = lambda tick: (tick, "PROJECT_BLOCKED", {"proj": PID, "tpl": "seal", "why": "occupied",           # noqa: E731
                                              "parts": f"Slab {AT} (a door wanted)"})
DOC = {"phase_target": "P3", "year": 1, "seasons": [{"build": []}] * 4}
S = {"t": {"season": 0}, "phase": "P3"}


# ---------------------------------------------------------------- BUG-579: the seal that was built and is named again
def test_a_seal_finished_before_a_later_audit_that_names_its_tile_is_built_not_open(tmp_path):
    save = _save(tmp_path, [_audit(1000), DONE(2000), _audit(2000 + cmd.WALL_BUILT_LAG)])
    a = cmd.audit_routes(save)
    assert a["open"] == [] and a["pending"] == {} and a["built"] == {f"{AT} floor wall": PID}, a      # old: open, drafted again every year
    errs, warn = plan.audit_gate(copy.deepcopy(DOC), S, {"audit": a}, None)
    assert errs == [] and len(warn) == 1 and PID in warn[0] and "not redrafted" in warn[0], (errs, warn)


def test_an_audit_read_within_the_snapshot_lag_of_the_finish_is_still_open(tmp_path):
    save = _save(tmp_path, [DONE(2000), _audit(2000 + cmd.WALL_BUILT_LAG - 1)])
    a = cmd.audit_routes(save)
    assert a["built"] == {} and a["open"] == [f"{AT} floor wall"], a                # a snapshot older than the build proves nothing


def test_a_seal_still_running_is_pending_as_before(tmp_path):
    save = _save(tmp_path, [_audit(1000)])
    a = cmd.audit_routes(save)
    assert a["pending"] == {f"{AT} floor wall": PID} and a["built"] == {} and a["jammed"] == {}, a


# ---------------------------------------------------------------- BUG-579: a building stands on the tile
def test_a_blocked_occupied_seal_is_jammed_and_names_the_building_not_pending(tmp_path):
    save = _save(tmp_path, [_audit(1000), OCC(1500), _audit(3000)])
    assert cmd.seal_occupied(save) == {(6, 2, 0): (1500, "Slab")}
    a = cmd.audit_routes(save)
    assert a["jammed"] == {f"{AT} floor wall": "Slab"} and a["pending"] == {} and a["open"] == [], a   # old: 'pending: builds the wall'
    errs, warn = plan.audit_gate(copy.deepcopy(DOC), S, {"audit": a}, None)
    assert errs == [] and len(warn) == 1 and "holds a Slab" in warn[0] and "not redrafted" in warn[0], (errs, warn)


def test_the_jam_ends_when_a_seal_finishes_there_later(tmp_path):
    save = _save(tmp_path, [OCC(1500), DONE(2500), _audit(2500 + cmd.WALL_BUILT_LAG)])
    assert cmd.seal_occupied(save) == {}
    assert cmd.audit_routes(save)["jammed"] == {}


# ---------------------------------------------------------------- BUG-579: the route passes a hatch / door a seal of ours built
def test_a_route_via_a_finished_seal_hatch_says_so_and_proposes_no_second_seal(tmp_path):
    save = _save(tmp_path, [DONE(2000), _audit(2000 + cmd.WALL_BUILT_LAG, VIA)], params={"at": f"{AT} stair hatch"})
    a = cmd.audit_routes(save)
    assert a["walls"] == [] and a["via_built"] == {AT: PID}, a
    errs, warn = plan.audit_gate(copy.deepcopy(DOC), S, {"audit": a}, None)
    assert errs == [] and len(warn) == 1 and PID in warn[0] and "counts a door or hatch open" in warn[0], (errs, warn)
    assert "by hand" not in warn[0], "the old advice asked for a removal nobody can make"          # route_advice (BUG-376) said so


def test_a_via_route_without_a_seal_keeps_the_old_advice(tmp_path):
    save = _save(tmp_path, [_audit(1000, VIA)], params={"at": "9,9,0 floor wall"})
    a = cmd.audit_routes(save)
    assert a["via_built"] == {}
    errs, warn = plan.audit_gate(copy.deepcopy(DOC), S, {"audit": a}, None)
    assert warn and "take the door out by hand" in warn[0], warn


# ---------------------------------------------------------------- BUG-578: the odds in the wake text and the event
def test_armour_note_carries_the_odds_and_never_recommends_poor_ones():
    good = {"worn": 90, "need": 80, "rec": 1, "odds": "good", "ours": 100, "est": 10, "foes": 1}
    assert wake.armour_note(good) == " (sortie recommended: worn 90% >= 80%, odds good (cv 100 vs ~10, 1 hostile(s)))"
    weak = {"worn": 90, "need": 80, "rec": 0, "odds": "hopeless", "ours": 100, "est": 480, "foes": 40}
    note = wake.armour_note(weak)
    assert "NOT recommended: worn 90% ok, but" in note and "odds hopeless (cv 100 vs ~480, 40 hostile(s))" in note, note
    low = {"worn": 50, "need": 80, "rec": 0, "odds": "even", "ours": 100, "est": 100, "foes": 10}
    assert "worn 50% < 80%, odds even" in wake.armour_note(low)
    assert wake.armour_note({"worn": 90, "need": 80, "rec": 1}) == " (sortie recommended: worn 90% >= 80%)"      # the old events


def test_decision_with_odds_and_the_drill_retries_pass_the_schema():
    d = {"id": "siege_long", "q": "x", "worn": 90, "need": 80, "rec": 0, "odds": "poor", "ours": 100, "est": 240, "foes": 20}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []
    assert schema.validate_event_d("DRILL_RESULT", {"pass": 0, "fails": ["occupied:B1"], "retries": 2}) == []
    assert schema.validate_event_d("DRILL_RESULT", {"pass": 0, "retries": "x"}) != []
