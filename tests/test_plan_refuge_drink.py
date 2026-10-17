"""FR-69 refuge drink store (Run 11, Kilrudrabed y477, kernel b23b5d4: Tiefe+ drink 0, wells 1 (dry), 59 beds, 212
tiles; 1199 of the fort's 1493 drinks in the Kern+ stockpile `dfllm-stock`; readiness R0 refuge_dry; `bp sites
cistern` offered only far sites). While readiness says refuge_dry, `plan check` warns with the fix (the refuge drink
store, sized from the citizens) and `plan propose` drafts it with the refuge pieces, not a cistern far away."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, append_events, ev, make_runtime, reset_paths

from dfpilot import files, plan, schema

STORE = {"tpl": "refuge_drink", "site": "S1", "p": {"n": 11}}          # 52 citizens: 52 drinks at 5 a barrel


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def dry(state, dr=0, dn=52, st=None, fail=("refuge_dry",)):
    """The fixture state (52 citizens) with a separated refuge with beds whose drink readiness calls short."""
    s = copy.deepcopy(state)
    s["alert"] = {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1,
                  "ref": {"ex": 1, "sep": 1, "beds": 13, "need": 13}}
    if dr is not None:
        s["alert"]["ref"].update(dr=dr, dn=dn)
    if st is not None:
        s["alert"]["ref"]["st"] = st
    s["ready"]["fail"] = list(fail)
    assert schema.validate("state", s) == []
    return s


def refuge_lines(doc, state, **kw):
    kw.setdefault("decisions", {})
    kw.setdefault("banned", plan.BANNED)
    errs, warn = plan.check(doc, state, **kw)
    return [e for e in errs if e.startswith("refuge")], [w for w in warn if w.startswith("refuge")]


FIX_TEXT = ('refuge: Tiefe+ has no drink (readiness R0 refuge_dry: drink 0<52): add '
            '{"tpl":"refuge_drink","site":"S1","p":{"n":11}} (FR-69: a drink store dug off the refuge room, 11 barrels '
            'for 52 citizens; dfllm plan propose drafts it)')


def test_check_warns_with_the_store_fix(base):
    prev, state = base
    doc = copy.deepcopy(prev)
    assert refuge_lines(doc, dry(state), prev=prev) == ([], [FIX_TEXT])            # old code: nothing
    older = dry(state, dr=None)                                                 # a kernel without alert.ref.dr
    assert refuge_lines(doc, older, prev=prev)[1] == [FIX_TEXT.replace(": drink 0<52)", ")")]
    assert refuge_lines(doc, dry(state, fail=()), prev=prev) == ([], [])          # readiness: not dry
    # planned in this plan, or one under way: no warning
    fixed = copy.deepcopy(doc)
    fixed["seasons"][2]["build"].append({"tpl": "refuge_drink", "site": "S1", "p": {"n": 8}})
    assert refuge_lines(fixed, dry(state), prev=prev) == ([], [])
    assert refuge_lines(doc, dry(state), prev=prev, fort={"refuge": {"drink": 11}}) == ([], [])
    # the store stands (the kernel sees its pile on Tiefe+, or its room is in the manifest) and is still short
    stands = ("refuge: Tiefe+ has no drink yet (readiness R0 refuge_dry: drink 3<52) though its drink store stands "
              "(15 tiles): it fills as the haulers bring barrels in (it takes from dfllm-stock; brew more while the "
              "fort's drink is low); dfllm cmd inspect what=refuge")
    assert refuge_lines(doc, dry(state, dr=3, st=15), prev=prev) == ([], [stands])
    assert refuge_lines(doc, dry(state, dr=3), prev=prev, fort={"refuge": {"drink_room": True}})[1] == [
        stands.replace(" (15 tiles)", "")]
    # the ranking found room only for a smaller store, or none at all
    small = refuge_lines(doc, dry(state), prev=prev, fort={"refuge": {"drink_fit": 6}})[1]
    assert small == [FIX_TEXT.replace('{"n":11}', '{"n":6}').replace("11 barrels for 52 citizens",
                                                                       "6 barrels: room for 6 of 11 for 52 citizens")]
    why = "refuge_drink: no site beside the refuge room 50-58,62-68 z3: not even a 3x1 store (2 barrels) ..."
    none = refuge_lines(doc, dry(state), prev=prev, fort={"refuge": {"drink_fit": 0, "drink_why": why}})[1]
    assert none == [f"refuge: Tiefe+ has no drink (readiness R0 refuge_dry: drink 0<52): no site for refuge_drink: {why} "
                    "(dfllm bp sites refuge_drink)"]


def test_propose_drafts_the_store_not_a_cistern(base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
             for t in ("fortcore", "tombs", "temple", "seal", "refuge_beds", "refuge_drink", "stockroom", "cistern")}

    def new(doc):
        return [b for si, se in enumerate(doc["seasons"]) for b in se["build"][len(prev["seasons"][si]["build"]):]]

    s = dry(state)
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={})
    got = new(doc)
    assert got[0] == STORE, got                                   # old code: the phases' builds only
    assert not any(b["tpl"] == "cistern" for b in got)
    assert refuge_lines(doc, s, prev=prev) == ([], [])
    # beds short too: the beds first, then the store (both refuge pieces, before the other builds)
    beds = copy.deepcopy(s)
    beds["alert"]["ref"].update(beds=8, need=28)
    got = new(plan.propose(beds, phases, prev, decisions={}, tinfo=tinfo, fort={}))
    assert got[:2] == [{"tpl": "refuge_beds", "site": "S1", "p": {"n": 20}}, STORE]
    # no core stockroom to take from: no link
    got = new(plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={"stockroom": False}))
    assert got[0] == {"tpl": "refuge_drink", "site": "S1", "p": {"n": 11, "take": ""}}
    # only room for a smaller one: that one
    got = new(plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={"refuge": {"drink_fit": 6}}))
    assert got[0] == {"tpl": "refuge_drink", "site": "S1", "p": {"n": 6}}
    # nothing to draft: not dry, under way, standing, no site, applied before, no template
    for st, ft, ti in ((dry(state, fail=()), {}, tinfo), (s, {"refuge": {"drink": 11}}, tinfo),
                       (dry(state, st=15), {}, tinfo), (s, {"refuge": {"drink_room": True}}, tinfo),
                       (s, {"refuge": {"drink_fit": 0}}, tinfo),
                       (s, {}, {k: v for k, v in tinfo.items() if k != "refuge_drink"})):
        got = new(plan.propose(st, phases, prev, decisions={}, tinfo=ti, fort=ft))
        assert all(b["tpl"] != "refuge_drink" for b in got), (st["alert"], ft)
    applied = {("refuge_drink", None)}
    got = new(plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={}, applied=applied))
    assert all(b["tpl"] != "refuge_drink" for b in got)
    # a store of the runner's supply kind (runner.lua kind_of SUPPLY): it runs under the rebuild policy
    assert plan.build_kind(STORE) == "supply"


def test_fort_facts_know_the_store(save, base):
    from dfpilot import cmd
    _, state = base

    def stub(bid, params):
        return {"v": 2, "id": bid, "tpl": "refuge_drink", "site": "S1", "class": "infra", "params": params,
                "anchor": [50, 33, 120], "rot": 0, "stages": [{"label": "dig", "mode": "dig", "orders": 0,
                "defense": 0, "chunks": [{"pos": [50, 34, 120], "cells": [[0, 0, 0, "d"]]}]}],
                "manifest": {"v": 2, "rooms": [{"id": f"refuge_d{bid}", "tpl": "refuge_drink", "use": "utility",
                                                "bbox": [49, 35, 120, 51, 36, 120], "tier": 0}]},
                "materials": {}}
    f = plan.fort_facts(save, dry(state, fail=()))["refuge"]
    assert (f["drink"], f["drink_room"], f["drink_fit"], f["drink_why"]) == (0, False, None, None)   # not dry: not ranked
    # dry: the store is ranked on the sites snapshot (the fixture's fortcore stops at stage 2: no refuge room yet)
    f = plan.fort_facts(save, dry(state))["refuge"]
    assert f["drink_fit"] == 0 and "no refuge in the fort manifest" in f["drink_why"], f
    cmd.write_bp(save, stub("c7", {"n": 9, "take": "dfllm-stock", "burrow": "Tiefe+"}))
    f = plan.fort_facts(save, dry(state))["refuge"]
    assert f["drink"] == 9
    append_events(save, [ev(8813, "PROJECT_DONE", "c7 done", {"proj": "c7"})])
    f = plan.fort_facts(save, dry(state))["refuge"]
    assert (f["drink"], f["drink_room"]) == (0, True)               # done: its room is in the fort manifest
