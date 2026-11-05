"""BUG-488 / BUG-489 / BUG-490 (Run 16a i1 Basementflew y372-y397; round 30).
BUG-489: the aqshaft ended at z125 above the known heavy levels z123/z120/z116; `plan propose` drew no second shaft because
"a shaft was placed" and drew fortcore stage 2/3 and seal@refuge on phantom depths while stage 1 was parked for a heavy aquifer.
BUG-488 tests (trade pile) are in the second half of this file."""
from __future__ import annotations

import copy
import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import files, plan, schema

TOP = 129
AQ = [127, 126, 123, 120, 116]                    # Basementflew: light z127/z126, wet z123, heavy z120 and z116


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    box = {"man": {"v": 2, "aquifer_levels": list(AQ)}, "free": [
        {"id": "S1", "anchor": [45, 15, TOP], "rot": 0, "why": "column 45,15 z129-z114, passes aquifer level z127"}]}
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: {"v": 2, "id": "s1", "rows": {}, "bbox": [0, 0, 100, 1, 1, 140], "marks": {}})
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "core_anchor", lambda _d: None)

    def free(save, tpl, params=None, snap=None, n=3, **kw):
        return (box["free"] if tpl == "aqshaft" else []), "s1", len(box["free"])
    monkeypatch.setattr(plan, "free_sites", free)
    yield d, box
    reset_paths()


def _bp(save, pid, doc):
    (save / "bp").mkdir(parents=True, exist_ok=True)
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), encoding="utf-8")


def _shaft(save, pid="y389s0b0", bot=125, done=True, depth=16):
    _bp(save, pid, {"tpl": "aqshaft", "id": pid, "anchor": [45, 15, TOP], "params": {"x": 45, "y": 15, "top": TOP, "depth": depth}})
    if done:
        append_events(save, [ev(8001, "AQ_PASS_DONE", "", {"proj": pid, "top": TOP, "bot": bot, "n": 1, "lv": [127]}),
                             ev(8002, "PROJECT_DONE", "", {"proj": pid})])


def _state(save, phase="P3"):
    s = copy.deepcopy(files.read_state(save))
    s["phase"], s["proj"], s["sched"] = phase, [], {}
    s["pop"] = {"cit": 40}
    return s


def test_a_shaft_that_ended_above_the_known_levels_is_a_gap(world):
    save, _ = world
    _shaft(save)
    assert plan.aq_shafts(save, {("aqshaft", None)}) == {"placed": True, "live": False, "bottom": 125}
    late = plan.aquifer_late(save, {("aqshaft", None)})
    assert late and late["ok"] and late["site"]["anchor"] == [45, 15, TOP], late
    assert late["gap"]["bottom"] == 125 and late["gap"]["below"] == [123, 120, 116], late


def test_a_shaft_below_every_known_level_or_a_live_one_is_no_gap(world):
    save, box = world
    _shaft(save, bot=114)
    assert plan.aquifer_late(save, {("aqshaft", None)}) is None, "passed every known level"
    box["man"]["aquifer_levels"] = [127]
    _shaft(save, bot=125)
    assert plan.aquifer_late(save, {("aqshaft", None)}) is None, "z127 is above the bottom"
    box["man"]["aquifer_levels"] = list(AQ)
    _shaft(save, pid="y390s0b0", done=False)
    assert plan.aquifer_late(save, {("aqshaft", None)}) is None, "a second shaft is under way"
    assert plan.aq_shafts(save, {("aqshaft", None)})["live"] is True


def test_propose_draws_the_aqshaft_first_and_drops_the_parked_core(world):
    save, _ = world
    _shaft(save)
    _bp(save, "y388s0b1", {"tpl": "fortcore", "id": "y388s0b1", "anchor": [46, 16, 131], "params": {"stage": 1}})   # parked: not done
    applied = {("aqshaft", None), ("fortcore", 1)}
    sf = plan.surface_facts(save, _state(save), applied, None)
    assert sf["aq_late"]["gap"]["parked"] is True and sf["aq_late"]["ok"] is True, sf
    fort = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True, "aqshaft": True, "aq_live": False,
            "surface": sf}
    builds = [{"tpl": "seal", "site": "S1", "p": {"at": "refuge"}}, {"tpl": "fortcore", "site": "same", "p": {"stage": 2}},
              {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}, {"tpl": "farms", "site": "S1"}]
    note = plan.aquifer_late_swap(builds, sf["aq_late"])
    assert [b["tpl"] for b in builds] == ["aqshaft", "farms"], builds
    assert "BUG-489" in note and "z125" in note and "z123" in note and "3 parked core piece" in note, note
    doc = plan.propose(_state(save), plan.load_phases(), None, decisions={}, applied=applied, fort=fort)
    bs = [b for se in doc["seasons"] for b in se["build"]]
    assert bs and bs[0]["tpl"] == "aqshaft" and bs[0]["p"]["top"] == TOP, bs
    assert not any(b["tpl"] == "fortcore" for b in bs), bs
    assert "BUG-489" in doc["notes"]
    assert schema.validate("plan", doc) == []


def test_a_standing_core_keeps_its_stages(world):
    save, _ = world
    _shaft(save)
    _bp(save, "y388s0b1", {"tpl": "fortcore", "id": "y388s0b1", "anchor": [46, 16, 131], "params": {"stage": 1}})
    append_events(save, [ev(8003, "PROJECT_DONE", "", {"proj": "y388s0b1"})])
    late = plan.aquifer_late(save, {("aqshaft", None), ("fortcore", 1)})
    assert late["gap"]["parked"] is False
    builds = [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]
    plan.aquifer_late_swap(builds, late)
    assert [b["tpl"] for b in builds] == ["aqshaft", "fortcore"] and builds[1]["p"] == {"stage": 3, "aquifer": "pass"}


# ---------------------------------------------------------------- BUG-488: the trade pile without a fortcore
from pathlib import Path

from dfpilot import bp, cmd

X0, Y0, Z = 100, 100, 130
W, H = 40, 30


def _snap():
    rows = ["." * W for _ in range(H)]
    return {"v": 2, "id": "s488", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": rows, f"z{Z + 1}": ["_" * W for _ in range(H)]}, "marks": {}}


def test_tradepost_is_a_4x2_stockpile_named_dfllm_trade_that_digs_nothing():
    doc = bp.emit("tradepost", {}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert [st["mode"] for st in doc["stages"]] == ["place"] and doc["class"] == "infra"
    cells = [c for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]]
    assert len(cells) == 1 and cells[0][3].startswith("g{name=dfllm-trade autotrade=true}"), cells
    assert "zones" not in doc["manifest"] and not doc["manifest"].get("rooms")
    assert schema.validate("bp", dict(doc, id="y1s0b4")) == [] and bp.validate(dict(doc, id="y1s0b4")) == []
    assert "tradepost" in [t["tpl"] for t in bp.list_templates()]


def test_tradepost_sites_need_no_fortcore_and_stand_beside_the_manifest_depot():
    snap = _snap()
    found = bp.rank(snap, "tradepost", {}, n=3)
    assert found and "4x2 open surface floor for the trade pile" in found[0]["why"]
    man = {"v": 2, "depot": [136, 125, Z]}
    near = bp.rank(snap, "tradepost", {}, manifest=man, n=1)[0]
    assert near["anchor"][0] > X0 + 25 and near["anchor"][1] > Y0 + 15, near
    # the depot's own tiles are not offered when the depot stands in the manifest's keep-out: the ranking is on open floor only
    assert bp.rank(snap, "tradepost", {}, manifest=man, n=1, near=[136, 125, Z], within=12)


def test_a_depot_without_a_pile_gets_the_tradepost_drafted(world):
    save, _ = world
    s = _state(save, "P0")
    full = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True, "trade_pile": False}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("depot", None), ("fortcore", 1)}, fort=full)
    bs = [b for se in doc["seasons"] for b in se["build"]]
    assert [b for b in bs if b["tpl"] == "tradepost"] == [{"tpl": "tradepost", "site": "S1"}], bs
    assert "BUG-488" in doc["notes"] and schema.validate("plan", doc) == []
    assert plan.build_kind({"tpl": "tradepost", "site": "S1"}) == "depot"
    have = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("depot", None), ("fortcore", 1)}, fort={**full, "trade_pile": True})
    assert all(b["tpl"] != "tradepost" for se in have["seasons"] for b in se["build"])
    unknown = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("depot", None), ("fortcore", 1)},
                           fort={k: v for k, v in full.items() if k != "trade_pile"})
    assert all(b["tpl"] != "tradepost" for se in unknown["seasons"] for b in se["build"]), "not looked up: nothing drafted"


def test_a_depot_drafted_now_gets_its_pile_in_the_same_draft(world):
    save, _ = world
    s = _state(save, "P0")
    full = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": False, "trade_pile": False}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)}, fort=full)
    tpls = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
    assert "depot" in tpls and "tradepost" in tpls and tpls.index("depot") < tpls.index("tradepost"), tpls


def test_trade_pile_planned_knows_a_tradepost_the_surface_core_and_a_live_fortcore(world):
    save, _ = world
    assert plan.trade_pile_planned(save) is False
    _bp(save, "y1s0b0", {"tpl": "depot", "id": "y1s0b0", "anchor": [1, 1, Z], "params": {}})
    assert plan.trade_pile_planned(save) is False, "a depot alone has no pile"
    _bp(save, "y1s0b1", {"tpl": "fortcore", "id": "y1s0b1", "anchor": [1, 1, Z], "params": {"stage": 1}})
    assert plan.trade_pile_planned(save) is True, "fortcore stage 1 builds one"
    assert plan.trade_pile_planned(save, {"ids": ["y1s0b1"]}) is False, "a fortcore stopped on a breach never did"
    _bp(save, "y1s0b2", {"tpl": "tradepost", "id": "y1s0b2", "anchor": [1, 1, Z], "params": {}})
    assert plan.trade_pile_planned(save, {"ids": ["y1s0b1"]}) is True
