"""BUG-418 / BUG-419 (Run 16b/16d, 05.11.2026).
BUG-418 (Run 16d i4 Mazelanterns: `bedrooms x19: free 0 < homeless 15 + 4` every ~9 days, 15 homeless, `mood shops missing 4124
days`, refuge_dry for years; the player added bedrooms, refuge_beds, workshops only=... and refuge_drink by hand every year):
`plan propose` drafts the open PROJECT_REQUESTs (once, deduplicated), the moodable shops R0 mood_ws names and refuge_drink while
R0 says refuge_dry.
BUG-419 (Run 16b i2 Ostgate event #5420: follow placed a wet fortcore, score 0, after PLAN_EXHAUSTED): follow's own fortcore never
takes a wet site (score 0 / aquifer reason) without the aqshaft route (BUG-412); it says why instead."""
from __future__ import annotations

import copy
import json

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import cmd, files, plan, wake
from test_bug412_413_aquifer_default import AQ, Z, _snap  # noqa: F401  (the aquifer world)

T0 = 3 * 403200 + 124000
DAY = 1200


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    box = {"snap": _snap(), "man": {"v": 2, "aquifer_levels": list(AQ)}}
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    # the fixture's four projects are done long ago (a bedrooms project under way would close every bedrooms request)
    n = files.last_event_n(d) + 10
    append_events(d, [ev(n + i, "PROJECT_DONE", "", {"proj": pid}, tick=T0 - 300 * DAY)
                      for i, pid in enumerate(("y3s0b0", "y3s0b1", "y3s1b0", "y3s2b0"))])
    yield d, box
    reset_paths()


def _state(save, phase="P1", **extra):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = phase
    s["proj"] = []
    s.update(extra)
    return s


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def _req(n, tpl, d, tick):
    return ev(n, "PROJECT_REQUEST", f"{tpl} request", {"tpl": tpl, **d}, tick=tick)


# ---------------------------------------------------------------- BUG-418: request facts
def test_open_requests_newest_per_template_stone_dig_requests_and_old_ones_left_out(world):
    save, _ = world
    n0 = files.last_event_n(save) + 100
    append_events(save, [
        _req(n0 + 5, "refuge_beds", {"n": 2, "why": "beds"}, T0 - 100 * DAY),         # older than 40 days: not open
        _req(n0, "bedrooms", {"n": 9, "why": "free 0 < homeless 11 + 4"}, T0 - 30 * DAY),
        _req(n0 + 1, "bedrooms", {"n": 19, "why": "free 0 < homeless 15 + 4"}, T0 - 9 * DAY),
        _req(n0 + 2, "bedrooms", {"n": 4, "why": "rock"}, T0 - 2 * DAY),             # a stone dig: follow places it
        _req(n0 + 4, "tombs", {"why": "memorial"}, T0),
    ])
    got = plan.request_facts(save, _state(save))
    assert got == [{"tpl": "bedrooms", "n": 19, "why": "free 0 < homeless 15 + 4"}], got


def test_a_request_is_closed_by_a_later_project_done_or_a_project_under_way(world):
    save, _ = world
    n0 = files.last_event_n(save) + 100
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / "y1s0b0.json").write_text(json.dumps({"tpl": "bedrooms", "anchor": [1, 2, 3], "rot": 0, "params": {"n": 19}}))
    append_events(save, [_req(n0, "bedrooms", {"n": 19, "why": "free 0 < homeless 15 + 4"}, T0 - 5 * DAY)])
    # the bedrooms project is neither done nor parked: under way, nothing to draft
    assert plan.request_facts(save, _state(save)) == []
    # parked (state.proj says so): the request stays open
    st = _state(save, proj=[["y1s0b0", "s0.dig", 0, "parked: breach"]])
    assert plan.request_facts(save, st)[0]["tpl"] == "bedrooms"
    # done after the request: closed
    append_events(save, [ev(n0 + 1, "PROJECT_DONE", "", {"proj": "y1s0b0"}, tick=T0 - DAY)])
    assert plan.request_facts(save, st) == []
    # asked again after the project was done: open again
    append_events(save, [_req(n0 + 2, "bedrooms", {"n": 6, "why": "free 0 < homeless 2 + 4"}, T0)])
    (save / "bp" / "y1s0b0.json").unlink()
    assert plan.request_facts(save, _state(save)) == [{"tpl": "bedrooms", "n": 6, "why": "free 0 < homeless 2 + 4"}]


# ---------------------------------------------------------------- BUG-418: the draft
FORT = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True}


def test_propose_drafts_the_open_requests_once(world):
    save, _ = world
    fort = dict(FORT, requests=[{"tpl": "bedrooms", "n": 19, "why": "free 0 < homeless 15 + 4"},
                                {"tpl": "refuge_beds", "n": 2, "why": "beds"}])
    s = _state(save, phase="P2")
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    bs = _builds(doc)
    assert [b for b in bs if b["tpl"] == "bedrooms" and b.get("p") == {"n": 19}], bs
    assert len([b for b in bs if b["tpl"] == "refuge_beds" and b.get("p") == {"n": 2}]) == 1, bs
    assert "BUG-418" in doc["notes"] and "bedrooms n=19" in doc["notes"], doc["notes"]
    # a draft made again on top of the plan applied (the same builds are in prev) repeats nothing
    again = plan.propose(s, plan.load_phases(), doc, decisions={}, applied=plan.applied_builds(save, s), fort=fort)
    assert len([b for b in _builds(again) if b["tpl"] == "bedrooms" and b.get("p") == {"n": 19}]) == 1
    # no request, nothing extra
    plain = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=FORT)
    assert "BUG-418" not in plain["notes"] and not [b for b in _builds(plain) if (b.get("p") or {}) == {"n": 19}]


def test_propose_drafts_the_mood_shops_r0_names_with_skip_of_the_others(world):
    save, _ = world
    mood = cmd._moodable()
    if len(mood) < 3:
        pytest.skip("no bp package")
    want = [mood[0], mood[2]]
    doc = plan.propose(_state(save, phase="P2"), plan.load_phases(), None, decisions={}, applied=set(),
                       fort=dict(FORT, mood_ws=want))
    ws = [b for b in _builds(doc) if b["tpl"] == "workshops" and "skip" in (b.get("p") or {})]
    assert len(ws) == 1, _builds(doc)
    assert set(ws[0]["p"]["skip"].split(",")) == set(mood) - set(want), ws
    assert "workshops " + ",".join(want) in doc["notes"]


def test_mood_ws_missing_reads_r0_and_the_fort_manifest(world, monkeypatch):
    save, _ = world
    monkeypatch.setattr(cmd, "workshops_missing", lambda d, types=None: ["Loom", "Jewelers"])
    assert plan.mood_ws_missing(save, {"ready": {"fail": ["mood_ws"]}}) == ["Loom", "Jewelers"]
    assert plan.mood_ws_missing(save, {"ready": {"fail": ["audit"]}}) == []
    assert plan.mood_ws_missing(save, {}) == []


def test_refuge_drink_is_drafted_for_the_part_a_standing_store_lacks_while_r0_says_refuge_dry(world):
    save, _ = world
    s = _state(save, phase="P2")
    s["ready"] = {**s["ready"], "fail": ["refuge_dry"]}
    s["alert"] = {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1,
                  "ref": {"ex": 1, "sep": 1, "beds": 13, "need": 13, "dr": 0, "dn": 52, "st": 6}}      # a 6 tile store stands
    want = plan.drink_want(s)
    assert isinstance(want, int) and want > 6, want
    fort = dict(FORT, refuge={"drink": 0, "drink_fit": want, "bed_site": None, "beds": 0})
    # the old rule: a standing store is waited for
    assert plan.drink_draft(s, fort, set()) is None
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("refuge_drink", None)}, fort=fort)
    drinks = [b for b in _builds(doc) if b["tpl"] == "refuge_drink"]
    assert len(drinks) == 1 and drinks[0]["p"]["n"] == want - 6, drinks
    assert "refuge_drink (R0 refuge_dry)" in doc["notes"]
    # a store of the right size waits for barrels; one under way or without a site: not again
    s["alert"]["ref"]["st"] = want
    assert plan.drink_draft(s, fort, set(), force=True) is None
    s["alert"]["ref"]["st"] = 6
    assert plan.drink_draft(s, dict(fort, refuge={"drink": 11, "drink_fit": 11}), set(), force=True) is None
    assert plan.drink_draft(s, dict(fort, refuge={"drink": 0, "drink_fit": 0}), set(), force=True) is None
    # R0 without refuge_dry: nothing
    s["ready"]["fail"] = []
    assert plan.drink_draft(s, fort, set(), force=True) is None


# ---------------------------------------------------------------- BUG-419: no wet core by itself
def test_a_wet_core_site_without_the_aqshaft_route_is_not_placed(world, monkeypatch):
    save, box = world
    p, why = plan.wet_core_guard(save, {"stage": 1}, box["snap"])
    assert p is None and "BUG-419" in why and "aqshaft route" in why and "p.aquifer=pass" in why, why
    # no safe column: the reason says so, nothing is placed
    monkeypatch.setattr(plan, "aquifer_route", lambda d: {"ok": False, "why": "no fortcore site with a safe shaft column"})
    p, why = plan.wet_core_guard(save, {"stage": 1}, box["snap"])
    assert p is None and "no aqshaft route exists" in why and "safe shaft column" in why, why


def test_a_dry_world_places_the_core_as_before(world):
    save, box = world
    box["man"] = {"v": 2}                                  # no aquifer level known
    box["snap"] = _snap()
    p, why = plan.wet_core_guard(save, {"stage": 1}, box["snap"])
    assert why == "" and p == {"stage": 1}, (p, why)


def test_follow_refuses_a_wet_starter_core_and_says_why(world, monkeypatch):
    save, box = world
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    sent, failed = [], []
    monkeypatch.setattr(f, "_send", lambda *a, **k: sent.append(a) or "c1")
    monkeypatch.setattr(f, "_fail", lambda what, err, now: failed.append((what, str(err))))
    monkeypatch.setattr(files, "read_snapshot", lambda p: box["snap"])
    job = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
    f.jobs["starter"] = job
    f._place("starter", job, 1000.0)
    assert not sent and failed and failed[0][0] == "fortcore" and "BUG-419" in failed[0][1], (sent, failed)
    assert "starter" not in f.jobs
    # stage 2 (site same) and an aquifer=pass core are not judged by this guard
    job2 = {"snap": "c0", "since": 1000.0, "params": {"stage": 2}, "tpl": "fortcore", "site": "same", "path": "snap/x.json"}
    f.jobs["starter"] = job2
    f._place("starter", job2, 1000.0)
    assert len(sent) == 1
