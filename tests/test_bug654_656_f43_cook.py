"""Round 43 (cook; offline, live-untested), Python side. The Lua parts are in tests/lua/test_bug654_656_cut_shops.lua and
tests/lua/test_bug655_hospital_beds.lua.
BUG-654 (Run 16a i1 Basementflew: meals 0 for years, the only Kitchen stood in the flooded level z117): the kernel's PROJECT_REQUEST workshops
         why=cut names the shop types no citizen can walk to; follow places a NEW one although the fort manifest lists the cut-off one,
         `plan propose` drafts it (request_facts keeps a cut type the manifest has).
BUG-656 (the same fort y464: `bp.place workshops only=Kitchen rebuild=1` refused 'taken [78,100,131] by c1a1ab437a0e153311 (workshops
         finished)'): a rebuild is not held back by a FINISHED project, a running one still holds its tiles."""
import json

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import cmd, files, plan, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1_792_251_900.0):
        self.t = t

    def __call__(self):
        return self.t


def _manifest_with_kitchen(save):
    from dfpilot.bp.rooms import MOODABLE_TYPES
    for p in cmd.bp_files(save):
        p.unlink()
    files.write_json_atomic(save / "bp" / "w433.json", {
        "v": 2, "id": "w433", "tpl": "workshops", "site": "S1", "class": "infra", "params": {}, "anchor": [60, 40, 120],
        "rot": 0, "stages": [], "materials": {},
        "manifest": {"v": 2, "workshops": [{"type": t, "pos": [61 + i, 41, 120]} for i, t in enumerate(MOODABLE_TYPES)]
                     + [{"type": "Kitchen", "pos": [29, 112, 117]}]}})
    assert cmd.workshops_missing(save, ["Kitchen"]) == [], "the manifest lists the cut-off kitchen: it is not missing for the old tests"


def test_follow_cut_request_places_a_new_kitchen_although_the_manifest_lists_one(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    _manifest_with_kitchen(save)
    f = wake.Follower(out=lambda s: None, clock=Clock())
    f.poll()
    append_events(save, [ev(18902, "PROJECT_REQUEST", "workshops: cut off from the citizens (Kitchen at 29,112,117 (walk group 9, the citizens on 7)): Kitchen",
                            {"tpl": "workshops", "n": 1, "why": "cut", "types": ["Kitchen"]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and f.jobs["cut"]["need"] == ["Kitchen"], f.jobs
    assert f.jobs["cut"]["params"].get("add") == "Kitchen"
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(18903, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert calls["emit"][-1][1].get("add") == "Kitchen", calls["emit"][-1]


def test_request_facts_keeps_a_cut_type_the_manifest_has(save):
    _manifest_with_kitchen(save)
    append_events(save, [ev(100, "PROJECT_DONE", "x", {"proj": "w433", "tpl": "workshops"}, tick=100)])      # the hall was built long ago
    append_events(save, [
        ev(18902, "PROJECT_REQUEST", "x", {"tpl": "workshops", "n": 2, "why": "cut", "types": ["Carpenters", "Kitchen"]}),
        ev(18903, "PROJECT_REQUEST", "x", {"tpl": "workshops", "n": 1, "why": "missing", "types": ["Kitchen"]})])
    reqs = [r for r in plan.request_facts(save, {}) if r["tpl"] == "workshops"]
    assert reqs and set(reqs[0]["types"]) == {"Carpenters", "Kitchen"}, reqs      # old code: both are in the manifest, nothing drafted
    # no cut request: a type the manifest has is not asked for
    other = save / "events.jsonl"
    other.write_text("", encoding="utf-8")
    append_events(save, [ev(18904, "PROJECT_REQUEST", "x", {"tpl": "workshops", "n": 1, "why": "missing", "types": ["Kitchen"]})])
    assert [r for r in plan.request_facts(save, {}) if r["tpl"] == "workshops"] == []


def test_a_finished_project_does_not_hold_a_rebuild_a_running_one_does(save, monkeypatch):
    params = {"only": "Kitchen", "rebuild": 1}
    append_events(save, [ev(900, "PROJECT_DONE", "x", {"proj": "c1a1ab437a0e153311", "tpl": "workshops"}, tick=900)])
    assert cmd.rebuild_free(save, "workshops", params, ["c1a1ab437a0e153311"]) == []
    assert cmd.rebuild_free(save, "workshops", params, ["c1a1ab437a0e153311", "y400s0b1"]) == ["y400s0b1"]
    assert cmd.rebuild_free(save, "workshops", {"only": "Kitchen"}, ["c1a1ab437a0e153311"]) == ["c1a1ab437a0e153311"], "a plain placement is unchanged"
    assert cmd.rebuild_free(save, "dining", params, ["c1a1ab437a0e153311"]) == ["c1a1ab437a0e153311"]
    monkeypatch.setattr(files, "read_state", lambda d: {"proj": [["c1a1ab437a0e153311", "build", 40, ""]]})
    assert cmd.rebuild_free(save, "workshops", params, ["c1a1ab437a0e153311"]) == ["c1a1ab437a0e153311"], "the kernel still has a row for it"


@pytest.mark.parametrize("why", ["manager", "missing", "gear", "well", "masonry", "trade", "cut"])
def test_every_workshops_request_why_follow_answers_has_a_place_key(why):
    """BUG-654: the request's job is keyed by its why; a key missing from PLACE_KEYS got its snapshot and was never placed."""
    assert why in wake.PLACE_KEYS
