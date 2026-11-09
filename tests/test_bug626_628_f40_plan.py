"""Round 40 (plan; offline, live-untested). BUG-626 P3+ plans refused for O1 and B2 in a fort whose stage 3 waits for the aqshaft (round 39
regression of BUG-523, Run 16a i1 Basementflew y455), BUG-627 the trade sell list's surplus kinds (Lua side:
tests/lua/test_bug627_trade_surplus.lua), BUG-628 `plan propose` drew traps with no trap part free."""
from __future__ import annotations

import pytest

from dfpilot import plan, traps


@pytest.fixture(autouse=True)
def _no_surface_core(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)


DOC = {"phase_target": "P5", "seasons": [{"build": []} for _ in range(4)], "year": 456}
ST = {"bridges": {"B1": "down"}, "alert": {"ref": {"ex": 1}}}
AQSHAFT = {"tpl": "aqshaft", "site": "S1", "p": {"x": 88, "y": 96, "top": 131}}


# ---------------------------------------------------------------- BUG-626
def test_a_core_whose_stage_3_waits_for_the_placed_shaft_is_not_held_for_o1_and_b2():
    # Basementflew after round 39: the core stands (stage 2), no stage 3 yet, an aqshaft is placed and has not passed the aquifer
    fort = {"surface": {"need": False, "have": False, "aq_wait": {"live": True}}, "core": None}
    errs, warn = plan.stage3_gate(DOC, ST, fort, None)
    assert errs == [], "P3+ is not refused for a stage 3 that cannot be dug before the shaft passed"
    assert len(warn) == 1 and "waits for the aqshaft" in warn[0] and "O1, B2" in warn[0]
    p3 = {**DOC, "phase_target": "P3"}
    assert plan.stage3_gate(p3, ST, fort, None)[0] == []


def test_a_draft_that_builds_the_shaft_for_a_due_aquifer_route_is_not_held_either():
    late = {"ok": True, "site": {"anchor": [88, 96, 131]}, "aquifers": [125, 123]}
    fort = {"surface": {"need": False, "aq_late": late}}
    doc = {**DOC, "seasons": [{"build": []}, {"build": [dict(AQSHAFT)]}, {"build": []}, {"build": []}]}
    errs, warn = plan.stage3_gate(doc, ST, fort, None)
    assert errs == [] and "this plan builds the aqshaft" in warn[0]
    # the route is due but the plan builds no shaft: stage 3 is asked for as before
    assert plan.stage3_gate(DOC, ST, fort, None)[0], "no shaft in the plan: the old ERROR"


def test_a_fort_that_can_dig_stage_3_now_is_held_as_before():
    for fort in ({}, {"surface": {"need": False}}, {"surface": {"need": False, "aq_late": {"ok": True}}}):
        assert plan.stage3_gate(DOC, ST, fort, None)[0], fort
    assert plan.stage3_gate(DOC, ST, {}, None)[0], "no core, no shaft, a site may exist: O1, B2 and the refuge are asked for"
    # a stage 3 in the plan keeps its place check (no waiting branch)
    st3 = {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}
    waiting = {"surface": {"aq_wait": {"live": True}}}
    doc = {**DOC, "seasons": [{"build": [st3]}, {"build": []}, {"build": []}, {"build": []}]}
    assert plan.stage3_gate(doc, ST, waiting, None) == ([], [])


def test_surface_facts_names_a_placed_shaft_that_has_not_passed(monkeypatch, tmp_path):
    monkeypatch.setattr(plan, "_kern_manifest", lambda sd: {})
    monkeypatch.setattr(plan, "aquifer_late", lambda sd, applied: None)
    monkeypatch.setattr(plan, "sites_snapshot", lambda sd: None)
    applied = {("fortcore", 2), ("aqshaft", None)}
    for shafts, want in (({"placed": True, "live": True, "bottom": None}, {"live": True}),
                         ({"placed": True, "live": False, "bottom": None}, {"live": False}),
                         ({"placed": True, "live": False, "bottom": 117}, None),
                         ({"placed": False, "live": False, "bottom": None}, None)):
        monkeypatch.setattr(plan, "aq_shafts", lambda sd, ap, s=shafts: s)
        assert plan.surface_facts(tmp_path, {}, applied, None).get("aq_wait") == want, shafts


def test_the_stage3_gate_reads_the_shaft_facts_of_a_fort_without_a_fortcore(monkeypatch, tmp_path):
    # no fortcore in `applied` (an aqshaft alone: the waiting fortcore was cancelled): the shaft still is the way
    monkeypatch.setattr(plan, "_kern_manifest", lambda sd: {})
    monkeypatch.setattr(plan, "aquifer_late", lambda sd, applied: None)
    monkeypatch.setattr(plan, "sites_snapshot", lambda sd: None)
    monkeypatch.setattr(plan, "aq_shafts", lambda sd, ap: {"placed": True, "live": True, "bottom": None})
    sf = plan.surface_facts(tmp_path, {}, {("aqshaft", None)}, None)
    errs, warn = plan.stage3_gate(DOC, ST, {"surface": sf}, None)
    assert errs == [] and warn


# ---------------------------------------------------------------- BUG-628
def test_traps_that_already_wait_for_parts_with_none_free_gate_new_lanes():
    stuck = {"stock": {"mfree": 0, "mroute": "ordered", "mtp": 1}}
    assert "trap part" in plan.noparts_reason(stuck) and "1 planned trap" in plan.noparts_reason(stuck)
    assert plan.noparts_reason({"stock": {"mfree": 0, "mtp": 5}}), "the kernel clears mroute when no trap is short; mtp says they wait"
    assert plan.noparts_reason({"stock": {"mfree": 4, "mtp": 1}}) == "", "parts stand"
    assert plan.noparts_reason({"stock": {"mfree": 0, "mroute": "ordered", "mtp": 0}}) == "", "nothing waits: the first traps may ask for parts"
    assert plan.noparts_reason({"stock": {"mfree": 0, "mroute": "ordered"}}) == "", "an older kernel (no mtp) as before"


def test_propose_draws_no_trap_lane_while_parts_are_out_of_reach():
    fort = {"traps": {"open": 2, "ways": ["a", "b"], "bopen": 1, "bways": ["B1"]}, "nostone": "", "noparts": "no trap part free"}
    out, note = traps.draft(fort, "P5", [], None, 456, None, False)
    assert out == [] and "BUG-628" in note and "no trap part free" in note
    fort["noparts"] = ""
    out, note = traps.draft(fort, "P5", [], None, 456, None, False)
    assert [b["tpl"] for b in out] == ["traps", "traps"], "parts or a way to make them: the lanes are drafted"
    fort["nostone"] = "the stone digs found only soil (no hard stone yet)"
    assert traps.draft(fort, "P5", [], None, 456, None, False)[0] == [], "no stone: no mechanisms either"


def test_plan_check_does_not_advise_a_lane_that_cannot_be_built():
    st = {"t": {"y": 5, "season": 0}, "phase": "P5"}
    fort = {"traps": {"bopen": 1, "bways": ["B1"]}, "noparts": "no trap part free"}
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    doc["phase_target"] = "P5"
    for se in doc["seasons"]:
        se["build"] = []
    _, warn = plan.check(doc, st, decisions={}, fort=fort)
    lane = [w for w in warn if w.startswith("traps:")]
    assert len(lane) == 1 and "not buildable now: no trap part free" in lane[0], warn
    _, warn = plan.check(doc, st, decisions={}, fort={**fort, "noparts": ""})
    assert [w for w in warn if w.startswith("traps:")] and "not buildable" not in "".join(warn)
