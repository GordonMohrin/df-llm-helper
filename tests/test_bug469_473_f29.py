"""BUG-469..473 (Run 16a-d, round 29 water/seal): the cisterns that could not fill, the patient request without a tile, the depot before the
first caravan. The Lua parts are in tests/lua/test_bug469_473.lua.
BUG-469: i3/i4 cisterns stood 87-106 tiles from the pond zone, bucket-fed, the wells dry for 30 days: cmd.cistern_fill_guard turns a plain
  cistern into the aquifer cistern (or refuses it) when no revealed water lies within sites.BUCKET_STEPS_MAX steps of the core.
BUG-470 (follow side): PROJECT_REQUEST cistern why=patient_water without a tile (i4: nothing was placed) now places the aquifer cistern.
BUG-473: a core that waits for the aquifer shaft gets the surface depot in the same draft."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema, wake
from dfpilot.bp import sites

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402

CIS_AQ = {"tpl": "cistern", "site": "S1", "p": {"water": "aquifer"}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


# ---------------------------------------------------------------- BUG-469
def test_fill_source_marks_water_farther_than_the_carriers_walk(fort, monkeypatch):
    snap, man = fort
    near = sites.fill_source(snap, man)
    assert near["ok"] is True and near["steps"] > 1 and near["far"] is (near["steps"] > sites.BUCKET_STEPS_MAX)
    monkeypatch.setattr(sites, "BUCKET_STEPS_MAX", near["steps"] - 1)
    far = sites.fill_source(snap, man)
    assert far["ok"] is True and far["far"] is True and far["steps"] == near["steps"] and far["at"]
    assert f"(> {near['steps'] - 1}: too far for bucket carriers)" in far["why"], far
    monkeypatch.setattr(sites, "BUCKET_STEPS_MAX", near["steps"])
    assert sites.fill_source(snap, man)["far"] is False


def _guard(save, monkeypatch, fill, aq, params, snap=None):
    class FakeSites:
        @staticmethod
        def fill_source(s, m):
            return fill

        @staticmethod
        def known_aquifer(s, m):
            return {120} if aq else set()
    monkeypatch.setattr(cmd, "load_bp", lambda name: FakeSites)
    monkeypatch.setattr(cmd, "fort_manifest", lambda d: {"v": 2})
    monkeypatch.setattr(cmd, "sites_snapshot", lambda d: {"id": "s"})
    return cmd.cistern_fill_guard(save, params, snap, "y1s0b0")


FAR = {"ok": True, "far": True, "steps": 101, "at": [1, 2, 3], "why": "revealed water at 1,2,3, 101 steps from the core (> 40)"}
DRY = {"ok": False, "steps": None, "at": None, "why": "no revealed brook, river or lake (>= 8 tiles) on snapshot s"}


def test_far_water_and_a_known_aquifer_makes_the_aquifer_cistern(save, monkeypatch):
    p = _guard(save, monkeypatch, FAR, True, {"level": "core"})
    assert p == {"level": "core", "water": "aquifer"}
    assert "placed p.water=aquifer" in cmd.PLACE_NOTES["y1s0b0"] and "101 steps" in cmd.PLACE_NOTES["y1s0b0"]


def test_far_water_without_an_aquifer_refuses_the_dry_cistern(save, monkeypatch):
    with pytest.raises(cmd.BpError, match=r"BUG-469: a bucket-fed cistern .* would stay dry: .*101 steps.*no aquifer level is known"):
        _guard(save, monkeypatch, FAR, False, {})
    with pytest.raises(cmd.BpError, match=r"would stay dry: no revealed brook"):
        _guard(save, monkeypatch, DRY, False, {})
    assert _guard(save, monkeypatch, DRY, True, {}) == {"water": "aquifer"}


def test_pipe_aquifer_near_water_and_unknown_pass_unchanged(save, monkeypatch):
    assert _guard(save, monkeypatch, FAR, True, {"path": "1,6;1,9;4,9"}) == {"path": "1,6;1,9;4,9"}
    assert _guard(save, monkeypatch, FAR, True, {"water": "aquifer"}) == {"water": "aquifer"}
    assert _guard(save, monkeypatch, {"ok": True, "far": False, "steps": 12}, True, {"level": "core"}) == {"level": "core"}
    assert _guard(save, monkeypatch, {"ok": None, "why": "no core"}, True, {}) == {}


def test_place_applies_the_guard_to_a_cistern_only(save, monkeypatch):
    seen = []
    monkeypatch.setattr(cmd, "cistern_fill_guard", lambda d, p, s, b="": seen.append(p) or dict(p or {}, water="aquifer"))
    for tpl, p in (("cistern", {"level": "core"}), ("tombs", {})):
        try:
            cmd._place(save, tpl, p, "S1", "y1s0b0")          # may fail or succeed later on this fixture: only the guard call counts
        except Exception:      # noqa: BLE001
            pass
    assert seen == [{"level": "core"}]


# ---------------------------------------------------------------- BUG-470 (follow)
def _follower(save, monkeypatch):
    f = wake.Follower(save=str(save), out=lambda line: None, clock=lambda: 1000.0)
    f.dir = save
    sent = []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **k: sent.append((verb, args, what)) or "c1")
    return f, sent


def test_patient_water_without_a_tile_places_the_aquifer_cistern(save, monkeypatch):
    f, sent = _follower(save, monkeypatch)
    f._request_access({"tpl": "cistern", "why": "patient_water", "n": 114}, 1000.0)
    j = f.jobs["cistern_water"]
    assert j["tpl"] == "cistern" and j["params"] == {"water": "aquifer"} and not j.get("access") and j["prio"] == 1
    assert sent == [("snapshot", {"purpose": "sites"}, "cistern snapshot")]


def test_no_water_request_without_a_tile_still_waits_for_one(save, monkeypatch):
    f, sent = _follower(save, monkeypatch)
    f._request_access({"tpl": "cistern", "why": "no_water", "n": 114}, 1000.0)
    assert "cistern_water" not in f.jobs and sent == []


def test_an_aquifer_cistern_project_answers_the_request_once(save, monkeypatch):
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / "y1s0b0.json").write_text(json.dumps({"tpl": "cistern", "params": {"water": "aquifer"}}), "utf-8")
    f, sent = _follower(save, monkeypatch)
    f._request_access({"tpl": "cistern", "why": "patient_water", "n": 114}, 1000.0)
    assert sent == [] and "cistern_water" not in f.jobs


def test_masonry_request_is_a_workshops_request():
    src = Path(wake.__file__).read_text("utf-8")
    assert '"masonry"' in src


# ---------------------------------------------------------------- BUG-473 (depot)
def tinfo():
    return {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
            for t in ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "cistern",
                      "traps", "depot", "aqshaft")}


def built(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_depot_is_drafted_for_a_core_that_waits_for_the_aquifer_shaft(save):
    state = files.read_state(save)
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    base = {"depot": False, "aqshaft": True}
    doc = plan.propose(copy.deepcopy(state), phases, None, decisions={}, tinfo=tinfo(), applied=set(), fort=base)
    assert schema.validate("plan", doc) == []
    b = built(doc)
    assert plan.DEPOT_BUILD in b and "before the first caravan" in doc["notes"], doc["notes"]
    # no shaft: the note is BUG-368's as before
    doc2 = plan.propose(copy.deepcopy(state), phases, None, decisions={}, tinfo=tinfo(), applied=set(), fort={"depot": False})
    assert "waits for the aquifer shaft" not in doc2["notes"]
