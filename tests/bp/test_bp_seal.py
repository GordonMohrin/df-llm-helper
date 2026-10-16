"""seal (Run 10: SIEGE_UNREADY listed (90,109,125) ramp, (53,126,127) floor, (95,127,123) floor as open ways in): one
piece per opening, a door on a floor, a wall on the ramp top (a ramp cannot carry a door), a hatch on a stair, or
walls/grates/bars; at=last takes the openings of the last entrance check; one log line per piece."""
import json

import pytest

from dfpilot import bp, cmd, files
from dfpilot.bp import defense
from dfpilot.bp.render import World, cell_rects
from dfpilot.bp.topo import Graph

from bp_fixtures import tiny


def pieces(at, close="auto"):
    return [(tuple(p["at"]), p["key"], p["piece"]) for p in defense.seal_pieces({"at": at, "close": close})]


def test_one_piece_per_opening():
    assert pieces("90,109,125 ramp;53,126,127 floor;95,127,123 stair_down") == [
        ((90, 109, 126), "Cw", "wall"), ((53, 126, 127), "d", "door"), ((95, 127, 123), "H", "hatch")]
    assert pieces("53,126,127 floor;90,109,125 ramp", "wall") == [((53, 126, 127), "Cw", "wall"),
                                                                 ((90, 109, 126), "Cw", "wall")]
    assert pieces("53,126,127 floor;90,109,125 ramp", "grate") == [((53, 126, 127), "W", "grate"),
                                                                  ((90, 109, 126), "G", "grate")]
    assert pieces("53,126,127 floor;90,109,125 ramp", "bars") == [((53, 126, 127), "B", "bars"),
                                                                 ((90, 109, 126), "~b", "bars")]
    assert pieces("53,126,127 floor wall;53,126,127 floor") == [((53, 126, 127), "Cw", "wall")]   # once per tile
    with pytest.raises(ValueError, match="cannot carry a door"):
        pieces("90,109,125 ramp door")
    with pytest.raises(ValueError, match="only a hatch"):
        pieces("95,127,123 stair_up wall")
    with pytest.raises(ValueError, match="no piece for this tile kind"):
        pieces("1,2,3 wall")
    with pytest.raises(ValueError, match="name the neighbouring tile"):       # Run 11: the CLI finds the neighbour
        pieces("1,2,3 Door")
    with pytest.raises(ValueError, match="split them"):
        pieces(";".join(f"{x},1,1 floor" for x in range(7)))


@pytest.mark.parametrize("rot", range(4))
def test_pieces_land_on_the_absolute_tiles(rot):
    at = "90,109,125 ramp;53,126,127 floor;95,127,123 stair_down"
    d = bp.emit("seal", {"at": at}, {"id": "S1", "anchor": [90, 109, 125], "rot": rot})
    got = sorted((x0, y0, z, k) for st, k, _, x0, y0, x1, y1, z in cell_rects(d))
    assert got == [(53, 126, 127, "d"), (90, 109, 126, "Cw"), (95, 127, 123, "H")]
    assert d["class"] == "defense" and d["materials"] == {"door": 1, "hatch": 1, "wall": 1}
    assert d["stages"][0]["orders"] == 1 and d["stages"][0]["defense"] == 1


def world():
    """z0: a ramp (3,1) and a floor gap (5,1) in a wall line; z1 above the ramp: its open top beside a ledge."""
    return tiny([["#######", "#..r.##", "##.#..#", "#######"],
                 ["#######", "##.v.##", "#######", "#######"]])


def test_the_ramp_and_the_doorway_close():
    snap = world()
    d = bp.emit("seal", {"at": "3,1,0 ramp;4,2,0 floor"}, {"id": "S1", "anchor": [3, 1, 0], "rot": 0})
    w = bp.as_built(d, base=snap)
    assert w.errors == []
    after = w.snapshot()
    assert after["rows"]["z1"][1][3] == "C" and after["rows"]["z0"][2][4] == "+"
    g0, g1 = Graph(snap), Graph(after)
    reach = lambda g, a, b: bool(g.bfs([g.idx(a)])[0][g.idx(b)])   # noqa: E731
    assert reach(g0, (1, 1, 0), (2, 1, 1)) and not reach(g1, (1, 1, 0), (2, 1, 1))   # the ramp leads up no more
    (site,) = bp.rank(snap, "seal", {"at": "3,1,0 ramp;4,2,0 floor"})
    assert site["anchor"] == [3, 1, 0] and site["rot"] == 0 and "wall at 3,1,1 (the ramp top)" in site["why"]


def test_rank_refuses_closed_hidden_or_wrong_tiles():
    snap = world()
    with pytest.raises(ValueError, match="not the floor"):
        bp.rank(snap, "seal", {"at": "1,0,0 floor"})                # rock: closed already
    with pytest.raises(ValueError, match="not the ramp"):
        bp.rank(snap, "seal", {"at": "4,2,0 ramp"})
    hid = World.from_snapshot(snap)
    hid.set(4, 2, 0, "?")
    with pytest.raises(ValueError, match="not revealed"):
        bp.rank(hid.snapshot(), "seal", {"at": "4,2,0 floor"})
    capped = World.from_snapshot(snap)
    capped.set(3, 1, 1, "#")
    with pytest.raises(ValueError, match="ramp top"):
        bp.rank(capped.snapshot(), "seal", {"at": "3,1,0 ramp"})
    with pytest.raises(ValueError, match="name the openings"):
        bp.rank(snap, "seal", {})


@pytest.fixture
def save(tmp_path):
    d = tmp_path / "save"
    snap = {**world(), "id": "c1", "purpose": "sites"}
    files.write_json_atomic(d / "snap" / "c1.json", snap)
    ev = {"n": 7, "tick": 100, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready",
          "d": {"fails": ["bypass"], "routes": 3, "open": 3, "ents": ["3,1,0 ramp", "4,2,0 floor", "1,0,0 floor"],
                "traps": 0}}
    (d / "events.jsonl").write_text(json.dumps(ev) + "\n", encoding="utf-8")
    return d


def test_at_last_takes_the_last_entrance_check(save):
    at, notes = cmd.seal_openings(save, "last")
    assert at == "3,1,0 ramp;4,2,0 floor" and len(notes) == 1 and "1,0,0: left out" in notes[0]
    at, _ = cmd.seal_openings(save, "4,2,0")                       # the kind comes from the snapshot
    assert at == "4,2,0 floor"
    with pytest.raises(cmd.BpError, match="nothing to close"):
        cmd.seal_openings(save, "1,0,0 floor")


def test_place_and_log_one_line_per_piece(save):
    # another project owns the doorway tile: a seal is never refused for it (it builds on open tiles only)
    cmd.write_bp(save, {"v": 2, "id": "c3", "tpl": "tombs", "site": "S1", "class": "living", "params": {},
                        "anchor": [4, 2, 0], "rot": 0, "stages": [{"label": "dig", "mode": "dig", "orders": 0,
                        "defense": 0, "chunks": [{"pos": [4, 2, 0], "cells": [[0, 0, 0, "d"], [1, 0, 0, "d"]]}]}],
                        "manifest": {"v": 2}, "materials": {}})
    doc = cmd.place(save, "seal", {}, "S1", "c9")
    assert doc["params"]["at"] == "3,1,0 ramp;4,2,0 floor" and doc["anchor"] == [3, 1, 0]
    cid, reply = cmd.send(save, "bp.place", {"tpl": "seal", "site": "S1"}, wait_s=0, cmd_id="c10")
    assert reply is None and (save / "bp" / "c10.json").exists()
    log = (save / "cli.log").read_text(encoding="utf-8").splitlines()
    lines = [ln for ln in log if "\tseal:piece\t" in ln]
    assert len(lines) == 2
    assert lines[0].endswith("3,1,0 ramp: wall at 3,1,1 (the ramp top)") and lines[1].endswith(
        "4,2,0 floor: door at 4,2,0")


def test_bp_sites_resolves_at_last(save):
    sites, snap_id, n = cmd.free_sites(save, "seal", {})
    assert snap_id == "c1" and n == 1 and sites[0]["anchor"] == [3, 1, 0] and "door at 4,2,0" in sites[0]["why"]
