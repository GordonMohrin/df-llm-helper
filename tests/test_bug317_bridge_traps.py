"""BUG-317 (Run 15 Earthboat y383-385, runs/run-15b-earthboat/FR-BUGS.md 'Runde 3'): a fort whose ways in are its
drawbridges only got `bp sites traps` "no way in left to trap (0 door(s) between the outside and the fort)", `traps 0`
and never a traps draft from `plan propose`: dfpilot/bp/traps.py ways_in counted doors only. Now `traps at=bridges` lays
a stone-fall lane in the attack corridor behind every outer and inner bridge (the Z2 hall behind O1, the killbox K1 in
front of B1), off the bailey (depot, wagons) and the bridge footprints; propose drafts it from P5, check warns.
Fails on 1d17c7e (no at=bridges, no bridge_ways)."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema, traps
from dfpilot.bp import topo
from dfpilot.bp import traps as T

ANCHOR = [60, 60, 20]


def fort_world(rot=0):
    docs = bp.emit_all("fortcore", {}, {"id": "S1", "anchor": ANCHOR if rot else [30, 5, 20], "rot": rot})
    return docs, bp.as_built(docs[:3])                  # stages 1-3: O1, B1, B2 stand, no hall traps yet


def boxes_have(boxes, p):
    return any(b[0] <= p[0] <= b[3] and b[1] <= p[1] <= b[4] and b[2] <= p[2] <= b[5] for b in boxes)


def cheb(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))


@pytest.mark.parametrize("rot", [0, 1])
def test_bridge_only_fort_gets_a_lane_behind_o1_and_in_front_of_b1(rot):
    _, w = fort_world(rot)
    s, m = w.snapshot(sid="s1", purpose="sites"), w.manifest
    assert T.ways_in(s, m, 1) == []                     # the bug: no door, no way in, nothing to trap
    ws = T.bridge_ways(s, m)
    assert [x["bridge"] for x in ws] == ["O1", "B1"]
    z1, z2 = m["zones"]["Z1"], m["zones"]["Z2"]
    k1 = [k["bbox"] for k in m["killboxes"]]
    fps = [b["fp"] for b in m["bridges"].values()]
    for x in ws:
        assert len(x["tiles"]) == T.BRIDGE_LANE and not x["trapped"] and not x["partial"]
        assert x["way"] == T._centre(m["bridges"][x["bridge"]]["fp"])
        for t in x["tiles"]:
            ring = [[t[0] + dx, t[1] + dy, t[2]] for dx, dy in topo.N8] + [t]
            assert not any(boxes_have(z1, q) or boxes_have(fps, q) for q in ring), t   # bailey exit, bridge ring free
            assert cheb(t, x["way"]) <= T.OFF_BRIDGE
    o1, b1 = ws
    assert all(boxes_have(z2, t) for t in o1["tiles"])                  # O1: the hall, past the bailey exit
    assert sum(boxes_have(k1, t) for t in b1["tiles"]) >= T.BRIDGE_LANE - 1   # B1: the killing field in front of it


@pytest.fixture
def fort(tmp_path):
    _, w = fort_world()
    d = tmp_path / "save"
    (d / "snap").mkdir(parents=True)
    (d / "bp").mkdir()
    (d / "manifest.json").write_text(json.dumps(w.manifest), encoding="utf-8")
    (d / "snap" / "s1.json").write_text(json.dumps(w.snapshot(sid="s1", purpose="sites")), encoding="utf-8")
    return d


def test_place_bridges_emits_stone_lanes_with_way_entries_then_nothing_is_left(fort):
    with pytest.raises(cmd.SealClosed, match=r"0 door\(s\).*2 bridge way\(s\) want a lane: traps at=bridges"):
        cmd.place(fort, "traps", {"at": "ways"}, "S1", "c901")
    doc = cmd.place(fort, "traps", {"at": "bridges"}, "S1", "c902")
    assert doc["params"]["kind"] == "stone"
    parts = T.parse_at(doc["params"]["at"])
    assert [p.get("bridge") for p in parts] == [True, True] and sum(len(p["tiles"]) for p in parts) == 16
    cells = [t for st in doc["stages"] for ch in st["chunks"] for *_, t in ch["cells"]]
    assert set(cells) == {"Ts"} and len(cells) == 16 and "cage" not in doc["materials"]
    ents = {e["id"]: e for e in doc["manifest"]["traps"]}
    man = json.loads((fort / "manifest.json").read_text("utf-8"))
    for n in ("O1", "B1"):
        c = T._centre(man["bridges"][n]["fp"])
        assert ents[T.way_id(c)]["way"] == c and ents[T.way_id(c)]["kind"] == "stone"
    assert schema.validate("manifest", doc["manifest"]) == [] and bp.check_doc(doc) == []
    cmd.write_bp(fort, doc)
    with pytest.raises(cmd.SealClosed, match="no bridge way left to trap"):   # the project under way covers both lanes
        cmd.place(fort, "traps", {"at": "bridges"}, "S1", "c903")
    f = traps.facts(fort)
    assert f["doors"] == 0 and f["bridges"] == 2 and f["bopen"] == 0


def test_cage_traps_behind_a_bridge_are_refused():
    with pytest.raises(ValueError, match="no cage traps behind a bridge"):
        T.pieces({"at": "b30,12,18:0,11 1,11", "kind": "cage"})
    assert len(T.pieces({"at": "b30,12,18:0,11 1,11", "kind": "stone"})) == 2
    with pytest.raises(ValueError, match="at most 16 away"):
        T.pieces({"at": "b30,12,18:0,17", "kind": "stone"})
    with pytest.raises(ValueError, match="filled in by dfllm cmd"):
        T.pieces({"at": "bridges", "kind": "stone"})


def test_a_placed_stage4_and_standing_traps_hold_their_slots(fort):
    docs, w = fort_world()
    s = w.snapshot(sid="s1", purpose="sites")
    s4 = {**docs[3], "id": "c800"}
    files.write_json_atomic(fort / "bp" / "c800.json", s4)            # stage 4 placed, not done: it arms the hall itself
    (o1, b1) = traps.bridge_lanes(fort, s)
    hall4 = traps.covered(fort, hall4=True)
    assert hall4 and not any(tuple(t) in hall4 for t in o1["tiles"])
    assert len(o1["tiles"]) < T.BRIDGE_LANE and len(b1["tiles"]) == T.BRIDGE_LANE
    built = bp.as_built(docs).snapshot(sid="s2", purpose="sites")     # stage 4 done: '^' on the hall's trap tiles
    (o1b, _) = T.bridge_ways(built, w.manifest)
    assert len(o1b["tiles"]) < T.BRIDGE_LANE


def test_a_replaced_bridge_gets_no_lane():
    _, w = fort_world()
    s = w.snapshot(sid="s1", purpose="sites")
    s["bridges"]["B1"] = "replaced"
    assert [x["bridge"] for x in T.bridge_ways(s, w.manifest)] == ["O1"]
    assert T.bridge_ways(s, {"v": 2}) == []


def test_the_lanes_keep_the_audit_clean():
    """No cage trap on the main path, and the hall/field traps count on the attack route (R2's min_traps)."""
    docs, w = fort_world()
    s = w.snapshot(sid="s1", purpose="sites")
    ws = T.bridge_ways(s, w.manifest)
    at = T.format_at([{"way": x["way"], "tiles": x["tiles"], "bridge": True} for x in ws])
    d = bp.emit("traps", {"at": at, "kind": "stone"}, {"id": "S1", "anchor": ws[0]["tiles"][0], "rot": 0})
    w2 = bp.as_built([d], base=w)
    res = topo.audit(w2.snapshot(), w2.manifest)
    assert not [f for f in res["fails"] if "cage trap" in f] and res["min_traps"] >= 1


# ---------------------------------------------------------------- plan propose / check
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "traps")
BRIDGED = {"traps": {"doors": 0, "open": 0, "trapped": 0, "partial": 0, "ways": [], "bridges": 2, "bopen": 2,
                     "bways": ["O1", "B1"]}}


def test_propose_drafts_traps_at_bridges_from_p5_once(save):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    s = copy.deepcopy(files.read_state(save))
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s["phase"] = "P5"
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort=BRIDGED)
    builds = [b for se in doc["seasons"] for b in se["build"]]
    assert builds.count(traps.TRAPS_BRIDGES) == 1 and traps.TRAPS_WAYS not in builds
    assert "BUG-317: 2 bridge way(s) without a trap lane (O1, B1)" in doc["notes"]
    assert schema.validate("plan", doc) == []
    again = plan.propose(s, phases, doc, decisions={}, tinfo=tinfo, fort=BRIDGED)
    assert sum(b["tpl"] == "traps" for se in again["seasons"] for b in se["build"]) == 1
    both = {"traps": {**BRIDGED["traps"], "open": 1, "ways": ["4,2,0"]}}
    two = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort=both)
    bs = [b for se in two["seasons"] for b in se["build"]]
    assert bs.count(traps.TRAPS_WAYS) == 1 and bs.count(traps.TRAPS_BRIDGES) == 1


def test_check_warns_without_a_bridge_traps_build_from_p5(save):
    d = copy.deepcopy(json.loads((save / "plan.json").read_text("utf-8")))
    state = files.read_state(save)
    d["phase_target"] = "P5"
    w = [x for x in plan.check(d, state, decisions={}, banned=plan.BANNED, fort=BRIDGED)[1] if x.startswith("traps:")]
    assert len(w) == 1 and '{"tpl":"traps","site":"S1","p":{"at":"bridges"}}' in w[0] and "O1, B1" in w[0]
    d["seasons"][3]["build"].append(copy.deepcopy(traps.TRAPS_WAYS))      # a door build does not cover the bridges
    assert [x for x in plan.check(d, state, decisions={}, banned=plan.BANNED, fort=BRIDGED)[1] if x.startswith("traps:")]
    d["seasons"][3]["build"].append(copy.deepcopy(traps.TRAPS_BRIDGES))
    assert not [x for x in plan.check(d, state, decisions={}, banned=plan.BANNED, fort=BRIDGED)[1]
                if x.startswith("traps:")]
