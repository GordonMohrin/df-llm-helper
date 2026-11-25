"""Neuausrichtung 10 (wasser), Run 17 i1 Diedplank / i4 Girderroots: no citizen has to leave the fort to drink.
BUG-872: the default `bp sites cistern` ranks the aquifer cistern when every plain site lies on an aquifer level (i1: 'all 79 candidate
  site(s) lie on or right under a known aquifer level' for years, i4 placed water=aquifer at once); a level with a recorded heavy stop
  stays refused as a whole (verifier: untested is not light), open water / magma / a drop within 3 tiles refuses a site.
BUG-873: PROJECT_REQUEST cistern why=inside_water / hospital_water is answered (plan.request_drafts, wake._request_access): the aquifer
  cistern even when a cistern was applied before; a finished one does not answer it, a pending one does, at most WATER_INSIDE_MAX.
The Lua parts are in tests/lua/test_bug871_877_water.lua."""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, plan, wake

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402


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


# ---------------------------------------------------------------- BUG-872: the heavy stop is a place
def test_i1_heavy_levels_stay_refused_as_a_whole(fort):
    snap, man = fort
    z = bp.rank(snap, "cistern", {}, manifest=man)[0]["anchor"][2]
    i1 = {**man, "aquifer_levels": [z - 1], "breaches": [{"pos": [200, 200, z - 1], "why": "heavy_aquifer"}]}
    with pytest.raises(ValueError, match="a level is heavy as a whole"):
        bp.rank(snap, "cistern", {"water": "aquifer"}, manifest=i1)
    ok = {**man, "aquifer_levels": [z - 1], "breaches": [{"pos": [10, 10, z - 2], "why": "heavy_aquifer"}]}
    assert bp.rank(snap, "cistern", {"water": "aquifer"}, manifest=ok)


# ---------------------------------------------------------------- BUG-872: the default call falls back to the aquifer cistern
class _Sites:
    """a sites module whose plain cistern ranking has no site (every one lies on an aquifer level) and whose aquifer ranking has one"""

    @staticmethod
    def rank(snap, tpl, params, manifest=None, n=3, **k):
        if (params or {}).get("water") == "aquifer":
            return [{"id": "S1", "anchor": [1, 2, 3], "rot": 0, "score": 1, "why": "basin on aquifer level z2"}]
        raise ValueError("cistern: all 47 candidate site(s) lie on or right under a known aquifer level (z135-z138); rooms keep one dry level")

    @staticmethod
    def fill_source(s, m):
        return {"ok": True, "far": False, "steps": 3, "at": [1, 2, 3], "why": "x"}

    @staticmethod
    def known_aquifer(s, m):
        return {138}


def _patch(monkeypatch, mod):
    monkeypatch.setattr(cmd, "load_bp", lambda name: mod)
    monkeypatch.setattr(cmd, "fort_manifest", lambda d: {"v": 2})
    monkeypatch.setattr(cmd, "sites_snapshot", lambda d: {"id": "s"})


def test_default_cistern_with_every_site_on_an_aquifer_level_becomes_the_aquifer_cistern(save, monkeypatch):
    _patch(monkeypatch, _Sites)
    assert cmd.cistern_aq_fallback(save, {}, None) == {"water": "aquifer"}
    assert cmd.cistern_aq_fallback(save, {"level": "core"}, None) == {"level": "core", "water": "aquifer"}
    # a pipe or an explicit water is never touched
    assert cmd.cistern_aq_fallback(save, {"path": "1,6;1,9"}, None) is None
    assert cmd.cistern_aq_fallback(save, {"water": "pond"}, None) is None
    # place: the guard hands the aquifer params on and notes it
    p = cmd.cistern_fill_guard(save, {}, {"id": "s"}, "y1s0b0")
    assert p == {"water": "aquifer"} and "BUG-872" in cmd.PLACE_NOTES["y1s0b0"]


def test_default_cistern_with_a_plain_site_stays_plain(save, monkeypatch):
    class Plain(_Sites):
        @staticmethod
        def rank(snap, tpl, params, manifest=None, n=3, **k):
            return [{"id": "S1", "anchor": [1, 2, 3], "rot": 0, "score": 1, "why": "x"}]
    _patch(monkeypatch, Plain)
    assert cmd.cistern_aq_fallback(save, {}, None) is None


def test_no_aquifer_site_either_keeps_the_plain_error(save, monkeypatch):
    class Neither(_Sites):
        @staticmethod
        def rank(snap, tpl, params, manifest=None, n=3, **k):
            raise ValueError("cistern: all 47 candidate site(s) lie on or right under a known aquifer level (z135)")
    _patch(monkeypatch, Neither)
    assert cmd.cistern_aq_fallback(save, {}, None) is None


# ---------------------------------------------------------------- BUG-873: the request is answered
def test_inside_water_request_drafts_the_aquifer_cistern_although_one_was_applied_before():
    fort = {"requests": [{"tpl": "cistern", "why": "inside_water", "at": None, "access": {"why": "no water tile known"}}],
            "hosp": {"aq": True, "fill": {"ok": True, "far": False}}}
    out, why = plan.request_drafts({}, fort, {("cistern", None)}, [], None)
    assert [b["tpl"] for b in out] == ["cistern"] and out[0]["p"] == {"water": "aquifer"}, (out, why)
    assert "water inside the fort" in why
    # no aquifer known: the bucket-fed one when a fill source exists; else nothing
    fort2 = {**fort, "hosp": {"aq": False, "fill": {"ok": True, "far": False}}}
    out2, _ = plan.request_drafts({}, fort2, {("cistern", None)}, [], None)
    assert [b["tpl"] for b in out2] == ["cistern"] and not out2[0].get("p")
    fort3 = {**fort, "hosp": {"aq": False, "fill": {"ok": False}}}
    assert plan.request_drafts({}, fort3, set(), [], None)[0] == []
    # a cistern already drafted is not drafted twice
    assert plan.request_drafts({}, fort, set(), [{"tpl": "cistern", "site": "S1"}], None)[0] == []


def test_hospital_water_and_inside_water_are_cistern_requests():
    assert {"hospital_water", "inside_water", "no_water", "patient_water"} <= set(plan.CISTERN_WHY)


def _follower(save, monkeypatch, aq):
    f = wake.Follower.__new__(wake.Follower)
    f.jobs = {}
    f.dir = save
    sent = []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **k: sent.append((verb, args, what)) or "c1")
    monkeypatch.setattr(f, "_aq_known", lambda: aq)
    return f, sent


def _bp(save, name, params):
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / f"{name}.json").write_text(json.dumps({"tpl": "cistern", "params": params}), "utf-8")


def test_follow_places_the_aquifer_cistern_for_inside_water_even_with_a_tile(save, monkeypatch):
    f, sent = _follower(save, monkeypatch, True)
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1, "at": [101, 95, 143]}, 1000.0)
    j = f.jobs["cistern_water"]
    assert j["params"] == {"water": "aquifer"} and not j.get("access"), j


def test_follow_inside_water_without_an_aquifer_takes_the_piped_route(save, monkeypatch):
    f, sent = _follower(save, monkeypatch, False)
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1, "at": [101, 95, 143]}, 1000.0)
    j = f.jobs["cistern_water"]
    assert j["params"] == {} and j.get("access") is True


def test_follow_a_finished_cistern_does_not_answer_inside_water_but_a_pending_one_does(save, monkeypatch):
    _bp(save, "y1s0b0", {"water": "aquifer"})
    f, sent = _follower(save, monkeypatch, True)
    monkeypatch.setattr("dfpilot.plan.done_projects", lambda d: {"y1s0b0"})
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert "cistern_water" in f.jobs, "old code: any aquifer cistern project, done or not, answered the request for good"
    f2, _ = _follower(save, monkeypatch, True)
    monkeypatch.setattr("dfpilot.plan.done_projects", lambda d: set())
    f2._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert "cistern_water" not in f2.jobs, "a project under way answers it"
    # patient_water keeps the old rule
    f3, _ = _follower(save, monkeypatch, True)
    f3._request_access({"tpl": "cistern", "why": "patient_water", "n": 1}, 1000.0)
    assert "cistern_water" not in f3.jobs


def test_follow_stops_at_water_inside_max(save, monkeypatch):
    for i in range(wake.WATER_INSIDE_MAX):
        _bp(save, f"y1s0b{i}", {"water": "aquifer"})
    f, _ = _follower(save, monkeypatch, True)
    monkeypatch.setattr("dfpilot.plan.done_projects", lambda d: {f"y1s0b{i}" for i in range(wake.WATER_INSIDE_MAX)})
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert "cistern_water" not in f.jobs


# ---------------------------------------------------------------- BUG-873 (verifier): the well parts gate and the stalled project
_SEQ = [0]


def _state(save, stock, tick=200 * 1200):
    from dfpilot import files
    base = json.loads((save / "state.a.json").read_text("utf-8"))
    _SEQ[0] += 10
    st = dict(base, seq=base["seq"] + _SEQ[0], t={**base["t"], "abs": tick}, stock={**(base.get("stock") or {}), **stock})
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


def test_well_parts_why_names_stone_and_mechanisms(save):
    assert plan.well_parts_why(save, {"stock": {"mfree": 3, "rock": 5}})[0] == ""
    why, toks = plan.well_parts_why(save, {"stock": {"mfree": 0, "mroute": "no stone", "rock": 0, "nowood": 1}})
    assert "well parts missing" in why and "free mechanisms 0" in why and "no logs" in why, why
    assert "mechanism" in toks and "wood" in toks
    why2, toks2 = plan.well_parts_why(save, {"stock": {"rhard": 1, "mfree": 2}})
    assert "DF cancels the rock jobs" in why2 and "stone" in toks2


def test_follow_does_not_place_a_cistern_without_well_parts_but_names_it(save, monkeypatch):
    _state(save, {"mfree": 0, "mroute": "no Mechanics", "rock": 0})
    f, sent = _follower(save, monkeypatch, True)
    synth = []
    monkeypatch.setattr(f, "_synth", lambda t, m, now: synth.append((t, m)))
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert "cistern_water" not in f.jobs, "old code placed the cistern, the well then hung at 37 % for years"
    assert synth and "well parts missing" in synth[0][1] and "no Mechanics" in synth[0][1]
    assert [a for v, a, _ in sent if v == "trade.want"] == [{"add": ["mechanism"]}], sent
    assert "well parts missing" in plan.inside_note(save)["parts"]
    synth.clear()                                  # the same cause is not announced twice
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1100.0)
    assert not synth
    from dfpilot import brief                      # the brief shows it
    ctx = brief.Ctx(save)
    assert any("INSIDE WATER BLOCKED" in t for _, t in brief.supply_items(ctx))
    _state(save, {"mfree": 4, "rock": 9})          # parts back: placed
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1200.0)
    assert "cistern_water" in f.jobs and plan.inside_note(save)["parts"] == ""


def test_a_stalled_cistern_project_no_longer_counts_as_pending(save, monkeypatch):
    _bp(save, "y1s0b0", {"water": "aquifer"})
    monkeypatch.setattr("dfpilot.plan.done_projects", lambda d: set())
    _state(save, {"mfree": 4, "rock": 9}, tick=100 * 1200)
    f, _ = _follower(save, monkeypatch, True)
    synth = []
    monkeypatch.setattr(f, "_synth", lambda t, m, now: synth.append((t, m)))
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert "cistern_water" not in f.jobs                       # pending: answers the ask
    _state(save, {"mfree": 4, "rock": 9}, tick=(100 + 91) * 1200)
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 2000.0)
    assert "cistern_water" in f.jobs, "stalled for 90+ game days: the ask places the next one"
    assert any("y1s0b0" in m and "waited 90 game days" in m for _, m in synth), synth
    assert plan.inside_note(save)["stalled"] == ["y1s0b0"]


# ---------------------------------------------------------------- BUG-873 (verifier round 2): every aquifer site refused (i1: heavy z135/136/138)
def _bperr(msg):
    from dfpilot.cmd import BpError
    return BpError(msg)


def _place_follower(save, monkeypatch, results, aq=True):
    """a follower whose bp.place answers `results` in order (an Exception is raised, a str is the command id)"""
    f, sent = _follower(save, monkeypatch, aq)
    calls = []

    def send(verb, args, what, now, **k):
        calls.append((verb, args))
        r = results.pop(0)
        if isinstance(r, Exception):
            raise r
        return r
    monkeypatch.setattr(f, "_send", send)
    monkeypatch.setattr(wake.files, "read_snapshot", lambda p: {"id": "s"})
    monkeypatch.setattr(wake.files, "log_cli", lambda *a, **k: None)
    synth = []
    monkeypatch.setattr(f, "_synth", lambda t, m, now: synth.append((t, m)))
    return f, calls, synth


def test_inside_water_falls_through_to_the_bucket_fed_cistern_when_every_aquifer_site_is_refused(save, monkeypatch):
    _state(save, {"mfree": 4, "rock": 9})
    f, calls, synth = _place_follower(save, monkeypatch, [_bperr("cistern water=aquifer: no site (heavy z135,z136,z138)"), "c9"])
    f.jobs["cistern_water"] = {"snap": "s1", "since": 1000.0, "params": {"water": "aquifer"}, "tpl": "cistern", "site": "S1",
                               "ready": 1000.0, "path": "snap/s1.json", "inside": True, "tries": [{"water": "aquifer"}, {}], "prio": 1}
    f._place("cistern_water", f.jobs["cistern_water"], 1001.0)
    assert [c[1]["p"] for c in calls] == [{"water": "aquifer"}, {}], calls
    assert f.jobs["cistern_water"]["placed"] == "c9" and not synth, "the bucket-fed route placed: nothing to complain about"


def test_every_route_refused_is_said_plainly_once_a_week_and_not_asked_again(save, monkeypatch):
    _state(save, {"mfree": 4, "rock": 9}, tick=200 * 1200)
    f, calls, synth = _place_follower(save, monkeypatch, [_bperr("cistern water=aquifer: no site (heavy z135,z136,z138)"),
                                                          _bperr("cistern: no fill source on the snapshot")])
    f.jobs["cistern_water"] = {"snap": "s1", "since": 1000.0, "params": {"water": "aquifer"}, "tpl": "cistern", "site": "S1",
                               "ready": 1000.0, "path": "snap/s1.json", "inside": True, "tries": [{"water": "aquifer"}, {}], "prio": 1}
    f._place("cistern_water", f.jobs["cistern_water"], 1001.0)
    assert "cistern_water" not in f.jobs
    assert len(synth) == 1 and "no site for a cistern inside the fort" in synth[0][1] and "heavy z135" in synth[0][1]
    assert "container reserve" in synth[0][1] and "trade.want" in synth[0][1]
    ns = plan.inside_note(save)["nosite"]
    assert ns["tick"] == 200 * 1200 and "bucket-fed" in ns["why"]
    from dfpilot import brief
    assert any("NO INSIDE WATER SITE" in t and "heavy z135" in t for _, t in brief.supply_items(brief.Ctx(save)))
    # the kernel asks again every week: held, no snapshot, no placement; the plain cause once per 7 days
    n_sent = len(calls)
    synth.clear()
    snaps = []
    monkeypatch.setattr(f, "_request_place", lambda *a, **k: snaps.append(a) or True)
    for day, say in ((3, 0), (7, 1), (10, 0), (14, 1), (21, 1), (27, 0)):
        _state(save, {"mfree": 4, "rock": 9}, tick=(200 + day) * 1200)
        synth.clear()
        f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 2000.0 + day)
        assert len(synth) == say, (day, synth)
    assert not snaps and len(calls) == n_sent, "no failing request repeated inside 28 days"
    _state(save, {"mfree": 4, "rock": 9}, tick=(200 + 29) * 1200)
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 3000.0)
    assert len(snaps) == 1, "after 28 days it tries again"
    assert plan.inside_note(save)["nosite"]["tick"] == 200 * 1200       # the report of other causes keeps the record


def test_follow_inside_job_carries_the_route_tries(save, monkeypatch):
    f, _ = _follower(save, monkeypatch, True)
    f._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert f.jobs["cistern_water"]["tries"] == [{"water": "aquifer"}, {}] and f.jobs["cistern_water"]["inside"] is True
    f2, _ = _follower(save, monkeypatch, False)
    f2._request_access({"tpl": "cistern", "why": "inside_water", "n": 1}, 1000.0)
    assert f2.jobs["cistern_water"]["tries"][0] == {}, "no aquifer level known: the bucket-fed cistern first"


# ---------------------------------------------------------------- hard rule: exactly 3 tiles
def test_aquifer_site_exactly_three_tiles_from_open_water_is_refused_four_is_not(fort):
    snap, man = fort
    z = bp.rank(snap, "cistern", {}, manifest=man)[0]["anchor"][2]
    from dfpilot.bp import sites
    m = {**man, "aquifer_levels": [z - 1]}
    cands = [{"anchor": [50, 50, z], "box": (50, 50, z, 52, 52, z), "why": "x", "rot": 0}]
    for lz in (z - 1, z):
        three = _with_tile_t(snap, 55, 51, lz, "~")          # box x2 = 52: 55 is exactly 3 tiles off
        with pytest.raises(ValueError, match="within 3 tiles"):
            sites.aquifer_well(cands, three, m)
        three_y = _with_tile_t(snap, 51, 47, lz, "~")        # box y1 = 50: 47 is exactly 3 tiles off
        with pytest.raises(ValueError, match="within 3 tiles"):
            sites.aquifer_well(cands, three_y, m)
        four = _with_tile_t(snap, 56, 51, lz, "~")
        assert sites.aquifer_well(cands, four, m), "4 tiles off: clear"
        assert sites.aquifer_well(cands, _with_tile_t(snap, 51, 46, lz, "~"), m)


def _with_tile_t(snap, x, y, z, ch):
    rows = {k: list(v) for k, v in snap["rows"].items()}
    r = rows[f"z{z}"]
    yy, xx = y - snap["bbox"][1], x - snap["bbox"][0]
    r[yy] = r[yy][:xx] + ch + r[yy][xx + 1:]
    return {**snap, "rows": rows}
