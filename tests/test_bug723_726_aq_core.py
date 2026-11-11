"""BUG-724 (Run 16c i3 Doorwings y372, Run 16d i4 Pagedsculpture y372/y373; round 46b): the aquifer route of `plan propose` after a finished
aqshaft. (1) The core is ranked near the finished shaft (Doorwings: 30 tiles away). (2) No aquifer level known: the route no longer says
'nothing to pass' and drops the fortcore for good; a finished shaft that found none lets the core follow with p.aquifer=pass (the runner digs
it only once a shaft reached its deepest level, BUG-723), a fresh fort gets the probe shaft first. (3) `bp sites fortcore aquifer=pass` with
no aquifer known no longer claims a layer to pass. BUG-723 itself (Lua) is tests/lua/test_aqshaft.lua, BUG-725/726 the embark tools."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import plan

TOP = 148
SHAFT = [94, 98, TOP]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    box: dict = {"aq": set(), "calls": [], "man": {"v": 2}, "core_shaft": None,
                 "sites": [{"id": "S1", "anchor": [64, 106, TOP], "rot": 0, "why": "far"}],
                 "near": [{"id": "S1", "anchor": [90, 100, TOP], "rot": 0, "why": "near"}]}

    class FakeSites:
        @staticmethod
        def known_aquifer(snap, man):
            return set(box["aq"])

        @staticmethod
        def core_shaft(snap, man, anchor, rot, depth):
            if box["core_shaft"] is None:
                raise ValueError("no column")
            return dict(box["core_shaft"])

    monkeypatch.setattr(plan, "load_bp", lambda name: FakeSites)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: {"v": 2, "id": "s1", "rows": {}, "bbox": [0, 0, 100, 1, 1, 150], "marks": {}})
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "_shaft_clash", lambda *a, **k: "")

    def free(save, tpl, params=None, snap=None, n=3, where=None, **kw):
        box["calls"].append((tpl, dict(params or {}), where))
        if tpl != "fortcore":
            return [], "s1", 0
        return (box["near"] if where else box["sites"]), "s1", 1
    monkeypatch.setattr(plan, "free_sites", free)
    yield d, box
    reset_paths()


def _bp(save, pid, doc):
    (save / "bp").mkdir(parents=True, exist_ok=True)
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), encoding="utf-8")


def _shaft(save, pid="y372s0b0", bot=134, done=True, depth=15):
    _bp(save, pid, {"tpl": "aqshaft", "id": pid, "anchor": list(SHAFT), "params": {"x": 94, "y": 98, "top": TOP, "depth": depth}})
    if done:
        append_events(save, [ev(9001, "AQ_PASS_DONE", "", {"proj": pid, "top": TOP, "bot": bot, "n": 0}),
                             ev(9002, "PROJECT_DONE", "", {"proj": pid})])


def test_aq_done_shaft_names_where_it_stands_and_how_deep(world):
    save, _ = world
    assert plan.aq_done_shaft(save) is None
    _shaft(save, done=False, pid="y371s0b0")
    assert plan.aq_done_shaft(save) is None, "a shaft under way is no finished one"
    _shaft(save)
    assert plan.aq_done_shaft(save) == {"anchor": SHAFT, "bottom": 134}


def test_the_core_is_ranked_near_the_finished_shaft_that_passed_the_known_levels(world):
    save, box = world
    box["aq"] = {140, 139, 138}
    _shaft(save, bot=137)                                   # below every known level
    box["core_shaft"] = None                                # no column needed: the shaft stands
    af = plan.aquifer_route(save)
    assert af["ok"] and af["site"]["anchor"] == [90, 100, TOP], af
    assert any(c[2] and c[2]["near"] == SHAFT and c[2]["within"] == plan.AQ_CORE_NEAR for c in box["calls"]), box["calls"]
    builds, note = plan.aquifer_core_swap([{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}], af, True)
    assert [b["tpl"] for b in builds] == ["fortcore"] and builds[0]["p"]["aquifer"] == "pass", builds
    assert "beside the finished shaft at [94, 98]" in note, note


def test_a_shaft_that_did_not_pass_the_known_levels_is_no_reason_to_stay_near(world):
    save, box = world
    box["aq"] = {141, 142, 143}
    _shaft(save, bot=144)                                   # Doorwings: ended above the heavy layers that lie under it
    box["core_shaft"] = {"x": 50, "y": 50, "top": TOP, "depth": 20, "why": "col"}
    af = plan.aquifer_route(save)
    assert af["ok"] and af["site"]["anchor"] == [64, 106, TOP] and af["col"]["x"] == 50, af
    builds, _ = plan.aquifer_core_swap([{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}], af, False)
    assert [b["tpl"] for b in builds] == ["aqshaft", "fortcore"], "a second shaft is drawn, the first one never reached the layers"


def test_no_aquifer_known_and_a_finished_shaft_finds_none_the_core_follows_with_pass(world):
    save, box = world
    _shaft(save, bot=134)
    af = plan.aquifer_route(save)
    assert af["ok"] and af.get("unknown") and af["depth"] == 3 and af["site"]["anchor"] == [90, 100, TOP], af
    builds, note = plan.aquifer_core_swap([{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}], af, True)
    assert [b["tpl"] for b in builds] == ["fortcore"] and builds[0]["p"]["aquifer"] == "pass" and builds[0]["p"]["depth"] == 3
    assert "BUG-724" in note and "no aquifer level is known" in note and "found no aquifer" in note, note


def test_no_aquifer_known_a_shaft_that_ended_above_the_core_is_not_enough(world):
    save, box = world
    box["near"] = box["sites"] = [{"id": "S1", "anchor": [90, 100, 130], "rot": 0, "why": "x"}]   # the core digs down to z130-2-3-3 = z122
    _shaft(save, bot=100)                                   # the shaft went far under the core: fine
    assert plan.aquifer_route(save)["ok"]
    (save / "bp" / "y372s0b0.json").unlink()
    _shaft(save, pid="y373s0b0", bot=127)                   # ended above the core's deepest level z122
    af = plan.aquifer_route(save)
    assert not af["ok"] and "ended at z127" in af["why"], af


def test_no_aquifer_known_no_shaft_the_probe_comes_first_then_the_core(world, monkeypatch):
    save, box = world
    monkeypatch.setattr(plan, "core_probe_args", lambda d, s: ({"tpl": "aqshaft", "site": "S1",
                                                                "p": {"x": 80, "y": 90, "top": TOP, "depth": 12}}, "open ground"))
    af = plan.aquifer_route(save)
    assert af["ok"] and af["unknown"] and af["col"]["x"] == 80, af
    builds, note = plan.aquifer_core_swap([{"tpl": "seal", "site": "S1"}, {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}], af, False)
    assert [b["tpl"] for b in builds] == ["seal", "aqshaft", "fortcore"], builds
    assert builds[2]["p"]["aquifer"] == "pass" and "probe aqshaft@80,90" in note, (builds, note)


def test_no_aquifer_known_and_a_shaft_under_way_waits(world):
    save, _ = world
    _shaft(save, done=False)
    af = plan.aquifer_route(save)
    assert not af["ok"] and "under way" in af["why"], af
    builds, note = plan.aquifer_core_swap([{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}], af, True)
    assert builds == [] and "under way" in note


def test_pass_with_no_aquifer_known_says_there_is_nothing_to_pass():
    from dfpilot.bp import sites
    from test_bug412_413_aquifer_default import _snap
    snap = _snap()
    snap["bbox"] = list(snap["bbox"])
    with pytest.raises(ValueError) as e:
        sites._rank_pass(snap, {"aquifer": "pass", "size": 99}, {"v": 2}, 1, None, None, None, None, lambda c: False)
    msg = str(e.value)
    assert "no aquifer level is known" in msg and "known levels none" not in msg and "under the aquifer" not in msg, msg
