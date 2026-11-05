"""BUG-458..461 (Run 16d i4 Orbblock y372-y377, 23 starved; offline, live-untested). The Lua side (seal.wall_cuts / locked_out, the runner's
wall fallback and LOCKED_OUT question, bp.cancel reopen, appoint replace, economy.seal_doors) is tested in tests/lua/test_bug458_wall_reach.lua,
test_manager_bypass.lua and test_economy_drink.lua. Here: the CLI schema, the wake hints, the famine options that can work (BUG-459), the
surface farm and the ceiling's reason in `plan propose` (BUG-460) and the room of the essential shops (BUG-461)."""
import json

import pytest

from dfpilot import plan, schema, wake


# ---------------------------------------------------------------- BUG-458: the schema and the hints
def test_bp_cancel_reopen_and_appoint_replace_pass_the_schema():
    assert schema.validate_args("bp.cancel", {"proj": "c1a1ab60b6183f0601", "reopen": "95,69,137;95,71,137"}) == []
    assert schema.validate_args("bp.cancel", {"proj": "c1a1ab60b6183f0601", "reopen": "x" * 201}) != []
    assert schema.validate_args("appoint", {"code": "MANAGER", "unit": 26274, "replace": True}) == []
    assert schema.validate_args("appoint", {"code": "MANAGER", "unit": 26274, "replace": False}) != [], "replace is true or absent"


def test_locked_out_decision_passes_the_schema_and_the_wake_names_the_fix():
    cmd = 'dfllm cmd bp.cancel \'{"proj":"c1a1ab60b6183f0601","reopen":"95,69,137"}\''
    d = {"id": "locked_out", "q": "LOCKED OUT: our wall at 95,69,137 shuts 2 citizen(s) and farm 96,77,138 off the fort", "n": 2,
         "at": ["95,69,137"], "units": [26272, 26274], "places": ["farm 96,77,138"], "proj": "c1a1ab60b6183f0601", "cmd": cmd,
         "how": "reopen takes only the wall the kernel built there down"}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []
    verb, _, raw = cmd.removeprefix("dfllm cmd ").partition(" ")
    assert schema.validate_args(verb, json.loads(raw.strip("'"))) == []
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "act now" in h and "95,69,137" in h and cmd in h and "bp.place seal at=last" in h


def test_manager_stuck_outside_names_the_replacement_command():
    rep = 'dfllm cmd appoint \'{"code":"MANAGER","unit":26277,"replace":true}\''
    d = {"id": "manager_stuck", "q": "manager Ilral OUTSIDE the fort for 9 days", "n": 5, "days": 9, "units": [26272],
         "cmds": [rep, "dfllm cmd inspect what=unit key=26272"], "out": 9, "replace": rep}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "OUTSIDE the fort for 9 days" in h and rep in h
    verb, _, raw = rep.removeprefix("dfllm cmd ").partition(" ")
    assert schema.validate_args(verb, json.loads(raw.strip("'"))) == []
    plain = wake.next_hint("DECISION_NEEDED", {"d": {"id": "manager_stuck", "days": 14, "n": 3, "cmds": ["dfllm cmd inspect what=orders"]}})
    assert "OUTSIDE" not in plain and "validates nothing for 14 days" in plain


# ---------------------------------------------------------------- BUG-459: the famine options that can work
FARM = "dfllm cmd bp.place '{\"tpl\":\"farms\",\"site\":\"S1\",\"p\":{\"surface\":1}}'"
BUTCH = "dfllm cmd butcher.mark '{\"n\":2}'"
TRADE = "dfllm cmd trade.want '{\"add\":[\"food\",\"seeds\"]}'"


def test_farm_command_is_dropped_when_no_farm_site_stands_and_a_decision_never_has_none(monkeypatch, tmp_path):
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "none")
    d = {"id": "famine", "opts": ["farms"], "cmds": [FARM]}
    cmds, dropped = wake.workable_food_cmds(d, tmp_path)
    assert FARM not in cmds and cmds == [wake.TRADE_FOOD_CMD], "old code: the dead farm command was the only option"
    assert dropped and "no farm site" in dropped[0]
    h = wake.food_hint(d, tmp_path)
    assert wake.TRADE_FOOD_CMD in h and "not offered: bp.place farms: no farm site" in h
    # a site stands: the command stays; trade.want is kept once
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "surface")
    cmds, dropped = wake.workable_food_cmds({"cmds": [FARM, TRADE]}, tmp_path)
    assert cmds == [FARM, TRADE] and dropped == []
    # unknown (no sites snapshot): the command stays, nothing is claimed
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: None)
    assert wake.workable_food_cmds({"cmds": [FARM, BUTCH]}, tmp_path)[0][0] == FARM
    # no save dir (the hint of a test or a bare event): the kernel's list stands, plus the trade fallback
    assert wake.workable_food_cmds({"cmds": [BUTCH]})[0] == [BUTCH, wake.TRADE_FOOD_CMD]


def test_trade_want_command_of_the_decision_is_a_valid_command():
    verb, _, raw = TRADE.removeprefix("dfllm cmd ").partition(" ")
    assert schema.validate_args(verb, json.loads(raw.strip("'"))) == []


# ---------------------------------------------------------------- BUG-460: the surface farm and the ceiling
def test_surface_farm_is_looked_up_in_a_famine_although_the_surface_core_is_off(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)
    assert [k for k, _ in plan._farm_kinds()] == ["room"], "BUG-413: no surface fort by default"
    assert [k for k, _ in plan._farm_kinds(urgent=True)] == ["room", "surface"], "old code: the surface plots never looked up"
    assert [p.get("surface") for p in wake.farm_tries({"plots": 2}, "PEACE")] == [None, None]
    assert wake.farm_tries({"plots": 2}, "PEACE", urgent=True)[-1] == {"plots": 2, "surface": 1}
    assert wake.farm_tries({"plots": 2}, "SIEGE", urgent=True)[-1].get("surface") is None, "builders go out in PEACE only"
    assert wake.food_urgent({"stock": {"food_d": 3}}) and not wake.food_urgent({"stock": {"food_d": 61}})
    assert not wake.food_urgent({}) and not wake.food_urgent(None)


def test_farm_plots_follow_the_citizens():
    assert [plan.farm_plots_for(n) for n in (0, 1, 10, 11, 26, 40, 95, None)] == [None, 1, 1, 2, 3, 4, 4, None]


STATE = {"stock": {"food_d": 1}, "mode": "PEACE", "pop": {"cit": 26}}


def test_food_draft_draws_the_surface_farm_with_plots_per_citizen():
    b, note = plan.food_draft(STATE, {"farms": {"open": False, "site": "surface"}}, [], None)
    assert b == {"tpl": "farms", "site": "S1", "p": {"surface": 1, "plots": 3}}, "old code: surface=1 and the template's 2 plots"
    assert "p.plots=3" in note
    # the soil has room for fewer: never more than fits
    b, _ = plan.food_draft(STATE, {"farms": {"open": False, "site": "surface", "plots": 1}}, [], None)
    assert b["p"] == {"surface": 1, "plots": 1}
    # a small fort: one plot
    b, _ = plan.food_draft({**STATE, "pop": {"cit": 7}}, {"farms": {"open": False, "site": "surface"}}, [], None)
    assert b["p"] == {"surface": 1, "plots": 1}
    # a room site: no surface params
    b, _ = plan.food_draft(STATE, {"farms": {"open": False, "site": "room"}}, [], None)
    assert b == {"tpl": "farms", "site": "S1"}


def test_farm_site_fix_gives_a_phase_farms_build_the_surface_params_with_plots():
    builds = [{"tpl": "farms", "site": "S1"}]
    out, note = plan.farm_site_fix(builds, STATE, {"farms": {"site": "surface"}})
    assert out[0]["p"] == {"surface": 1, "plots": 3} and "p.surface=1" in note


def test_a_ceiling_under_the_policy_names_its_blocker():
    assert plan.ceiling_held_note(100, 100, ["traps 0"]) == "" and plan.ceiling_held_note(26, 100, []) == ""
    n = plan.ceiling_held_note(26, 100, ["traps 0", "armor worn 10 %"])
    assert n.startswith("; pop_ceiling 26 held (policy 100): defence short (traps 0, armor worn 10 %)")
    doc = {"year": 374, "phase_target": "P2", "policy": {"option": "B", "pop_ceiling": 26, "beauty": "none"},
           "seasons": [{"build": []}] * 4, "notes": "draft from phases P0..P2" + n + "; site S<k> = k-th free site"}
    assert "ceiling 26 (held, policy 100: defence short (traps 0, armor worn 10 %))" in plan._summary(doc)
    doc["policy"]["pop_ceiling"] = 100
    assert "ceiling 100 beauty" in plan._summary(doc), "a ceiling that is not the held one carries no reason"


# ---------------------------------------------------------------- BUG-461: the room of the essential shops
def _doc(seasons):
    return {"year": 372, "phase_target": "P2", "policy": {"option": "B", "pop_ceiling": 100, "beauty": "none"},
            "seasons": [{"build": b} for b in seasons], "notes": "draft"}


def test_essential_shops_are_drafted_before_dining_and_furnaces(monkeypatch, tmp_path):
    monkeypatch.setattr(plan._cmd, "workshops_missing", lambda save_dir, types=None: ["Still", "Butchers"])
    doc = _doc([[{"tpl": "seal", "site": "S1"}, {"tpl": "dining", "site": "S1"}],
                [{"tpl": "furnaces", "site": "S1"}], [], []])
    lines = plan.reserve_shop_room(tmp_path, doc, None)
    assert len(lines) == 1 and "workshops only=Still,Butchers drafted ahead of dining" in lines[0]
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["seal", "workshops", "dining"], "old code: dining and furnaces held the floor"
    assert doc["seasons"][0]["build"][1]["p"] == {"only": "Still,Butchers"}
    assert "BUG-461" in doc["notes"]


def test_a_workshops_build_of_the_draft_that_makes_them_moves_ahead(monkeypatch, tmp_path):
    monkeypatch.setattr(plan._cmd, "workshops_missing", lambda save_dir, types=None: ["Kitchen"])
    ws = {"tpl": "workshops", "site": "S1", "p": {"only": "Kitchen,Still"}}
    doc = _doc([[{"tpl": "dining", "site": "S1"}], [ws], [], []])
    lines = plan.reserve_shop_room(tmp_path, doc, None)
    assert len(lines) == 1 and "moved ahead of dining" in lines[0]
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["workshops", "dining"] and doc["seasons"][1]["build"] == []
    assert doc["seasons"][0]["build"][0] is ws


def test_nothing_changes_when_the_shops_stand_or_come_first_or_nobody_competes(monkeypatch, tmp_path):
    monkeypatch.setattr(plan._cmd, "workshops_missing", lambda save_dir, types=None: [])
    doc = _doc([[{"tpl": "dining", "site": "S1"}], [], [], []])
    assert plan.reserve_shop_room(tmp_path, doc, None) == [] and len(doc["seasons"][0]["build"]) == 1
    monkeypatch.setattr(plan._cmd, "workshops_missing", lambda save_dir, types=None: ["Still"])
    first = _doc([[{"tpl": "workshops", "site": "S1", "p": {"only": "Still"}}, {"tpl": "dining", "site": "S1"}], [], [], []])
    assert plan.reserve_shop_room(tmp_path, first, None) == []
    alone = _doc([[{"tpl": "bedrooms", "site": "S1"}], [], [], []])
    assert plan.reserve_shop_room(tmp_path, alone, None) == [] and len(alone["seasons"][0]["build"]) == 1
    # an unreadable manifest is no claim
    def boom(save_dir, types=None):
        raise RuntimeError("no manifest")
    monkeypatch.setattr(plan._cmd, "workshops_missing", boom)
    assert plan.reserve_shop_room(tmp_path, _doc([[{"tpl": "dining", "site": "S1"}], [], [], []]), None) == []


def test_applied_builds_keep_their_place(monkeypatch, tmp_path):
    """The builds of the applied plan of the same year (prev) are not moved: the new shops go in front of the first NEW dining."""
    monkeypatch.setattr(plan._cmd, "workshops_missing", lambda save_dir, types=None: ["Still"])
    prev = _doc([[{"tpl": "dining", "site": "S1"}], [], [], []])
    doc = _doc([[{"tpl": "dining", "site": "S1"}, {"tpl": "tavern", "site": "S1"}], [], [], []])
    lines = plan.reserve_shop_room(tmp_path, doc, prev)
    assert len(lines) == 1
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["dining", "workshops", "tavern"]
