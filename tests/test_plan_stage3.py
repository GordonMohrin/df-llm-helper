"""DECISIONS 1 (2026-10-23): fortcore stage 3 (O1, B2, the refuge) comes before P3. Runs 10, 11 and 13 lost forts between
pop 54 and 60 with an open or missing refuge and gates that were never built (stage 3 was a P5 deliverable). The phase
table (plans/year1.json, DESIGN §5.12), the fortcore docs and the plan order now say P3; stage 4 (the traps) stays P6.
`plan check` refuses phase_target P3+ while O1 or B2 do not stand, unless fortcore stage 3 is under way or the plan builds
it before its other new builds; `plan propose` drafts it first."""
import copy
import json
import re

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import fairplay, files, plan, schema

ROOT = fairplay.REPO
STAGE3 = {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def sealed(state, bridges, ex=1):
    """The fixture state with a refuge (separated, beds enough) and these bridge states."""
    s = copy.deepcopy(state)
    s.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    s["alert"]["ref"] = {"ex": ex, "sep": 1, "beds": 13, "need": 13}
    s["bridges"] = dict(bridges)
    assert schema.validate("state", s) == []
    return s


def lines(doc, state, **kw):
    kw.setdefault("decisions", {})
    kw.setdefault("banned", plan.BANNED)
    errs, warn = plan.check(doc, state, **kw)
    return [e for e in errs if e.startswith("stage 3")], [w for w in warn if w.startswith("stage 3")]


# ---------------------------------------------------------------- the phase table
def test_the_phase_table_says_p3(save):
    doc = json.loads((ROOT / "plans" / "year1.json").read_text("utf-8"))
    by = {p["id"]: p for p in doc["phases"]}
    stages = {pid: [d["stage"] for d in p["deliver"] if d.get("tpl") == "fortcore"] for pid, p in by.items()}
    assert stages["P3"] == [3] and stages["P5"] == [] and stages["P6"] == [4] and stages["P2"] == [2]
    assert by["P3"]["deliver"][0] == {"k": "proj", "tpl": "fortcore", "stage": 3}, "stage 3 first among the P3 builds"
    assert "stage 3" in by["P3"]["title"] and "stage 3" not in by["P5"]["title"]
    fix = json.loads((FIX / "phases.json").read_text("utf-8"))
    assert [d.get("stage") for p in fix["phases"] if p["id"] == "P3" for d in p["deliver"]
            if d.get("tpl") == "fortcore"] == [3]
    design = (ROOT / "docs" / "v2" / "DESIGN.md").read_text("utf-8")
    assert re.search(r"^\| P3 \| stage 3 \(O1, B2, refuge\)", design, re.M), "DESIGN §5.12 table"
    assert "3 (P3, DECISIONS 1" in design and "4 (P6) the 41 traps" in design
    assert re.search(r"^\| P5 \| gallery", design, re.M)
    doctrine = (ROOT / "docs" / "v2" / "DOCTRINE.md").read_text("utf-8")
    assert "stage 3" in doctrine and "P3" in doctrine
    assert plan.O1_PHASE == "P3" and plan.GALLERY_PHASE == "P5"


# ---------------------------------------------------------------- check
def test_check_refuses_p3_without_o1_and_b2(base):
    prev, state = base
    doc = copy.deepcopy(prev)                                             # phase_target P4
    want = ("stage 3: phase_target P4 (P3+) needs O1, B2 and the refuge standing or being built first (fortcore stage "
            "3 builds all three): O1, B2 do not stand; add "
            '{"tpl":"fortcore","site":"same","p":{"stage":3}} as the first build (dfllm plan propose drafts it)')
    no_gates = sealed(state, {"B1": "down"})
    assert lines(doc, no_gates, prev=prev) == ([want], [])                # old code: nothing
    only_b2 = sealed(state, {"B1": "down", "O1": "up"})
    assert lines(doc, only_b2, prev=prev)[0] == [want.replace("O1, B2 do not stand", "B2 does not stand")]
    # standing: up, down, moving, or replaced by a wall + door (BUG-048)
    for st in ("up", "down", "moving", "replaced"):
        assert lines(doc, sealed(state, {"O1": st, "B2": "down"}), prev=prev) == ([], [])
    # below P3 no gate; an older kernel (no alert.ref or no bridges) is not checked
    low = copy.deepcopy(doc)
    low["phase_target"] = "P2"
    assert lines(low, no_gates, prev=prev) == ([], [])
    older = copy.deepcopy(no_gates)
    del older["alert"]["ref"]
    assert lines(doc, older, prev=prev) == ([], [])
    # being built: a project under way (fort.refuge.stage3) ...
    assert lines(doc, no_gates, prev=prev, fort={"refuge": {"stage3": True}}) == ([], [])
    # ... or stage 3 in this plan no later than the first other new build
    fix = copy.deepcopy(doc)
    fix["seasons"][1]["build"].append(STAGE3)
    assert lines(fix, no_gates, prev=prev) == ([], [])
    late = copy.deepcopy(doc)
    late["seasons"][1]["build"].append({"tpl": "tavern", "site": "S1"})
    late["seasons"][3]["build"].append(STAGE3)
    (e,), _ = lines(late, no_gates, prev=prev)
    assert "planned in seasons[3]: move it to seasons[1], before the other new builds" in e
    # the refuge-less fort is the refuge gate's (it asks for stage 3 too): no second error
    none = sealed(state, {"B1": "down"}, ex=0)
    assert lines(doc, none, prev=prev) == ([], [])


def test_lost_gates_after_stage_3_is_the_keepers_job(base):
    """Stage 3 is applied and done, O1 is lost (BUG-048: the keeper rebuilds it in quiet PEACE or replaces it): a warning
    naming the keeper, not a second stage 3."""
    prev, state = base
    s = sealed(state, {"B1": "down", "B2": "down", "O1": "destroyed"})
    errs, warn = lines(copy.deepcopy(prev), s, prev=prev, fort={"o1": True})
    assert errs == []
    assert len(warn) == 1 and "O1 does not stand" in warn[0] and "the kernel rebuilds it" in warn[0], warn


# ---------------------------------------------------------------- propose
TINFO = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
         for t in ("fortcore", "furnaces", "hospital", "tombs", "temple", "seal", "refuge_beds", "stockroom", "dining",
                   "bedrooms", "tavern", "farms", "office", "captives")}


def test_propose_drafts_stage_3_first(base):
    prev, state = base
    phases = json.loads((ROOT / "plans" / "year1.json").read_text("utf-8"))
    fort = {"refuge": {"fortcore": True, "stage3": False, "beds": 0, "seal": False, "ents": 0}}
    s = dict(sealed(state, {"B1": "down"}), phase="P2")
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=TINFO, fort=fort)
    new = [b for se in doc["seasons"] for b in se["build"]]
    mine = [b for b in new if b not in [x for se in prev["seasons"] for x in se["build"]]]
    assert doc["phase_target"] == "P5"
    assert mine[0] == STAGE3, "fortcore stage 3 is the first new build (old code: furnaces, hospital, ... first)"
    assert sum(b == STAGE3 for b in new) == 1
    assert [b["tpl"] for b in mine].index("furnaces") > 0
    errs, _ = plan.check(doc, s, decisions={}, banned=plan.BANNED, prev=prev, fort=fort)
    assert [e for e in errs if e.startswith("stage 3")] == []
    # a fort whose phase list (adopted before) had stage 3 in P5 and is in P4 now, with O1 and B2 missing: drafted first
    s4 = dict(sealed(state, {"B1": "down"}), phase="P4")
    doc = plan.propose(s4, phases, prev, decisions={}, tinfo=TINFO, fort=fort)
    mine = [b for se in doc["seasons"] for b in se["build"] if b not in [x for q in prev["seasons"] for x in q["build"]]]
    assert mine[0] == STAGE3
    # standing gates, stage 3 under way, or no fortcore to anchor on: nothing extra
    for st, ft in ((dict(sealed(state, {"B2": "down", "O1": "up"}), phase="P4"), fort),
                   (s4, {"refuge": dict(fort["refuge"], stage3=True)}),
                   (s4, {"refuge": dict(fort["refuge"], fortcore=False)})):
        doc = plan.propose(st, phases, prev, decisions={}, tinfo=TINFO, fort=ft)
        got = [b for se in doc["seasons"] for b in se["build"]]
        assert STAGE3 not in got, (st.get("bridges"), ft)
    # a plan that adds stage 3 once is not asked to add it again
    applied = {("fortcore", 3)}
    doc = plan.propose(s4, phases, prev, decisions={}, tinfo=TINFO, applied=applied, fort=fort)
    assert STAGE3 not in [b for se in doc["seasons"] for b in se["build"]]
