"""BUG-374 / BUG-375 / BUG-376 (Run 16d Plankscale y374-y380, Run 16b Ostgate):
374 `seal at=last` said 'nothing to close' while status named open ways in (a snapshot older than the entrance check
    said door/wall there; the state counted ways but carried no tile);
375 a sapling way in gets its piece on the sapling (not a neighbour the plant regrows beside);
376 an audit route with no wall tile names what it passes and a placeable fix or the waiver."""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths       # noqa: E402

from dfpilot import bp, brief, cmd, files, plan                               # noqa: E402

# z0 the walk level, z1 the roof: (2,2) a door with open floor beside it, (6,2) a 1-wide opening into the hall
FORT = [".............",
        ".............",
        "##+.##.##.###",
        "##..##.##.###",
        "#...........#",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 5


def snap(tick, rows=None, marks=None):
    return {**tiny([rows or FORT, ROOF], marks), "id": f"s{tick}", "tick": tick, "purpose": "sites"}


def save_with(tmp_path, snaps, ents, utick):
    d = tmp_path / "save"
    d.mkdir(parents=True, exist_ok=True)
    for s in snaps:
        files.write_json_atomic(d / "snap" / f"{s['id']}.json", s)
    e = {"n": 7, "tick": utick, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready",
         "d": {"fails": ["open_perimeter"], "routes": len(ents), "open": len(ents), "ents": ents, "traps": 0}}
    (d / "events.jsonl").write_text(json.dumps(e) + "\n", encoding="utf-8")
    return d


# ---------------------------------------------------------------- BUG-374
def test_a_snapshot_older_than_the_entrance_check_does_not_close_the_way_in(tmp_path):
    """The snapshot (tick 100) shows a door at 2,2,0; the entrance check of tick 5000 names 2,2,0 open (the door was
    destroyed since). Old: 'nothing to close (2,2,0: left out, the snapshot shows a door or hatch there (closed))'."""
    save = save_with(tmp_path, [snap(100)], ["2,2,0 floor"], 5000)
    at, _ = cmd.seal_openings(save, "last")
    assert at.startswith("2,2,0 floor"), at
    # the same snapshot taken within the day before the check is the later evidence as before: the door stands
    save = save_with(tmp_path / "b", [snap(4900)], ["2,2,0 floor"], 5000)
    with pytest.raises(cmd.SealClosed, match="nothing to close"):
        cmd.seal_openings(save, "last")


@pytest.fixture
def rt(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _put_ready(save, **ready):
    st = files.read_state(save)
    st["ready"] = dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 100, "min_traps": 0},
                        "fail": ["open_perimeter"]}, **ready)
    st["seq"] += 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


def test_a_state_that_counts_ways_without_tiles_takes_the_event_list(rt):
    now = files.read_state(rt)["t"]["abs"]
    append_events(rt, [ev(8813, "SIEGE_UNREADY", "u", {"fails": ["open_perimeter"], "ents": ["7,8,140 floor"]},
                          tick=now - 50)])
    _put_ready(rt, open=1)                                                      # counted, no ents
    assert cmd.last_entrances(rt) == ["7,8,140 floor"]                          # old: [] beside 'ways in: 1'


def test_a_counted_way_with_no_tile_anywhere_is_no_nothing_to_close(rt):
    _put_ready(rt, open=3)
    with pytest.raises(cmd.BpError, match="status counts 3 ways in but no tile is on file") as ei:
        cmd.seal_openings(rt, "last")
    assert not isinstance(ei.value, cmd.SealClosed)                             # old: SealClosed, plan apply left it out
    _put_ready(rt, open=0)
    with pytest.raises(cmd.SealClosed, match="the last entrance check names no open way in"):
        cmd.seal_openings(rt, "last")


# ---------------------------------------------------------------- BUG-375
def test_a_sapling_way_in_gets_its_piece_on_the_sapling_with_or_without_a_neighbour(tmp_path):
    save = save_with(tmp_path, [snap(100, marks={"shrub": [], "sapling": [[9, 2, 0]]})], ["9,2,0 sapling"], 200)
    at, notes = cmd.seal_openings(save, "last")
    assert at == "9,2,0 floor" and any("on the sapling itself" in n for n in notes), (at, notes)   # old: 9,3,0 for=9,2,0
    save = save_with(tmp_path / "b", [], ["9,2,0 sapling"], 200)                 # no snapshot at all
    assert cmd.seal_openings(save, "last")[0] == "9,2,0 floor"


# ---------------------------------------------------------------- BUG-376
def _via_world():
    """The edge tile 1,1,0 is a stair up to 1,1,1; the target (Z4) is 2,1,1: no floor tile on the foreign part of the
    route takes a wall (old finding: 'bypass: edge->Z3/Z4 avoids the trap hall (reaches 2,1,1)')."""
    snap_ = tiny([["#####", "#<###", "#####"], ["#####", "#>.##", "#####"]])
    man = {"v": 2, "zones": {"Z2": [[4, 2, 0, 4, 2, 0]], "Z4": [[2, 1, 1, 2, 1, 1]]}, "edge": [[1, 1, 0]]}
    return snap_, man


def test_a_route_without_a_wall_tile_names_what_it_passes():
    snap_, man = _via_world()
    res = bp.audit(snap_, man)
    (f,) = [f for f in res["fails"] if f.startswith("bypass")]
    assert f == "bypass: via stair 1,1,1 -> 2,1,1", f
    assert "wall" not in f                                                      # no seal at=audit wall to ask for


def test_route_advice_is_a_fix_or_the_waiver_never_look_at_it():
    adv = cmd.route_advice("bypass: via door 4,5,6 -> 7,8,9")
    assert 'at="4,5,6 floor wall"' in adv and "WAIVED" in adv
    adv = cmd.route_advice("bypass: via stair 4,5,6 -> 7,8,9")
    assert "no seal piece closes it" in adv and "WAIVED" in adv
    adv = cmd.route_advice("refuge: on the attack path, via bridge 1,2,3")
    assert "bridge 1,2,3" in adv and "WAIVED" in adv
    assert cmd.route_advice("bypass: edge->Z3/Z4 avoids the trap hall (reaches 1,2,3)") == ""


def test_plan_check_and_status_use_the_advice(rt):
    route = "bypass: via stair 4,5,6 -> 7,8,9"
    a = {"routes": [route], "walls": [], "open": [], "pending": {}, "fails": [route]}
    errs, warn = plan.audit_gate({"phase_target": "P3", "seasons": [{"build": []}] * 4, "year": 1}, {"t": {"season": 0}},
                                 {"audit": a}, None)
    assert errs == [] and len(warn) == 1 and "WAIVED" in warn[0] and "look at it" not in warn[0]
