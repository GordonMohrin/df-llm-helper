"""FR-102 / FR-103 (G15) in `plan propose`: the P7 stages of the large rooms and the deep core are drafted one at a time
(relocate.gate), with readiness kept; the deep site comes from a known dry level (relocate.facts on a save folder);
status/brief carry one `rooms:` line."""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import ev

from dfpilot import bp, files, plan, relocate, schema

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_docs, terrain  # noqa: E402

STATE = {"t": {"y": 5, "season": 0}, "phase": "P7", "ready": {"lvl": 2}, "pop": {"cit": 60}}


def phases():
    return plan.load_phases()


def mine(doc, tpls=relocate.STAGED):
    return [b for se in doc["seasons"] for b in se["build"] if b["tpl"] in tpls]


def st(tpl, k, pid, done=True, p=None, anchor=(60, 60, 25)):
    return {tpl: {k: {"id": pid, "anchor": list(anchor), "rot": 0, "p": {"stage": k, **(p or {})}, "done": done}}}


def test_year1_p7_lists_every_stage_and_validates():
    ph = phases()
    assert ph is not None and schema.validate("phases", ph) == []
    p7 = next(p for p in ph["phases"] if p["id"] == "P7")
    got = {(d["tpl"], d["stage"]) for d in p7["deliver"] if d["k"] == "proj"}
    assert got == {(t, k) for t in relocate.GRAND for k in (1, 2)} | {("deepcore", k) for k in (1, 2, 3)}
    assert p7["approve"] is True                       # a star phase: Gordon's approval (RULES 1.6)
    assert all(not any(d.get("tpl") in relocate.STAGED for d in p["deliver"]) for p in ph["phases"] if p["id"] != "P7")


def test_p7_drafts_the_first_room_stages_not_the_beauty_nor_the_deep_core_without_a_site():
    fort = {"grand": {"st": {}, "deep": {"why": "deepcore: no known dry deep level (... explore first)"}}}
    doc = plan.propose(STATE, phases(), None, decisions={}, fort=fort)
    got = mine(doc)
    assert [(b["tpl"], b["p"]["stage"]) for b in got] == [(t, 1) for t in relocate.GRAND]
    assert got[0]["p"] == {"stage": 1, "size": "large", "n": 20} and got[1]["p"]["size"] == "grand"
    assert all(b["site"] == "S1" for b in got)
    assert "FR-102/103: " in doc["notes"] and "explore first" in doc["notes"]
    assert schema.validate("plan", doc) == []


def test_below_p7_nothing_and_readiness_holds_every_stage():
    doc = plan.propose({**STATE, "phase": "P5"}, phases(), None, decisions={}, fort={"grand": {}})
    assert mine(doc) == []
    doc = plan.propose({**STATE, "ready": {"lvl": 0}}, phases(), None, decisions={}, fort={"grand": {"st": {}}})
    assert mine(doc) == [] and "waits for R1 (R0)" in doc["notes"]
    deep = {"site": "A60_60_25_0", "depth": 11, "why": "rot0, deep level z14 (11 down, known dry)"}
    doc = plan.propose({**STATE, "ready": {"lvl": 1}}, phases(), None, decisions={}, fort={"grand": {"st": {}, "deep": deep}})
    assert [b["tpl"] for b in mine(doc)] == list(relocate.GRAND) and "deepcore st1 waits for R2 (R1)" in doc["notes"]
    doc = plan.propose(STATE, phases(), None, decisions={},
                       fort={"grand": {"st": {}, "deep": deep}, "seals": [{"proj": "s1", "n": 1}]})
    assert mine(doc) == [] and "waits for the open seal" in doc["notes"]
    doc = plan.propose({**STATE, "stock": {"drink_d": 3, "food_d": 90}}, phases(), None, decisions={},
                       fort={"grand": {"st": {}, "deep": deep}})
    assert mine(doc) == [] and "waits: drink 3 d" in doc["notes"]


def test_the_deep_core_goes_to_its_explicit_anchor_with_the_depth():
    deep = {"site": "A60_60_25_0", "depth": 11, "why": "rot0, deep level z14 (11 down, known dry)"}
    stg = {}
    for t in relocate.GRAND:
        stg.update(st(t, 1, f"y4s0b{relocate.GRAND.index(t)}", done=False))
    doc = plan.propose(STATE, phases(), None, decisions={}, fort={"grand": {"st": stg, "deep": deep}})
    assert mine(doc) == [{"tpl": "deepcore", "site": "A60_60_25_0", "p": {"stage": 1, "depth": 11}}]
    assert "deepcore st1 at A60_60_25_0" in doc["notes"] and "suites st2 waits for st1 done" in doc["notes"]


def test_later_stages_wait_for_the_stage_before_and_take_its_params():
    stg = st("suites", 1, "y4s0b0", p={"size": "large", "n": 12, "burrow": "Kern+", "tier": 0})
    stg.update(st("deepcore", 1, "y5s0b0", p={"depth": 11, "beds": 12, "burrow": "Kern+"}))
    fort = {"grand": {"st": stg}}
    got = mine(plan.propose(STATE, phases(), None, decisions={}, fort=fort), ("suites", "deepcore"))
    assert {"tpl": "suites", "site": "same", "p": {"stage": 2, "size": "large", "n": 12, "burrow": "Kern+", "tier": 0}} in got
    assert all(b["tpl"] != "deepcore" for b in got)            # st1 was placed this plan year: st2 next year
    doc = plan.propose({**STATE, "t": {"y": 6, "season": 0}}, phases(), None, decisions={}, fort=fort)
    assert {"tpl": "deepcore", "site": "same", "p": {"stage": 2, "depth": 11, "beds": 12, "burrow": "Kern+"}} in mine(doc)
    stg["deepcore"][1]["done"] = False
    doc = plan.propose({**STATE, "t": {"y": 6, "season": 0}}, phases(), None, decisions={}, fort=fort)
    assert all(b["tpl"] != "deepcore" for b in mine(doc)) and "deepcore st2 waits for st1 done" in doc["notes"]
    # every bp the drafts name is valid for its template
    for b in mine(plan.propose({**STATE, "t": {"y": 6, "season": 0}}, phases(), None, decisions={}, fort={"grand": {
            "st": {**st("deepcore", 1, "y5s0b0", p={"depth": 11, "beds": 12, "burrow": "Kern+"}),
                   **st("grand_temple", 1, "y5s0b1", p={"size": "grand", "burrow": "Kern+", "tier": 0})}}})):
        bp.check_params(b["tpl"], b["p"])


@pytest.fixture(scope="module")
def deep_save(tmp_path_factory):
    """A save folder: the 32-level fortcore world's manifest and sites snapshot, a finished explore shaft (y4s0b0) whose
    tunnels reveal z22, z19, z16 and z14, a deep core not placed yet."""
    sv = tmp_path_factory.mktemp("deep") / "save"
    (sv / "bp").mkdir(parents=True)
    (sv / "snap").mkdir()
    w = bp.as_built(fort_docs(anchor=[50, 20, 30]), base=terrain(z0=1, z1=32, surf=30).snapshot())
    snap, man = w.snapshot(purpose="sites"), w.manifest
    snap["id"] = "s1"
    files.write_json_atomic(sv / "manifest.json", man)
    files.write_json_atomic(sv / "snap" / "s1.json", snap)
    ex = bp.rank(snap, "explore", {"depth": 11}, manifest=man)[0]
    doc = bp.emit("explore", {"depth": 11}, ex)
    doc["id"] = "y4s0b0"
    files.write_json_atomic(sv / "bp" / "y4s0b0.json", doc)
    (sv / "events.jsonl").write_text(json.dumps(ev(1, "PROJECT_DONE", "y4s0b0 (explore) done", {"proj": "y4s0b0",
                                                                                               "tpl": "explore"})) + "\n",
                                     encoding="utf-8")
    return sv, man, ex


def test_facts_find_the_deep_site_on_a_known_dry_level(deep_save):
    sv, man, ex = deep_save
    assert relocate.known_floors([files.read_json(sv / "bp" / "y4s0b0.json")], man) == [14, 16, 19, 22]
    f = relocate.facts(sv, {"phase": "P7"})
    d = f["deep"]
    assert d["z"] == 14 and d["site"].startswith("A") and d["depth"] == d["anchor"][2] - 14, d
    assert "deep" not in relocate.facts(sv, {"phase": "P6"})          # searched only from P7 on
    fort = {"grand": f}
    b = [x for x in mine(plan.propose(STATE, phases(), None, decisions={}, fort=fort)) if x["tpl"] == "deepcore"]
    assert b == [{"tpl": "deepcore", "site": d["site"], "p": {"stage": 1, "depth": d["depth"]}}]
    # the breach of that shaft makes its levels unknown again
    m2 = {**man, "breaches": [{"pos": ex["anchor"], "why": "damp", "proj": "y4s0b0"}]}
    assert relocate.known_floors([files.read_json(sv / "bp" / "y4s0b0.json")], m2) == []


def test_rooms_line(tmp_path):
    sv = tmp_path / "save"
    (sv / "bp").mkdir(parents=True)
    assert relocate.rooms_line(sv) == ""
    site = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}
    for pid, tpl, p in (("y5s0b0", "suites", {"stage": 1}), ("y5s0b1", "deepcore", {"stage": 2, "depth": 8})):
        d = bp.emit(tpl, p, site)
        d["id"] = pid
        files.write_json_atomic(sv / "bp" / f"{pid}.json", d)
    line = relocate.rooms_line(sv, {"proj": [["y5s0b1", "s2.build", 40, ""]]}, done={"y5s0b0"})
    assert line == "rooms: suites large st1 ok, deep core z92 st2/3 40% (next move)"
    assert len(line) < 120
    assert relocate.rooms_line(sv, {"proj": [["y5s0b1", "s2.build", 40, ""]]}) == \
        "rooms: suites large st1, deep core z92 st2/3 40% (next move)"         # status: no event scan


def test_status_and_brief_show_the_rooms_line(tmp_path, monkeypatch):
    from cli_v2_helpers import make_runtime, reset_paths
    from dfpilot import brief
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    sv = make_runtime(tmp_path)
    try:
        assert "rooms:" not in brief.status_text(sv)
        d = bp.emit("grand_dining", {"size": "grand"}, {"id": "S1", "anchor": [70, 70, 100], "rot": 0})
        d["id"] = "y9s0b0"
        files.write_json_atomic(sv / "bp" / "y9s0b0.json", d)
        assert "rooms: grand_dining grand st1" in brief.status_text(sv)
        assert "rooms: grand_dining grand st1 placed" in brief.brief_text(sv)
    finally:
        reset_paths()


def test_the_deep_notes_name_no_banned_term(deep_save):
    """plan check warns on a banned term in the notes (fair play): the deep search's reasons must not carry one."""
    sv, man, _ = deep_save
    from dfpilot.bp import deep
    snap = files.read_json(sv / "snap" / "s1.json")
    whys = [deep.pick(snap, man, [])["why"], deep.pick({**snap, "marks": {"cavern": [[5, 5, 13]]}}, man, [14])["why"]]
    assert all(whys) and not [(w, t) for w in whys for t in plan._banned_terms() if plan._has_term(w, t)]
