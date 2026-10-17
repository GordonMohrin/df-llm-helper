"""BUG-041 (Run 11, Kilrudrabed site98, y461): `dfllm plan check` warned 'seal c1a149cf2ff540c801 (1 piece open) is stuck
for 220 d (SEAL_STUCK): fix it first ...' at every plan check for years (the seal waited for a gather nobody did; the
earlier ramp head 79,116,146 in c1a147c261 stood 196 days the same way until the game session cancelled it). The
warning now names why (the newest SEAL_STUCK event's `wait`, else its pieces), is shown in full while the stuck episode
is young (< 28 days) and then as one short line; a parked seal (BUG-037, it pauses nothing) is no open seal at all.
Each test fails on e8a28a6."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, plan, schema

SEAL = "c1a149cf2ff540c801"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def stuck_event(n, wait=None, pieces=("door 59,62,146",), proj=SEAL):
    d = {"proj": proj, "tpl": "seal", "stage": "seal.clear", "days": 5, "n": len(pieces), "pieces": list(pieces)}
    if wait:
        d["wait"] = wait
    e = {"n": n, "tick": 1000 + n, "type": "SEAL_STUCK", "cls": "A",
         "msg": f"{proj} (seal) built nothing for 5 days at seal.clear: 1 piece open ({pieces[0]}); the other projects "
                "run again", "d": d}
    assert schema.validate("event", e) == [], schema.validate("event", e)
    return e


def add_events(save, *evs):
    with open(save / "events.jsonl", "a", encoding="utf-8") as f:
        for e in evs:
            f.write(json.dumps(e) + "\n")


def check(doc, state, **kw):
    return plan.check(doc, state, decisions={}, banned=plan.BANNED, **kw)


def with_temple(doc):
    d = copy.deepcopy(doc)
    d["seasons"][1]["build"] += [{"tpl": "temple", "site": "S1"}]
    return d


def test_a_parked_seal_is_no_open_seal(save):
    """BUG-037 parks a seal blocked for good (it pauses nothing); plan check still said 'is open: the runner pauses
    temple in PEACE until it is done' for its bp file (old code: every listed seal file without PROJECT_DONE)."""
    s = files.read_state(save)
    (save / "bp" / f"{SEAL}.json").write_text(json.dumps({"v": 2, "id": SEAL, "tpl": "seal"}), encoding="utf-8")
    s["proj"] = [[SEAL, "seal.plant", 50, "parked: build_lost"]] + s["proj"]
    assert plan.open_seals(save, s) == [], "old code: the parked seal listed as open"
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    _, warn = check(with_temple(prev), s, prev=prev, fort=plan.fort_facts(save, s))
    assert not [w for w in warn if SEAL in w], warn
    s["proj"][0][3] = ""
    assert [x["proj"] for x in plan.open_seals(save, s)] == [SEAL], "a live seal file still counts"


def test_a_stuck_seal_names_why_in_full_while_young_then_in_one_short_line(save):
    """Stuck 4 d: the full warning with the reason; stuck 220 d (y461): one short line, no 'fix it first' any more."""
    s = files.read_state(save)
    add_events(save, stuck_event(9001, pieces=("door 59,62,146",)),
               stuck_event(9002, wait="FellTree at 57,62,146: Wood cutting enabled for 0 of 26 citizens: nobody takes "
                                      "it"))
    s["sched"] = {"seal": {"proj": SEAL, "n": 1, "paused": 0, "more": 0, "stuck": 1, "days": 4}}
    seals = plan.open_seals(save, s)
    assert seals == [{"proj": SEAL, "n": 1, "stuck": True, "days": 4,
                      "why": "FellTree at 57,62,146: Wood cutting enabled for 0 of 26 citizens: nobody takes it"}]
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    d = with_temple(prev)
    _, warn = check(d, s, prev=prev, fort={"seals": seals})
    assert (f"seal {SEAL} (1 piece open) is stuck for 4 d (SEAL_STUCK: FellTree at 57,62,146: Wood cutting enabled "
            "for 0 of 26 citizens: nobody takes it): fix it first (material, a refused tile; dfllm cmd inspect "
            "what=workload); until then temple run beside it") in warn, warn
    old = [dict(seals[0], days=220)]
    _, warn = check(d, s, prev=prev, fort={"seals": old})
    mine = [w for w in warn if SEAL in w]
    assert mine == [f"seal {SEAL} (1 piece open) stuck 220 d (SEAL_STUCK, announced: FellTree at 57,62,146: Wood "
                    "cutting enabled for 0 of 26 citizens: nobody takes it): temple run beside it"], mine
    # an event without wait: its pieces are the reason; none at all: the old text
    s2 = copy.deepcopy(s)
    s2["sched"]["seal"]["proj"] = "c1a147c261"
    add_events(save, stuck_event(9003, pieces=("wall 79,116,146",), proj="c1a147c261"))
    assert plan.open_seals(save, s2)[0]["why"] == "wall 79,116,146"
    s2["sched"]["seal"]["proj"] = "c9"
    assert "why" not in plan.open_seals(save, s2)[0]
