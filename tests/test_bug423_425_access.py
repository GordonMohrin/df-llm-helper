"""BUG-424 (follow places the piped cistern from the water nearest to the fort; propose drafts it) and BUG-425 (the config key).
Fails on 03f4c1a."""
import json
import sys

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths
from test_cli_wake import Clock, F, save  # noqa: F401  (fixtures)

from dfpilot import fairplay, files, plan, wake

PARAMS = {"path": "1,6;1,12;8,12", "rise": 3, "side": "E", "water": "bed"}


def fake_access(unsafe=False, plan_ok=True):
    def cistern_access(snap, manifest, near=None, radius=20, level=None):
        if not plan_ok:
            return {"plan": None, "unsafe": False, "level": "core", "site": None, "why": "no revealed water in the snapshot"}
        return {"plan": {"params": PARAMS, "site": {"id": "S1", "anchor": [40, 30, 120], "rot": 1}, "rock": 1,
                         "why": "pipe 14 tiles, sealed rock intake"}, "unsafe": unsafe, "level": "core",
                "site": "A40_30_120_1"}
    return cistern_access


def _request_and_snapshot(save, f, c=None):
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "cistern: no water", {"tpl": "cistern", "why": "no_water", "n": 8,
                                                                            "at": [102, 72, 158]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8815, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    if c is not None:
        c.t += 11                                     # the wake gate's quiet time
        f.poll()


def test_follow_places_the_piped_cistern_from_the_nearest_water(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    sys.modules["dfpilot.bp.sites"].cistern_access = fake_access()
    f, out = F(Clock())
    _request_and_snapshot(save, f)
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    assert place["args"] == {"tpl": "cistern", "site": "A40_30_120_1", "p": PARAMS, "prio": 1}
    assert out == []                                  # class B: no wake line


def test_follow_does_not_place_an_unsafe_route_and_says_so(save, monkeypatch):
    install_fake_bp(monkeypatch)
    sys.modules["dfpilot.bp.sites"].cistern_access = fake_access(unsafe=True)
    c = Clock()
    f, out = F(c)
    _request_and_snapshot(save, f, c)
    assert inbox_docs(save) == []
    wakes = " ".join(out)
    assert "AUTO_FAIL" in wakes and "BUG-424" in wakes and "above the well room" in wakes and "102,72,158" in wakes, wakes


def test_follow_names_the_refusal_without_a_route(save, monkeypatch):
    install_fake_bp(monkeypatch)
    sys.modules["dfpilot.bp.sites"].cistern_access = fake_access(plan_ok=False)
    c = Clock()
    f, out = F(c)
    _request_and_snapshot(save, f, c)
    assert inbox_docs(save) == []
    assert "no safe access to the water at 102,72,158: no revealed water" in " ".join(out)


def test_no_second_request_while_a_piped_cistern_is_placed(save, monkeypatch):
    install_fake_bp(monkeypatch)
    sys.modules["dfpilot.bp.sites"].cistern_access = fake_access()
    files.write_json_atomic(save / "bp" / "y1s0b0.json", {"tpl": "cistern", "params": PARAMS})
    f, out = F(Clock())
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "cistern", {"tpl": "cistern", "why": "no_water", "n": 8, "at": [1, 2, 3]})])
    f.poll()
    assert inbox_docs(save) == []


def test_config_keys():
    assert fairplay.WATER_LIM["well_emerg"] == (0, 7)
    assert fairplay.ECONOMY_LIM["drink"]["access_d"] == (0, 400)


def test_request_drafts_the_piped_cistern_and_names_an_unsafe_one():
    acc = {"site": "A40_30_120_1", "params": PARAMS, "unsafe": False, "rock": 1, "why": "x"}
    fort = {"requests": [{"tpl": "cistern", "why": "no_water", "at": [102, 72, 158], "n": 8, "access": acc}]}
    out, note = plan.request_drafts({}, fort, set(), [], None)
    assert out == [{"tpl": "cistern", "site": "A40_30_120_1", "p": PARAMS}]
    assert "BUG-418" in note and "cistern piped from the water at 102,72,158 (sealed rock intake)" in note
    fort["requests"][0]["access"] = {**acc, "unsafe": True}
    out, note = plan.request_drafts({}, fort, set(), [], None)
    assert out == [] and "Gordon decides" in note and "--unsafe" in note
    fort["requests"][0]["access"] = {"why": "no sites snapshot"}
    out, note = plan.request_drafts({}, fort, set(), [], None)
    assert out == [] and "no sites snapshot" in note


# ---------------------------------------------------------------- request_facts / water_access
from test_bug418_419_requests_wet_core import DAY, T0, _req, _state, world  # noqa: E402,F401  (the world fixture)


def test_request_facts_carries_the_water_and_its_access(world, monkeypatch):
    save, _ = world
    n0 = files.last_event_n(save) + 100
    monkeypatch.setattr(plan, "water_access", lambda d, at: {"site": "A1_2_3_0", "params": PARAMS, "unsafe": False, "rock": 1, "why": "w"})
    append_events(save, [_req(n0, "cistern", {"why": "no_water", "n": 8, "at": [102, 72, 158]}, T0 - 2 * DAY),
                         _req(n0 + 1, "cistern", {"why": "something else"}, T0 - DAY)])
    got = plan.request_facts(save, _state(save))
    assert got == [{"tpl": "cistern", "why": "no_water", "at": [102, 72, 158], "n": 8,
                    "access": {"site": "A1_2_3_0", "params": PARAMS, "unsafe": False, "rock": 1, "why": "w"}}], got
    (save / "bp").mkdir(exist_ok=True)                 # a bucket-fed cistern (no pipe) does not answer it
    (save / "bp" / "y1s0b0.json").write_text(json.dumps({"tpl": "cistern", "anchor": [1, 2, 3], "rot": 0, "params": {}}))
    assert plan.request_facts(save, _state(save))[0]["tpl"] == "cistern"
    (save / "bp" / "y1s0b0.json").write_text(json.dumps({"tpl": "cistern", "anchor": [1, 2, 3], "rot": 0, "params": PARAMS}))
    assert plan.request_facts(save, _state(save)) == []


def test_water_access_reads_the_planner_and_reports_why_not(world, monkeypatch):
    save, box = world
    import types
    sites = types.SimpleNamespace(cistern_access=fake_access(unsafe=True))
    monkeypatch.setattr(plan, "load_bp", lambda part: sites)
    a = plan.water_access(save, [102, 72, 158])
    assert a["site"] == "A40_30_120_1" and a["unsafe"] is True and a["rock"] == 1 and a["params"] == PARAMS
    sites.cistern_access = fake_access(plan_ok=False)
    assert plan.water_access(save, [1, 2, 3]) == {"why": "no revealed water in the snapshot"}
    box["snap"] = None
    assert "no sites snapshot" in plan.water_access(save, [1, 2, 3])["why"]
