"""Round 35 (sites and plan blockers), Python side; offline, live-untested. The ranking side of BUG-553 is in tests/bp/test_bp_explore.py.
BUG-549 (Run 16a i1 / 16b i2: finished explore probes and a heavy-stopped aqshaft held every room site, `bp.cancel` answered 'no project'):
         a finished explore holds its shaft column, an aqshaft stopped on a heavy aquifer the levels it dug.
BUG-550 (Run 16b i2 y400/y401: ERROR 'drink inside Kern+ lasts 50 d < 90' with no stockroom site): a warning where no site exists.
BUG-551 (Run 16a i1 y415: P3+ refused for O1, B2 and the refuge beside a core whose stage 3 lies under the aquifer): the gate warns.
BUG-552 (Run 16b i2: propose drafted a surface depot every year beside a depot that stands and traded): depot_lost reads the trade.
BUG-553: cmd.site_params carries the depth a site was ranked at."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths
from test_bug412_413_aquifer_default import Z, _snap  # noqa: F401
from test_bug441_445_f28 import _bp, world  # noqa: F401  (the aquifer world fixture)

from dfpilot import cmd, files, plan


def _doc(save, tpl, pid, anchor, params):
    doc = cmd.emit_at(tpl, params, {"id": "S0", "anchor": list(anchor), "rot": 0}, "S0", pid)
    files.write_json_atomic(save / "bp" / f"{pid}.json", doc)
    return doc


# ---------------------------------------------------------------- BUG-549
def test_a_finished_explore_holds_only_its_shaft_column(world):
    save, box = world
    doc = _doc(save, "explore", "y9s0b0", (100, 100, 134), {"depth": 12})
    cells = cmd.bp_cells(doc)
    assert len(cells) > 80, "the probe digs a shaft and side tunnels"
    full = cmd.occupancy(save)
    assert set(full.owner) == cells, "unfinished: the whole footprint is held"
    append_events(save, [ev(900, "PROJECT_DONE", "x", {"proj": "y9s0b0", "tpl": "explore"}, tick=900)])
    occ = cmd.occupancy(save)
    col = cmd.shaft_column(cells)
    assert set(occ.owner) == col and len(col) == 13, (len(col), len(occ.owner))
    assert len({(x, y) for x, y, _ in col}) == 1, "one stair column, 13 levels"
    assert not (cells - col) & set(occ.owner), "the side tunnels are released"
    # a room beside the old tunnel of the finished probe has a free site now, one beside the shaft stays kept off
    tunnel = sorted(cells - col)[0]
    assert tunnel not in occ.owner


def test_shaft_column_of_a_bare_shaft_and_of_no_column():
    shaft = {(5, 5, z) for z in range(10, 14)}
    assert cmd.shaft_column(shaft | {(6, 5, 12), (7, 5, 12)}) == shaft
    flat = {(1, 1, 3), (2, 1, 3), (3, 1, 3)}
    assert cmd.shaft_column(flat) == flat, "no column of two levels: everything stays held"
    assert cmd.shaft_column(set()) == set()


def test_an_aqshaft_stopped_on_a_heavy_aquifer_holds_the_levels_down_to_it(world):
    save, box = world
    _doc(save, "aqshaft", "c1a1heavy", (120, 120, 129), {"x": 120, "y": 120, "top": 129, "depth": 12})
    assert (120, 120, 118) in cmd.occupancy(save).owner, "the whole plan is held while nothing is known"
    append_events(save, [ev(901, "AQ_HEAVY", "x", {"proj": "c1a1heavy", "z": 125, "flow": 9, "why": "heavy", "pos": [120, 120, 125]}, tick=901)])
    occ = cmd.occupancy(save)
    assert (120, 120, 129) in occ.owner and (120, 120, 125) in occ.owner
    assert (120, 120, 124) not in occ.owner and (120, 120, 118) not in occ.owner
    assert cmd.aq_bottoms(save) == {"c1a1heavy": 125}


def test_the_no_site_hint_names_a_finished_holder_and_does_not_promise_a_cancel(world):
    save, box = world
    _doc(save, "explore", "y9s0b0", (100, 100, 134), {"depth": 6})
    _doc(save, "explore", "y9s0b1", (120, 120, 134), {"depth": 6})
    append_events(save, [ev(900, "PROJECT_DONE", "x", {"proj": "y9s0b0", "tpl": "explore"}, tick=900)])
    done_only = cmd.no_site_hint(save, "deepcore", "s1", 3, ["y9s0b0"])
    assert "y9s0b0 (explore finished)" in done_only and "dug space" in done_only and "frees them" not in done_only
    mixed = cmd.no_site_hint(save, "deepcore", "s1", 3, ["y9s0b0", "y9s0b1"])
    assert "frees them" in mixed and "finished project is dug space" in mixed


# ---------------------------------------------------------------- BUG-550
def _plan_doc():
    return {"v": 2, "year": 400, "policy": {"option": "A", "pop_ceiling": 40, "beauty": "none"}, "phase_target": "P2",
            "seasons": [{"build": []} for _ in range(4)], "military": {"pct": 15, "squads": {"melee": 1, "xbow": 0}, "cv_min": 0},
            "supply": dict(plan.schema.PLAN_DEFAULTS["supply"]), "orders": {"import": []}, "trade": {"want": [], "sell": []},
            "notes": ""}


def _core_state(d=50, f=300, total=420):
    return {"t": {"y": 400, "season": 0}, "alert": {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1,
                                                    "core_d": d, "core_f": f},
            "stock": {"drink_d": total, "food_d": 900}, "ready": {"lvl": 0}, "pop": {"cit": 40}, "phase": "P2"}


def _lows(fort, doc=None, state=None):
    errs, warn = plan.check(doc or _plan_doc(), state or _core_state(), decisions={}, banned=plan.BANNED, fort=fort)
    return [e for e in errs if "inside Kern+" in e], [w for w in warn if "inside Kern+" in w or "core stock" in w]


def test_core_drink_is_a_warning_where_no_stockroom_site_exists():
    e, w = _lows({"sieged": True})
    assert e and "the doctrine minimum since the fort's first siege" in e[0], "a site may exist or be unknown: the old error stands"
    e, w = _lows({"sieged": True, "stock_site": True})
    assert e, "a site exists: the stockroom is asked for"
    e, w = _lows({"sieged": True, "stock_site": False})
    assert e == [] and any("no stockroom site exists" in x and "BUG-550" in x and "420 d of drink" in x for x in w), (e, w)
    assert not any(x.startswith("core stock: add tpl stockroom") for x in w), "no hint for a template that cannot be placed"


def test_a_refuge_drink_store_counts_for_the_core_drink_not_for_food():
    fort = {"sieged": True, "refuge": {"drink_room": True}}
    e, w = _lows(fort)
    assert e == [], "the drink has its barrel store"
    e, w = _lows(fort, state=_core_state(d=200, f=50))
    assert e and "food inside Kern+" in e[0], "food still needs the stockroom"
    planned = _plan_doc()
    planned["seasons"][1]["build"].append({"tpl": "refuge_drink", "site": "S1"})
    e, w = _lows({"sieged": True}, doc=planned)
    assert e == []


def test_stock_site_is_asked_only_while_the_core_is_short(world, monkeypatch):
    save, box = world
    calls = []

    def fake(_d, tpl, params=None, snap=None, n=3, where=None, taken=None):
        calls.append(tpl)
        return [{"anchor": [1, 2, 3]}], "s", 1
    monkeypatch.setattr(plan, "free_sites", fake)
    assert plan.stock_site(save, _core_state(d=120, f=130)) is None and calls == []
    assert plan.stock_site(save, _core_state(d=50)) is True and calls == ["stockroom"]
    monkeypatch.setattr(plan, "free_sites", lambda *a, **k: ([], "s", 3))
    assert plan.stock_site(save, _core_state(f=40)) is False

    def refuse(*a, **k):
        raise cmd.BpError("bp.sites.rank(stockroom): stockroom: only 0 free site(s)")
    monkeypatch.setattr(plan, "free_sites", refuse)
    assert plan.stock_site(save, _core_state()) is False

    def nosnap(*a, **k):
        raise cmd.BpError("no snapshot: run `dfllm bp sites <tpl> --fresh`")
    monkeypatch.setattr(plan, "free_sites", nosnap)
    assert plan.stock_site(save, _core_state()) is None, "unknown is not 'no site'"


# ---------------------------------------------------------------- BUG-551
def _late(ok=False):
    return {"ok": ok, "why": "aqshaft: all 951 candidate site(s) lie on or beside placed projects", "aquifers": [127, 126, 125, 123, 120, 119, 118],
            "stops": [], "meet": [], "gap": {"bottom": 125, "below": [123], "parked": False}}


def test_no_core_why_covers_a_core_whose_stage_3_has_no_way_through_the_aquifer(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)
    fort = {"surface": {"have": False, "need": False, "aq_late": _late()}, "refuge": {"stage3": False}, "core": None}
    why = plan.no_core_why(fort)
    assert "stage 3 meets the aquifer (z127, z126, z125, z123, z120, z119)" in why and "no aqshaft column is free" in why and "951" in why
    assert plan.no_core_why({**fort, "surface": {**fort["surface"], "aq_late": _late(ok=True)}}) == "", "a route exists: stage 3 is asked for"
    assert plan.no_core_why({**fort, "refuge": {"stage3": True}}) == "", "stage 3 is under way"
    assert plan.no_core_why({**fort, "core": {"ids": ["y1s0b0"]}}) == "", "a core stopped on a breach has its own re-site"
    assert plan.no_core_why({**fort, "surface": {**fort["surface"], "have": True}}) == ""
    assert plan.no_core_why({"surface": {"have": False, "need": False}}) == ""


def _gate_state():
    return {"phase": "P2", "bridges": {"B1": "down"}, "alert": {"ref": {"ex": 1, "sep": 1, "beds": 8, "need": 8}}}


def test_stage3_gate_warns_instead_of_refusing_when_stage_3_cannot_be_built(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)
    doc = _plan_doc()
    doc["phase_target"] = "P4"
    fort = {"surface": {"have": False, "need": False, "aq_late": _late()}, "refuge": {"stage3": False, "fortcore": True}, "core": None, "o1": False}
    errs, warn = plan.stage3_gate(doc, _gate_state(), fort, None)
    assert errs == [] and len(warn) == 1 and "no fortcore can be built" in warn[0] and "z127" in warn[0], (errs, warn)
    fort["surface"]["aq_late"] = _late(ok=True)                # a column is free: the old refusal
    errs, warn = plan.stage3_gate(doc, _gate_state(), fort, None)
    assert errs and "needs O1, B2 and the refuge" in errs[0] and warn == []


def test_propose_draws_no_stage_3_that_cannot_be_built(monkeypatch):
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)
    s = {"bridges": {"B1": "down"}, "alert": {"ref": {"ex": 1, "sep": 1, "beds": 8, "need": 8}}}
    fort = {"surface": {"have": False, "need": False, "aq_late": _late()}, "refuge": {"stage3": False, "fortcore": True}, "core": None, "o1": False}
    assert plan.stage3_due(s, fort, set(), []) is False
    fort["surface"]["aq_late"] = _late(ok=True)
    assert plan.stage3_due(s, fort, set(), []) is True
    s["alert"]["ref"]["ex"] = 0
    assert plan.refuge_drafts(s, fort, set()) == [plan.REFUGE_STAGE]
    fort["surface"]["aq_late"] = _late()
    assert plan.refuge_drafts(s, fort, set()) == []


# ---------------------------------------------------------------- BUG-552
def test_a_depot_that_traded_or_another_depot_falling_is_no_lost_depot(world, monkeypatch):
    save, box = world
    _bp(save, "y9s0b0", "depot", anchor=(92, 72, 139))
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: {"depot": [84, 88, 137]})
    topple = lambda n, pos: ev(n, "BUILDING_TOPPLED", "x", {"pos": pos, "what": "Trade Depot", "by": "a war Cave Dragon", "ghost": 0}, tick=n)  # noqa: E731
    append_events(save, [ev(980, "PROJECT_DONE", "x", {"proj": "y9s0b0", "tpl": "depot"}, tick=980)])
    # the depot of the manifest fell: lost (BUG-536)
    append_events(save, [topple(990, [84, 88, 137])])
    assert plan.depot_lost(save) is True
    # a caravan traded at a depot after that: it stands again
    append_events(save, [ev(995, "CARAVAN", "x", {"civ": "Catten", "phase": "traded", "ratio": 168}, tick=995)])
    assert plan.depot_lost(save) is False
    # a depot other than the manifest's fell: no loss, the one the manifest names stands
    append_events(save, [topple(999, [94, 74, 139])])
    assert plan.depot_lost(save) is False
    # ... but not when no manifest depot is known, and a missing depot is lost whatever the manifest says
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: {})
    assert plan.depot_lost(save) is True
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: {"depot": [84, 88, 137]})
    append_events(save, [ev(1001, "DEPOT_MISSING", "x", {}, tick=1001)])
    assert plan.depot_lost(save) is True


def test_a_standing_depot_is_not_drafted_again(world, monkeypatch):
    save, box = world
    monkeypatch.setattr(plan, "_kern_manifest", lambda _d: {"depot": [84, 88, 137]})
    append_events(save, [ev(990, "BUILDING_TOPPLED", "x", {"pos": [94, 74, 139], "what": "Trade Depot", "by": "a war Cave Dragon", "ghost": 0}, tick=990)])
    assert plan.depot_planned(save, {"proj": []}) is True


# ---------------------------------------------------------------- BUG-553
def test_site_params_carries_the_depth_of_an_explore_site():
    site = {"anchor": [1, 2, 3], "rot": 0, "depth": 6, "arm": 2}
    assert cmd.site_params("explore", {}, site) == {"depth": 6, "arm": 2}
    assert cmd.site_params("explore", {"depth": 9}, site) == {"depth": 9, "arm": 2}, "p.depth given stays"
    assert cmd.site_params("explore", None, {"anchor": [1, 2, 3]}) is None
    assert cmd.site_params("bedrooms", {}, {"depth": 6}) == {}
