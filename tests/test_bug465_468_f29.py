"""Round 29 (stone and wood): BUG-465 the embark rank/scan (a failed stone is a hard reject, the nearest hard stone ranks first, the aquifer span is
shown), BUG-468 plan propose (one explore at a time, none through a known heavy aquifer level). The Lua sides are tests/lua/test_embark_bug465.lua,
test_economy_pieces.lua (BUG-466/467), test_care_coffins.lua (BUG-466); the bp side is tests/bp/test_bp_explore.py."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "embark"))
import embark as drv  # noqa: E402

EX = {"tpl": "explore", "site": "S1"}
TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "cistern", "farms", "seal")


# ---------------------------------------------------------------- BUG-465
def _row(w, verdict="reject", score=50, fails=(), warns=(), unknown=(), **kw):
    return {"tag": f"r{w[0]}-{w[1]}", "world": list(w), "emb": [16 * w[0] + 6, 16 * w[1] + 6], "size": [4, 4], "verdict": verdict,
            "score": score, "fails": list(fails), "warns": list(warns), "unknown": list(unknown), "rec": kw.pop("rec", {}), **kw}


def test_bug465_stone_is_not_acceptable_and_has_a_reason():
    assert "stone" not in drv.ACCEPTABLE and "stone" in drv.WAIVABLE and "stone" in drv.HARD_REJECT
    with pytest.raises(ValueError, match=r"cannot accept \['stone'\].*hard stone within reach"):
        drv.make_spec("embark", site=[7, 23], accept=["stone"], reason="deep soil", explore_first="shaft to stone in spring")
    # the unknown depth is waived with a plan, as before
    e = drv.make_spec("embark", site=[7, 23], waive=["stone"], explore_first="shaft to stone in spring")
    assert e["waive"] == ["stone"]
    # a stone fail leaves no compromise (the best compromise names the criteria that can be accepted)
    out = drv.best_compromise([_row((4, 10), fails=["stone"], emb=[70, 166])])
    assert "cannot be accepted" in out


def test_bug465_rank_puts_the_nearest_hard_stone_first():
    some = _row((1, 1), "review", 70, warns=["stone"], reach=3)                       # 3 levels down
    aq = _row((2, 1), "review", 90, warns=["stone", "aquifer"], reach=9, aquifer_span=6)      # a better score, farther stone
    ok_far = _row((3, 1), "ok", 99)                                                   # no stone item at all: nothing to reach
    deep = _row((4, 1), "reject", 40, fails=["stone"], reach=19, aquifer_span=4)
    unk = _row((5, 1), "review", 80, unknown=["stone"])
    order = sorted([deep, unk, aq, ok_far, some], key=drv.rank_key)
    assert [r["world"][0] for r in order] == [3, 1, 2, 5, 4], order                  # ok first, then the nearest stone, unknown, reject
    assert [drv.stone_tier(r) for r in (ok_far, some, unk, deep)] == [0, 1, 2, 3]
    # within one verdict the stone decides before the number of other fails or the score
    a = _row((1, 1), "review", 99, warns=["stone"], reach=9, fails=[])
    b = _row((2, 1), "review", 20, warns=["stone", "trees", "water"], reach=3)
    assert sorted([a, b], key=drv.rank_key)[0] is b
    sw = [dict(r, sweep=True) for r in (deep, some, aq)]
    lines = drv.rank_lines(sw, top=3)
    best = [x for x in lines if x.startswith(("  1.", "  2.", "  3."))]
    assert [x.split()[1] for x in best] == ["1,1", "2,1", "4,1"], lines


def test_bug465_summary_shows_the_aquifer_spread_and_the_span():
    rec = {"aquifer": "light", "soil": "very_deep", "tiles": {"n": 16, "aq_n": {"none": 9, "light": 6, "heavy": 1}}}
    r = _row((21, 7), "reject", 30, fails=["stone"], rec=rec, stone_levels=15, aquifer_span=4, reach=19)
    txt = drv.aquifer_text(r)
    assert "aq tiles: 9 none, 6 light, 1 heavy" in txt, txt
    assert "aq span ~4 levels incl. heavy ones under the light" in txt and "hard stone ~19 levels down" in txt, txt
    lines = drv.summarize({"id": "s", "state": "done", "results": [r]})
    assert any("hard stone ~19 levels down" in x for x in lines), lines
    plain = _row((1, 1), "ok", 90, rec={"aquifer": "none", "tiles": {"n": 16, "aq_n": {"none": 16}}}, reach=1)
    assert drv.aquifer_text(plain) == " hard stone ~1 levels down"


def test_bug465_rules_json_carries_the_span():
    r = json.loads((ROOT / "tools" / "embark" / "rules.json").read_text(encoding="utf-8"))
    assert r["aquifer_span"] == {"light": 4, "varied": 6, "heavy": 8} and r["stone_score_per_level"] == 3
    text = (ROOT / "tools" / "embark" / "checklist.lua").read_text(encoding="utf-8")
    assert "aquifer_span = {light = 4, varied = 6, heavy = 8}" in text


# ---------------------------------------------------------------- BUG-468
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def _noore(state):
    s = copy.deepcopy(state)
    s["stock"].update({"ore": 0, "bars": 8, "metal": "explore"})
    return s


def _phases():
    return json.loads((FIX / "phases.json").read_text("utf-8"))


def _tinfo():
    return {t: {"params": {}, "about": ""} for t in TPLS}


def _site():
    return [{"id": "S1", "anchor": [45, 56, 25], "rot": 1, "score": 900, "why": "rot1, shaft to z19"}], "c1"


def test_bug468_one_explore_at_a_time(save, base, monkeypatch):
    prev, state = base
    s = _noore(dict(state, t=dict(state["t"], y=4, season=0)))
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: _site())
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 9)
    doc = plan.propose(s, _phases(), prev, decisions={}, tinfo=_tinfo())
    assert [(si, b) for si, x in enumerate(doc["seasons"]) for b in x["build"] if b["tpl"] == "explore"] == [(0, EX)]
    assert plan.explore_running(save) == []
    assert plan.fit_explore(save, doc, prev).startswith("explore: depth ")
    # an explore project is under way (bp file, no PROJECT_DONE, no breach): no second one is drafted, the note names it
    files.write_json_atomic(save / "bp" / "y4s0b0.json", {"tpl": "explore", "id": "y4s0b0"})
    assert plan.explore_running(save) == ["y4s0b0"]
    doc = plan.propose(s, _phases(), prev, decisions={}, tinfo=_tinfo())
    line = plan.fit_explore(save, doc, prev)
    assert line == "explore: y4s0b0 under way: no second explore drafted"
    assert not [b for x in doc["seasons"] for b in x["build"] if b["tpl"] == "explore"]
    assert "BUG-468: explore y4s0b0 is under way" in doc["notes"]
    assert schema.validate("plan", doc) == []
    # one that stopped at a breach (heavy aquifer) holds no miner: the next one may be drafted
    monkeypatch.setattr(plan, "_kern_manifest", lambda sd: {"breaches": [{"proj": "y4s0b0", "why": "heavy_aquifer", "tpl": "explore",
                                                                          "pos": [1, 2, 3]}]})
    assert plan.explore_running(save) == []
    doc = plan.propose(s, _phases(), prev, decisions={}, tinfo=_tinfo())
    assert plan.fit_explore(save, doc, prev).startswith("explore: depth ")
    # a finished one (PROJECT_DONE) neither
    monkeypatch.setattr(plan, "_kern_manifest", lambda sd: {})
    monkeypatch.setattr(plan, "done_projects", lambda sd: {"y4s0b0"})
    assert plan.explore_running(save) == []


def test_bug468_the_explore_stops_above_a_known_heavy_level(save, base, monkeypatch):
    prev, state = base
    s = _noore(dict(state, t=dict(state["t"], y=4, season=0)))
    asked = []

    def rank(save_dir, tpl, params=None, snap=None, n=3, manifest=None):
        asked.append(params["depth"])
        if params["depth"] > 2:                       # the heavy level z22 lies within depth 3+ of the anchor z25
            raise cmd.BpError("rank explore: explore: every anchor's shaft of depth 9 reaches an avoided level (z22: avoid, ... a heavy aquifer breach)")
        return _site()
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 9)
    monkeypatch.setattr(plan, "fort_manifest", lambda sd: {"breaches": [{"pos": [9, 9, 22], "proj": "y3s0b0", "tpl": "explore",
                                                                         "why": "heavy_aquifer"}]})
    assert plan.heavy_explore_levels(save) == [22]
    doc = plan.propose(s, _phases(), prev, decisions={}, tinfo=_tinfo())
    line = plan.fit_explore(save, doc, prev)
    assert asked == [12, 9, 6, 4, 2] and "stops above the heavy aquifer z22" in line, (asked, line)
    ex = [b for x in doc["seasons"] for b in x["build"] if b["tpl"] == "explore"]
    assert ex == [{**EX, "p": {"depth": 2}}]
    assert "BUG-468: the explore stops above the known heavy aquifer level(s) z22 (depth 2)" in doc["notes"]
