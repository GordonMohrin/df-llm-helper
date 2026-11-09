"""BUG-602 .. BUG-606 (Run 16c i3 Wallfree y372-y376, 16a i1 Basementflew, 09.11.2026; offline, live-untested).
BUG-602: `bp sites aqshaft` falls back to open-ground columns (nearest the fortcore that waits for the aqshaft) when every public-floor
         column is the floor of a placed room.
BUG-603: `bp sites fortcore` says when a site's dig may meet an aquifer nobody has seen (hidden rock) and what to do.
BUG-604: a same-year plan's cancelled fortcore stage 1 is no second core when a fortcore stage 1 stands.
BUG-605: drink 0 days with food 331 (no plot, nothing to brew): follow tries and the plan drafts the surface farm on soil / grass.
BUG-606: popcap.raise takes cap= (Lua side: tests/lua/test_fix10_famine.lua)."""
from __future__ import annotations

import json

import pytest
from test_bug412_413_aquifer_default import X0, Y0, Z, _snap  # noqa: F401
from test_bug441_445_f28 import _bp, world  # noqa: F401  (the aquifer world fixture)

from dfpilot import cmd, files, plan, wake


def _core(save, anchor=(180, 160, Z)):
    """A fortcore stage 1 with p.aquifer=pass, a real blueprint (the one that waits for the aqshaft)."""
    d = cmd.emit_at("fortcore", {"stage": 1, "aquifer": "pass", "depth": 4}, {"id": "S1", "anchor": list(anchor), "rot": 0},
                    "S1", "c1a1core")
    cmd.write_bp(save, d)
    return d


# ---------------------------------------------------------------- BUG-602
def _held_floor(monkeypatch, box):
    """Every tile of the Z4 box is the floor of a placed hospital (a fort whose first rooms were placed before any corridor)."""
    occ = cmd.Occupancy()
    z4 = box["man"]["zones"]["Z4"][0]
    for x in range(z4[0], z4[3] + 1):
        for y in range(z4[1], z4[4] + 1):
            occ.owner[(x, y, z4[2])] = ("y372s0b1", "hospital")
    monkeypatch.setattr(cmd, "occupancy", lambda *a, **k: occ)


def test_aqshaft_falls_back_to_open_ground_nearest_the_waiting_fortcore(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "zones": {"Z4": [[110, 110, Z, 120, 115, Z]]}, "aquifer_levels": [Z - 3, Z - 4]}
    _held_floor(monkeypatch, box)
    _core(save)
    with pytest.raises(cmd.BpError, match="placed room"):      # the old ranking: nothing, with the reason (no fallback for a named column)
        cmd.rank_sites(save, "aqshaft", {"x": 1, "y": 1, "top": Z, "depth": 4}, box["snap"], manifest=box["man"])
    sites, _ = cmd.rank_sites(save, "aqshaft", {}, box["snap"], manifest=box["man"])
    assert sites, "BUG-602: open ground is offered"
    s1 = sites[0]
    assert s1["id"] == "S1" and s1["anchor"][2] == Z and s1["depth"] >= 2 and "BUG-602" in s1["why"], s1
    assert "beside the waiting fortcore" in s1["why"] and max(abs(s1["anchor"][0] - 180), abs(s1["anchor"][1] - 160)) <= 6, s1
    z4 = box["man"]["zones"]["Z4"][0]
    assert not (z4[0] <= s1["anchor"][0] <= z4[3] and z4[1] <= s1["anchor"][1] <= z4[4]), "not the placed room's floor"
    doc = cmd.place(save, "aqshaft", {}, "S1", "c1a1shaft", snap=box["snap"])      # and bp.place S1 takes it
    assert doc["tpl"] == "aqshaft" and doc["anchor"] == s1["anchor"]


def test_open_ground_columns_keep_the_ranking_rules(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "zones": {"Z4": [[110, 110, Z, 120, 115, Z]]}}
    _held_floor(monkeypatch, box)
    box["snap"]["marks"] = {"cavern": [[150, 150, Z - 5]]}         # a revealed cavern level inside every column's levels
    with pytest.raises(cmd.BpError, match="placed room|cavern"):
        cmd.rank_sites(save, "aqshaft", {"depth": 8}, box["snap"], manifest=box["man"])


# ---------------------------------------------------------------- BUG-604
def _year_plan(builds):
    return {"year": 372, "seasons": [{"build": list(builds)}, {"build": []}, {"build": []}, {"build": []}]}


def test_a_cancelled_kept_fortcore_stage_1_is_the_core_that_stands(world):
    save, box = world
    _core(save)
    core = {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}
    prev = _year_plan([core])                     # y372s0b0 was applied, its project cancelled, the core placed by hand
    assert not (save / "bp" / "y372s0b0.json").exists()
    # the same draft on a fresh fort (no kept build at that index): the second stage 1 is still refused (BUG-358)
    with pytest.raises(cmd.BpError, match="fortcore already"):
        plan.place_all(save, _year_plan([core]), None)
    docs, kept, lines = plan.place_all(save, _year_plan([core]), prev)
    assert docs == [] and kept == 0
    assert any("kept c1a1core" in x and "BUG-604" in x for x in lines), lines


def test_a_later_stage_at_same_builds_on_the_core_that_stands(world):
    save, box = world
    _core(save)
    b1 = {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}
    b2 = {"tpl": "fortcore", "site": "same", "p": {"stage": 2, "depth": 4}}
    docs, _, lines = plan.place_all(save, _year_plan([b1, b2]), _year_plan([b1]))
    assert [d["anchor"] for d in docs] == [[180, 160, Z]], lines
    assert docs[0]["params"]["stage"] == 2


def test_without_the_core_shaft_the_open_ground_column_keeps_off_the_core_box(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "zones": {"Z4": [[110, 110, Z, 120, 115, Z]]}, "aquifer_levels": [Z - 3, Z - 4]}
    _held_floor(monkeypatch, box)
    _core(save)
    sm = cmd.load_bp("sites")
    monkeypatch.setattr(sm, "core_shaft", lambda *a, **k: (_ for _ in ()).throw(ValueError("no column beside the entrance")))
    sites, _ = cmd.rank_sites(save, "aqshaft", {}, box["snap"], manifest=box["man"])
    a = sites[0]["anchor"]
    assert "open-ground column" in sites[0]["why"] and "waiting fortcore" in sites[0]["why"], sites[0]
    assert 6 < max(abs(a[0] - 180), abs(a[1] - 160)) <= 12, a


def test_without_a_waiting_core_open_ground_near_the_embark_centre(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "zones": {"Z4": [[110, 110, Z, 120, 115, Z]]}, "aquifer_levels": [Z - 3, Z - 4]}
    _held_floor(monkeypatch, box)
    sites, _ = cmd.rank_sites(save, "aqshaft", {}, box["snap"], manifest=box["man"])
    assert sites and "open-ground column" in sites[0]["why"] and "the entrance" in sites[0]["why"], sites
    assert cmd.waiting_core(save) is None
    _core(save)
    assert cmd.waiting_core(save) == {"anchor": [180, 160, Z], "rot": 0, "depth": 4}


# ---------------------------------------------------------------- BUG-605
WALLFREE = {"mode": "PEACE", "stock": {"food_d": 331, "drink_d": 0}, "pop": {"cit": 18}}      # y377: food 331 d, drink 0 d, no plot


def test_low_drink_calls_for_a_farm_like_low_food():
    assert plan.farm_low(WALLFREE) == ("drink", 0)
    assert plan.farm_low({"stock": {"food_d": 40, "drink_d": 0}}) == ("food", 40), "food first"
    assert plan.farm_low({"stock": {"food_d": 331, "drink_d": 30}}) is None and plan.farm_low({}) is None
    assert wake.food_urgent(WALLFREE) and not wake.food_urgent({"stock": {"food_d": 331, "drink_d": 90}})
    # follow tries the surface farm in PEACE (plan.surface_core stays off), not in a siege
    assert wake.farm_tries({"plots": 2}, "PEACE", urgent=wake.food_urgent(WALLFREE))[-1] == {"plots": 2, "surface": 1}
    assert wake.farm_tries({"plots": 2}, "SIEGE", urgent=True)[-1].get("surface") is None


def test_the_plan_drafts_the_surface_farm_for_low_drink():
    b, note = plan.food_draft(WALLFREE, {"farms": {"open": False, "site": "surface"}}, [], None)
    assert b and b["tpl"] == "farms" and b["p"]["surface"] == 1, b
    assert "drink (no farm plot, nothing to brew) 0 d (< 30)" in note, note
    b, note = plan.food_draft({**WALLFREE, "mode": "ALERT"}, {"farms": {"open": False, "site": "surface"}}, [], None)
    assert b is None and "PEACE only" in note
    b, _ = plan.food_draft({"stock": {"food_d": 331, "drink_d": 90}}, {"farms": {"open": False, "site": "surface"}}, [], None)
    assert b is None, "neither low: nothing drafted"


def test_farm_facts_looks_up_the_surface_site_for_low_drink(world, monkeypatch):
    save, box = world
    box["snap"]["marks"] = {"soil": [[x, y, Z] for x in range(150, 190) for y in range(140, 170)]}
    ff = plan.farm_facts(save, WALLFREE)
    assert ff and ff["site"] == "surface", ff            # the room ranking has no Z4; the surface plots are free
    assert plan.farm_facts(save, {"stock": {"food_d": 331, "drink_d": 90}}) is None


# ---------------------------------------------------------------- BUG-603
def test_a_fortcore_site_says_when_its_dig_may_or_does_meet_an_aquifer(world):
    save, box = world
    sites, _ = cmd.rank_sites(save, "fortcore", {}, box["snap"], manifest={"v": 2})
    assert sites and "hidden rock is unknown" in sites[0]["why"] and "aquifer=pass" in sites[0]["why"], sites[0]["why"]
    sites, _ = cmd.rank_sites(save, "fortcore", {}, box["snap"], manifest={"v": 2, "aquifer_levels": [Z - 3]})
    assert sites and "MEETS the dig" in sites[0]["why"] and "AQ_HEAVY" in sites[0]["why"], sites[0]["why"]
    assert "aquifer at z127" in sites[0]["why"]
