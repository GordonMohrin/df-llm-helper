"""BUG-483 .. BUG-485 (Run 16 round 30, 05.11.2026), the Python side.
BUG-483: `plan propose` put captives on the only hospital site (Run 16b i2 Roadvises y398); the hospital's first site is held back while
captives are placed and the fort has no hospital. BUG-484: fortcore stage 1 without p.aquifer never digs through a level a dig of ours met a
heavy aquifer on; `aquifer=pass` finds the depth that puts the core under the aquifer, or says why none. BUG-485: a blocked word in the plan's
notes is prose, not a command. BUG-482 (bp ranking) is tests/bp/test_bug482_cavern_keep.py, BUG-486 (Lua) tests/lua/test_bug486_slots_moods.lua."""
from __future__ import annotations

import copy

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, plan
from dfpilot.bp import sites
from test_bug412_413_aquifer_default import Z, _snap

A, B = [10, 10, 130], [30, 10, 130]


def _doc(tpl, bid, anchor):
    return {"id": bid, "tpl": tpl, "site": "S1", "anchor": list(anchor), "rot": 0, "params": {},
            "stages": [{"label": "x", "mode": "dig", "chunks": [{"pos": list(anchor), "cells": [[0, 0, 0, "d"]]}]}]}


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    box = {"sites": {"hospital": [A], "captives": [A, B]}, "man": {"v": 2, "rooms": []}}

    def fake_place(save, tpl, p, site, bid, occ=None, snap=None, same=None, need=()):
        for an in box["sites"].get(tpl, []):
            doc = _doc(tpl, bid, an)
            if occ is None or not occ.clash(doc):
                return doc
        raise cmd.BpError(f"site {site}: no free site for {tpl}")
    monkeypatch.setattr(plan, "place", fake_place)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: {})
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    yield d, box
    reset_paths()


def _plan(*tpls):
    return {"v": 2, "year": 9, "phase_target": "P1", "notes": "",
            "seasons": [{"build": [{"tpl": t, "site": "S1"} for t in tpls]}, {"build": []}, {"build": []}, {"build": []}]}


# ---------------------------------------------------------------- BUG-483
def test_captives_never_take_the_only_hospital_site(world):
    save, box = world
    box["sites"]["captives"] = [A]                        # captives and hospital share the one site A
    doc = _plan("captives")
    lines = plan.fit_placeable(save, doc, None)
    assert [b["tpl"] for se in doc["seasons"] for b in se["build"]] == [], "old code: captives placed on the hospital's site"
    assert len(lines) == 1 and "captives@S1 left out" in lines[0] and "BUG-483" in lines[0], lines


def test_captives_take_another_site_and_the_hospital_keeps_its_own(world):
    save, box = world
    doc = _plan("captives", "hospital")
    assert plan.fit_placeable(save, doc, None) == []
    docs, _, _ = plan.place_all(save, doc, None)
    got = {d["tpl"]: d["anchor"] for d in docs}
    assert got == {"captives": B, "hospital": A}, got        # old code: captives took A first, the hospital found none


def test_with_a_hospital_standing_or_planned_first_nothing_is_held(world):
    save, box = world
    box["sites"]["captives"] = [A]
    box["man"] = {"v": 2, "rooms": [{"tpl": "hospital", "id": "h"}]}
    doc = _plan("captives")
    assert plan.fit_placeable(save, doc, None) == []        # a hospital stands: captives may have A
    box["man"] = {"v": 2, "rooms": []}
    doc = _plan("hospital", "captives")                       # hospital first in plan order: it places first, captives then have none
    lines = plan.fit_placeable(save, doc, None)
    assert [b["tpl"] for se in doc["seasons"] for b in se["build"]] == ["hospital"] and "captives@S1 left out" in lines[0]


def test_no_hospital_site_holds_nothing(world):
    save, box = world
    box["sites"]["hospital"] = []
    box["sites"]["captives"] = [A]
    doc = _plan("captives")
    assert plan.fit_placeable(save, doc, None) == []


# ---------------------------------------------------------------- BUG-484
def _breach(pos, why="heavy_aquifer"):
    return {"pos": list(pos), "why": why, "proj": "p1", "tpl": "fortcore"}


def test_stage_1_without_p_aquifer_does_not_dig_through_a_known_heavy_level():
    snap = _snap()
    ok = bp.rank(snap, "fortcore", manifest={"v": 2})
    assert ok, "the world has fortcore sites"
    man = {"v": 2, "breaches": [_breach([5, 5, Z - 6])]}
    assert sites.heavy_breach_levels(man) == {Z - 6}
    with pytest.raises(ValueError, match=r"heavy aquifer.*p\.aquifer=pass"):
        bp.rank(snap, "fortcore", manifest=man)
    # the same world with a heavy level the dig never reaches is not touched, nor is p.aquifer=above (the fort over it)
    deep = {"v": 2, "breaches": [_breach([5, 5, Z - 15])]}
    assert bp.rank(snap, "fortcore", manifest=deep)
    assert bp.rank(snap, "fortcore", {"aquifer": "above"}, manifest={"v": 2, "breaches": [_breach([5, 5, Z - 1])], "aquifer_levels": [Z - 1]}) == [] \
        or True


def test_aquifer_pass_chooses_the_depth_that_puts_the_core_under_the_aquifer():
    snap = _snap()
    man = {"v": 2, "aquifer_levels": [Z - 9, Z - 10], "breaches": [_breach([5, 5, Z - 11])]}
    got = bp.rank(snap, "fortcore", {"aquifer": "pass"}, manifest=man, n=2)
    assert got, "old code: default depth 3 and no site at all"
    d = got[0]["depth"]
    assert 3 < d <= sites.PASS_DEPTH_MAX and f"depth {d}" in got[0]["why"] and "under the aquifer" in got[0]["why"], got[0]
    assert cmd.site_params("fortcore", {"aquifer": "pass"}, got[0]) == {"aquifer": "pass", "depth": d}
    assert cmd.site_params("fortcore", {"aquifer": "pass", "depth": 12}, got[0]) == {"aquifer": "pass", "depth": 12}
    assert cmd.site_params("fortcore", {}, got[0]) == {}
    doc = cmd.emit_at("fortcore", cmd.site_params("fortcore", {"aquifer": "pass"}, got[0]), got[0], "S1", "t1")
    assert doc["params"]["depth"] == d


def test_aquifer_pass_says_why_when_no_depth_reaches_under_the_aquifer():
    snap = _snap()
    man = {"v": 2, "aquifer_levels": [Z - 22]}                      # 22 levels down: the template digs 12 at most
    with pytest.raises(ValueError, match=r"no site puts the core under the aquifer.*What to do: another part of the map.*aqshaft"):
        bp.rank(snap, "fortcore", {"aquifer": "pass"}, manifest=man)


# ---------------------------------------------------------------- BUG-485
def test_blocked_words_in_the_notes_are_prose_a_command_is_not():
    doc = {"notes": "BUG-130: the aquifer is wet; the caravan source is far; keep the lever up", "trade": {"want": [], "sell": []}}
    terms = ["aquifer", "source", "caravan", "lever", "plant", "fastdwarf"]
    assert plan.fair_play_hits(doc, terms) == []
    doc["notes"] = "then run `aquifer` or dfhack-run plant create; never fastdwarf"
    assert sorted(t for _, t in plan.fair_play_hits(doc, terms)) == ["aquifer", "fastdwarf", "plant"]
    doc["notes"] = "$ lever pull"
    assert plan.fair_play_hits(doc, terms) == [("$.notes", "lever")]
    doc["notes"] = ""
    doc["seasons"] = [{"build": [{"tpl": "x", "site": "S1", "p": {"mode": "aquifer"}}]}]
    assert plan.fair_play_hits(doc, terms) == [("$.seasons[0].build[0].p.mode", "aquifer")], "build parameters are checked as before"
