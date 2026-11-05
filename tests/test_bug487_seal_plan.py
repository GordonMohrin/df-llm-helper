"""BUG-487 (Run 16b i2 Roadvises y399-y402, 12 citizens died of thirst behind the kernel's own wall; offline, live-untested). The Lua side
(the plan build's walls through the reach check, WALL_REFUSED, LOCKED_OUT taken down at once) is tested in
tests/lua/test_bug487_plan_seal_walls.lua. Here the plan layer: the kernel's refusal (WALL_REFUSED) is read from the event stream, `seal
at=audit` honours close=door (the audit's own wall piece used to win), `plan check` errors on a seal that would wall a refused tile,
`plan propose` and follow draft close=door there, a door that stands is no open wall."""
import copy
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths       # noqa: E402

from dfpilot import cmd, files, plan, schema, wake                            # noqa: E402

# z0 the walk level, z1 the roof: (6,2) a 1-wide opening between walls, a door can stand there
FORT = [".............",
        ".............",
        "##+.##.##.###",
        "##..##.##.###",
        "#...........#",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 5
BYPASS = "bypass: wall 6,2,0 floor -> 9,5,0"
AT = "6,2,0"


def _save(tmp_path, events):
    d = tmp_path / "save"
    d.mkdir(parents=True, exist_ok=True)
    s = {**tiny([FORT, ROOF]), "id": "s100", "tick": 100, "purpose": "sites"}
    files.write_json_atomic(d / "snap" / "s100.json", s)
    lines = []
    for i, (tick, typ, data) in enumerate(events):
        lines.append(json.dumps({"n": i + 1, "tick": tick, "type": typ, "cls": "A", "msg": typ, "d": data}))
    (d / "events.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return d


AUDIT = (1000, "AUDIT", {"ok": 0, "fails": [BYPASS], "min_traps": 35})
REFUSED = (2000, "WALL_REFUSED", {"at": [AT], "n": 1, "how": "place", "why": "farm 48,93,121"})


# ---------------------------------------------------------------- the event and the read
def test_wall_refused_passes_the_schema_and_is_read_from_the_stream(tmp_path):
    assert "WALL_REFUSED" in schema.EVENTS
    assert schema.validate_event_d("WALL_REFUSED", {"at": [AT], "n": 1, "how": "plan", "proj": "y401s0b0", "why": "farm"}) == []
    assert schema.validate_event_d("WALL_REFUSED", {"n": 1}) != [], "the tiles are required"
    save = _save(tmp_path, [AUDIT, REFUSED])
    assert cmd.wall_refusals(save) == {(6, 2, 0): 2000}
    a = cmd.audit_routes(save)
    assert a["open"] == [f"{AT} floor wall"] and a["cut"] == [f"{AT} floor wall"], a
    # no refusal: nothing is cut
    assert cmd.audit_routes(_save(tmp_path / "b", [AUDIT]))["cut"] == []


def test_a_door_seal_finished_after_the_refusal_clears_it_and_the_audit_wall_is_not_open_again(tmp_path):
    save = _save(tmp_path, [AUDIT, REFUSED, (3000, "PROJECT_DONE", {"proj": "c1a1ac00000000001", "tpl": "seal"}),
                            (4000, "AUDIT", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    files.write_json_atomic(save / "bp" / "c1a1ac00000000001.json", {
        "tpl": "seal", "params": {"at": f"{AT} floor", "close": "door"}, "anchor": [6, 2, 0], "rot": 0, "v": 2, "class": "defense",
        "site": "S1", "stages": [], "manifest": {"v": 2}, "materials": {}})
    assert cmd.wall_refusals(save) == {}, "the door finished after the refusal"
    # the refusal seen again after the door (the kernel refused the wall once more): the door is no open wall
    append_events(save, [ev(5000, "WALL_REFUSED", "x", {"at": [AT], "n": 1, "how": "place"}, tick=5000)])
    a = cmd.audit_routes(save)
    assert a["open"] == [] and list(a["doored"].values()) == ["c1a1ac00000000001"], a


# ---------------------------------------------------------------- seal at=audit: close=door wins
def test_close_door_beats_the_audits_wall_piece(tmp_path):
    """Run 16b i2 y402: p.close=door, the kernel built 'Cw' all the same (the audit entry carries piece 'wall')."""
    save = _save(tmp_path, [AUDIT])
    at, _ = cmd.seal_openings(save, "audit")
    assert at == f"{AT} floor wall", at
    at, notes = cmd.seal_openings(save, "audit", close="door")
    assert at == f"{AT} floor", at                                  # old: '6,2,0 floor wall'
    assert any("close=door" in n for n in notes), notes
    dmod = cmd.load_bp("defense")
    (pc,) = dmod.seal_pieces({"at": at, "close": "door"})
    assert pc["piece"] == "door" and pc["key"] == "d"


def test_a_refused_wall_is_drafted_as_a_door_without_a_param(tmp_path):
    save = _save(tmp_path, [AUDIT, REFUSED])
    at, notes = cmd.seal_openings(save, "audit")
    assert at == f"{AT} floor", at
    assert any("kernel refused a wall there" in n for n in notes), notes
    # the door is kept even where no wall stands beside it on the snapshot (quickfort would refuse it; the kernel guards the wall)
    assert "nodoor" not in at


# ---------------------------------------------------------------- plan check and propose
def _audit(cut=True):
    w = f"{AT} floor wall"
    return {"routes": [BYPASS], "walls": [w], "open": [w], "pending": {}, "core": {}, "fails": [BYPASS], "cut": [w] if cut else [],
            "doored": {}}


DOC = {"phase_target": "P3", "year": 1, "seasons": [{"build": []}] * 4}


def _doc_with(p):
    doc = copy.deepcopy(DOC)
    doc["seasons"][0] = {"build": [{"tpl": "seal", "site": "S1", "p": p}]}
    return doc


def test_plan_check_errors_on_a_seal_that_would_wall_a_refused_tile_and_accepts_close_door():
    s = {"t": {"season": 0}, "phase": "P3"}
    errs, _ = plan.audit_gate(_doc_with({"at": "audit"}), s, {"audit": _audit()}, None)
    assert len(errs) == 1 and "p.close=door" in errs[0] and "refused" in errs[0], errs      # old: OK
    errs, _ = plan.audit_gate(_doc_with({"at": "audit", "close": "auto"}), s, {"audit": _audit()}, None)
    assert len(errs) == 1
    errs, warn = plan.audit_gate(_doc_with({"at": "audit", "close": "door"}), s, {"audit": _audit()}, None)
    assert errs == [], errs                                         # close=door is honoured, not overridden
    # no refusal on file: the wall is the audit's, as before
    errs, _ = plan.audit_gate(_doc_with({"at": "audit"}), s, {"audit": _audit(cut=False)}, None)
    assert errs == []


def test_plan_check_without_the_seal_drafts_the_door_in_its_fix():
    s = {"t": {"season": 0}, "phase": "P0"}
    doc = copy.deepcopy(DOC)
    errs, _ = plan.audit_gate(doc, s, {"audit": _audit()}, None)
    prev = {"phase_target": "P0", "year": 1, "seasons": [{"build": []}] * 4}
    doc["seasons"][0] = {"build": [{"tpl": "tombs", "site": "S1", "p": {}}]}
    errs, _ = plan.audit_gate(doc, s, {"audit": _audit()}, prev)
    assert len(errs) == 1 and '"close":"door"' in errs[0], errs


def test_a_door_that_stands_is_a_warning_not_a_forced_wall():
    a = _audit()
    a["open"], a["cut"], a["doored"] = [], [], {f"{AT} floor wall": "c1a1ac00000000001"}
    errs, warn = plan.audit_gate(copy.deepcopy(DOC), {"t": {"season": 0}}, {"audit": a}, None)
    assert errs == [] and len(warn) == 1 and "a door stands at 6,2,0" in warn[0] and "cut citizens off" in warn[0], warn


def test_propose_drafts_the_audit_seal_with_close_door_where_the_kernel_refused_a_wall(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    try:
        s = copy.deepcopy(files.read_state(d))
        s["phase"], s["proj"] = "P0", []
        fort = dict(plan.fort_facts(d, s), z4=True, core_any=True, core_dig=False)
        fort["audit"] = _audit()
        doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(d, s), fort=fort)
        seals = [b for se in doc["seasons"] for b in se["build"] if b["tpl"] == "seal" and b["p"].get("at") == "audit"]
        assert seals and seals[0]["p"] == {"at": "audit", "close": "door"}, seals           # old: {"at": "audit"}
        fort["audit"] = _audit(cut=False)
        doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(d, s), fort=fort)
        seals = [b for se in doc["seasons"] for b in se["build"] if b["tpl"] == "seal" and b["p"].get("at") == "audit"]
        assert seals and seals[0]["p"] == {"at": "audit"}
        assert schema.validate("plan", doc) == []
    finally:
        reset_paths()


# ---------------------------------------------------------------- follow and the hint
def test_follow_asks_for_the_audit_seal_with_close_door_after_a_refusal(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    try:
        class Clock:
            def __call__(self):
                return 1_000_000.0
        f = wake.Follower(out=[].append, clock=Clock())
        f.poll()
        append_events(d, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35}),
                          ev(8814, "WALL_REFUSED", "wall refused", {"at": [AT], "n": 1, "how": "place"})])
        f.poll()
        assert f.jobs["seal"]["params"] == {"at": "audit", "close": "door"}, f.jobs.get("seal")
    finally:
        reset_paths()


def test_locked_out_hint_says_the_kernel_took_the_wall_down():
    d = {"id": "locked_out", "q": "LOCKED OUT: our wall at 60,100,121 shuts 12 citizen(s)", "n": 12, "at": ["60,100,121"],
         "units": [60], "places": ["farm 48,93,121"], "proj": "y401s0b0", "how": "x", "reop": 1}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "designated it for removal" in h and "puts a door" in h and "act now" not in h, h
    d2 = dict(d)
    d2.pop("reop")
    assert "act now" in wake.next_hint("DECISION_NEEDED", {"d": d2})
