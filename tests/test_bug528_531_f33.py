"""Round 33 (explore). The Lua sides are tests/lua/test_bug529_slot_release.lua (BUG-529) and tests/lua/test_embark_bug531.lua (BUG-531).
BUG-528 (Run 16d i4 Trumpetrealms y375-y400: a soil fort locked out of explore: a cavern breach 78,127,127 and the default 6-tile side
tunnels meeting the core's rooms on every anchor; the message blamed the breach): shorter side tunnels (EXPLORE_ARMS) when the template's arm
has no site, a message that counts what removed the anchors.
BUG-530 (Run 16a-d: the year's plan empty for years because explore / aqshaft found no site): the draft offers rooms, beds, stockpiles,
workshops with a free site instead.
BUG-529 python side: the DECISION project_released has a wake hint and the config limit."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, fairplay, files, plan, wake
from dfpilot.bp import mine, sites


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


# ---------------------------------------------------------------- BUG-528
def _site(anchor=(45, 56, 25)):
    return {"id": "S1", "anchor": list(anchor), "rot": 0, "score": 900, "why": "rot0, shaft"}


def test_bug528_a_shorter_arm_is_ranked_when_the_template_arm_has_no_site(monkeypatch):
    asked = []

    def fake(snap, tpl, params=None, manifest=None, n=3, water=None, near=None, within=None, at=None, free=None):
        asked.append(params["arm"])
        if params["arm"] >= 3:
            raise ValueError(f"explore: no site at depth {params['depth']} arm {params['arm']}")
        return [_site()]
    monkeypatch.setattr(sites, "rank", fake)
    got = sites._rank_arms({}, "explore", {"depth": 8}, {}, 3, None, None, None, None, None)
    assert asked == [6, 4, 3, 2]                                   # the template's arm first, then the longest that fits
    assert got[0]["arm"] == 2 and "side tunnels cut to 2 tiles" in got[0]["why"] and "BUG-528" in got[0]["why"]
    # the template's own arm has a site: untouched, no arm key
    asked.clear()
    monkeypatch.setattr(sites, "rank", lambda *a, **k: (asked.append(a[2]["arm"]), [_site()])[1])
    got = sites._rank_arms({}, "explore", {"depth": 8}, {}, 3, None, None, None, None, None)
    assert asked == [6] and "arm" not in got[0]


def test_bug528_all_arms_empty_raises_the_bare_shafts_reason(monkeypatch):
    def fake(snap, tpl, params=None, manifest=None, *a, **k):
        raise ValueError(f"explore: reason for arm {params['arm']}")
    monkeypatch.setattr(sites, "rank", fake)
    with pytest.raises(ValueError) as e:
        sites._rank_arms({}, "explore", {"depth": 8}, {}, 3, None, None, None, None, None)
    assert "reason for arm 0" in str(e.value) and "arm 6, 4, 3, 2, 1, 0 tried" in str(e.value)
    monkeypatch.setattr(sites, "rank", lambda *a, **k: [])
    assert sites._rank_arms({}, "explore", {}, {}, 3, None, None, None, None, None) == []


def test_bug528_a_given_arm_is_never_changed(monkeypatch):
    called = []
    monkeypatch.setattr(sites, "_rank_arms", lambda *a, **k: called.append(1) or [])
    monkeypatch.setattr(sites, "check_params", lambda tpl, p: (_ for _ in ()).throw(RuntimeError("past the fallback")))
    with pytest.raises(RuntimeError, match="past the fallback"):
        sites.rank({}, "explore", {"arm": 2}, {})                  # p.arm given: no fallback, the ranking goes on with it
    assert called == []
    sites.rank({}, "explore", {}, {})                              # no arm: the fallback wraps the ranking
    assert called == [1]


def test_bug528_the_message_counts_what_removed_the_anchors():
    p = {"depth": 8, "arm": 6}
    # only the old reasons: the old wording stays (callers match it)
    assert sites._explore_none(p, {127}, [], (10, 0, 10, 0, 0)).startswith(
        "explore: every anchor's shaft of depth 8 reaches an avoided level (z127")
    only = sites._explore_none(p, set(), ["cavern 78,127,127 y375s1b0"], (6, 0, 0, 6, 0))
    assert "every anchor lies within 6 tiles of a dig that already stopped (cavern 78,127,127 y375s1b0)" in only
    assert "no safe explore site" in only
    # the Trumpetrealms case: a few anchors near the breach, the rest meet the core's rooms (old text: 'every anchor lies within 6 tiles')
    mixed = sites._explore_none(p, set(), ["cavern 78,127,127 y375s1b0"], (1108 + 680, 0, 0, 40, 1748))
    assert "some anchors lie within 6 tiles" in mixed and "every anchor" not in mixed, mixed
    assert "1748 have a shaft or side tunnels (arm 6) that meet the core's own open rooms" in mixed
    assert "p.arm=0..3" in mixed and "smaller p.depth" in mixed
    # avoided and geometry: the 'avoided level' words stay for fit_explore / depth_hint
    both = sites._explore_none(p, {124, 126, 127}, [], (30, 4, 20, 0, 6))
    assert "avoided level (z124,126,127" in both and "no site at depth 8 arm 6" in both and "[30 anchor tile(s): 4 lie on or under the refuge" in both
    nothing = sites._explore_none(p, set(), [], (0, 0, 0, 0, 0))
    assert "no free rock" in nothing and "[0 anchor tile(s)]" in nothing


def test_bug528_the_site_names_its_arm_and_the_document_takes_it():
    assert cmd.site_params("explore", {"depth": 8}, {"anchor": [1, 2, 3], "arm": 2}) == {"depth": 8, "arm": 2}
    assert cmd.site_params("explore", {"depth": 8, "arm": 5}, {"anchor": [1, 2, 3], "arm": 2}) == {"depth": 8, "arm": 5}
    assert cmd.site_params("explore", {"depth": 8}, {"anchor": [1, 2, 3]}) == {"depth": 8}
    assert cmd.site_params("bedrooms", {"n": 2}, {"anchor": [1, 2, 3], "arm": 2}) == {"n": 2}
    assert mine.PARAMS["explore"]["arm"][0] == 6 and 0 in sites.EXPLORE_ARMS and max(sites.EXPLORE_ARMS) < 6


def test_bug528_fit_explore_writes_the_arm_and_goes_on_past_no_site(save, monkeypatch):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [{"tpl": "explore", "site": "S1"}]}, {"build": []}, {"build": []}, {"build": []}]
    asked = []

    def rank(save_dir, tpl, params=None, snap=None, n=3, manifest=None):
        asked.append((params["depth"], params.get("arm")))
        if params["depth"] > 6:
            raise cmd.BpError("rank explore: explore: no site at depth 12 arm 6; no safe explore site there")
        return [{"id": "S1", "anchor": [78, 121, 136], "rot": 0, "score": 900, "arm": 3, "why": "rot0, shaft to z127"}], "c1"
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 9)
    monkeypatch.setattr(plan, "explore_running", lambda *a, **k: [])
    line = plan.fit_explore(save, doc, prev)
    assert [a[0] for a in asked] == [12, 9, 6], asked                # 'no site' / 'no safe explore site' tries the next depth
    assert line.startswith("explore: depth 6 at [78, 121, 136]")
    ex = [b for se in doc["seasons"] for b in se["build"] if b["tpl"] == "explore"]
    assert ex and ex[0]["p"] == {"depth": 6, "arm": 3}, ex          # the plan places depth 6, arm 3 (an explicit arm is not re-fitted)


# ---------------------------------------------------------------- BUG-530
def test_bug530_an_empty_draft_offers_rooms_beds_and_stockpiles(save, monkeypatch):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    state = files.read_state(save)
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": []} for _ in range(4)]
    doc["notes"] = "draft"
    removed = []

    def fit(save_dir, d, p):                                       # the placement dry run: the dining room finds no site
        for se in d["seasons"]:
            keep = [b for b in se["build"] if b["tpl"] != "dining"]
            removed.extend(b for b in se["build"] if b["tpl"] == "dining")
            se["build"] = keep
        return []
    monkeypatch.setattr(plan, "fit_placeable", fit)
    tpls = ["bedrooms", "stockroom", "dining", "tavern", "workshops"]
    line = plan.offer_growth(save, doc, prev, state, tpls)
    season = state["t"]["season"]
    got = [b for se in doc["seasons"] for b in se["build"]]
    assert [b["tpl"] for b in got] == ["bedrooms", "stockroom"] and got[0]["p"] == {"n": 4}, got   # OFFER_MAX 2
    assert len(doc["seasons"][season]["build"]) == 2
    assert line.startswith("BUG-530: the draft would add nothing") and "beds for growth" in line and "a stockpile room" in line
    assert line in doc["notes"] and removed                         # the dining room was tried and dropped by the placement check
    # a draft with a build is left alone
    again = copy.deepcopy(doc)
    assert plan.offer_growth(save, again, prev, state, tpls) == "" and again["seasons"] == doc["seasons"]


def test_bug530_nothing_finds_a_site_says_so_and_a_rebuilding_fort_offers_nothing(save, monkeypatch):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    state = files.read_state(save)
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": []} for _ in range(4)]
    doc["notes"] = "draft"

    def drop_all(save_dir, d, p):
        for se in d["seasons"]:
            se["build"] = []
        return []
    monkeypatch.setattr(plan, "fit_placeable", drop_all)
    line = plan.offer_growth(save, doc, prev, state, ["bedrooms", "stockroom"])
    assert "finds one either" in line and all(not se["build"] for se in doc["seasons"])
    # the rebuild policy: nothing offered (only seal, tombs, food/drink, beds run)
    monkeypatch.setattr(plan, "rebuild_state", lambda s: {"pop": 3, "lo": 10, "hi": 12})
    doc2 = copy.deepcopy(prev)
    doc2["year"] = prev["year"] + 1
    doc2["seasons"] = [{"build": []} for _ in range(4)]
    assert plan.offer_growth(save, doc2, prev, state, ["bedrooms"]) == "" and all(not se["build"] for se in doc2["seasons"])


# ---------------------------------------------------------------- BUG-529 (python side)
def test_bug529_the_config_limit_and_the_wake_hint():
    assert fairplay.RUNNER_LIM["queue"]["release_days"] == (0, 3000)
    hint = wake.released_hint({"id": "project_released", "proj": "c1a1ada7", "n": 425, "cause": "z124 ring has not moved",
                               "cmds": ["dfllm cmd bp.cancel '{\"proj\":\"c1a1ada7\"}'", "dfllm bp sites aqshaft --fresh"]})
    assert "c1a1ada7" in hint and "425 days" in hint and "bp.cancel" in hint and "bp sites aqshaft --fresh" in hint
    assert wake.URGENT_DECISIONS.isdisjoint({"project_released"})
