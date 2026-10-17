"""seal doors that cannot stand, Run 11 (Kilrudrabed site98 y435): the seal piece door 128,121,143 (REFUGE_FAIL `fix`
`128,121,143 floor` beside the door 127,121,143) stayed build_lost although 26 boulders and 171 logs lay in stock;
quickfort on that tile said 'Unsuitable tiles for building: 1' while a `Cw` went in at once. quickfort builds a door only
next to a tile of shape WALL or FORTIFICATION (build.lua is_tile_generic_and_wall_adjacent); another door does not
count. The seal now gives such a tile a constructed wall (`nodoor`), and the as-built simulation knows the rule."""
import json

import pytest

from dfpilot import bp, cmd, files
from dfpilot.bp import defense
from dfpilot.bp.render import cell_rects

from bp_fixtures import tiny

# z0 the walk level, z1 the roof: rows 0-1 lie under the open sky; a door (3,2) in the outer wall, the hall behind it
# (rows 3-4): its tile (3,3) has the door on one side and floor on the other three, like the live 128,121,143.
HALL = [".......",
        ".......",
        "###+###",
        "##...##",
        "##...##",
        "#######"]
ROOF = ["_" * 7] * 2 + ["#" * 7] * 4


def hall(rows=None, tick=100):
    return {**tiny([rows or HALL, ROOF]), "id": f"s{tick}", "tick": tick, "purpose": "sites"}


def save_with(tmp_path, snaps, events):
    d = tmp_path / "save"
    d.mkdir(parents=True, exist_ok=True)
    for s in snaps:
        files.write_json_atomic(d / "snap" / f"{s['id']}.json", s)
    (d / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events), encoding="utf-8")
    return d


def refuge_fail(fix="3,3,0 floor", n=9, tick=300):
    return {"n": n, "tick": tick, "type": "REFUGE_FAIL", "cls": "A", "msg": "alert burrow Kern+ refused",
            "d": {"burrow": "Kern+", "fallback": "Innen+", "why": "open to 1 entrance 3,3,0 floor beside door 3,2,0 "
                  "(62 steps)", "open": [fix], "fix": fix}}


def build_cells(doc):
    return [(k, (x0, y0, z)) for st, k, _, x0, y0, _, _, z in cell_rects(doc) if st["mode"] == "build"]


def test_the_live_door_beside_a_door_becomes_a_wall(tmp_path):
    """The live replay: `seal at=last` takes the REFUGE_FAIL tile 3,3,0 (the door 3,2,0 beside it, floor on its other
    three sides) and gives it a constructed wall, with the reason in its seal:piece line and a seal:note (old code: a
    door, which quickfort refuses: build_lost)."""
    save = save_with(tmp_path, [hall()], [refuge_fail()])
    at, notes = cmd.seal_openings(save, "last")
    assert at == "3,3,0 floor nodoor"
    assert "3,3,0 floor: door unsuitable at 3,3,0 (no wall or fortification beside it on the snapshot): wall " \
           "instead" in notes
    doc = cmd.place(save, "seal", {"at": "last"}, "S1", "c1a147087d")
    assert doc["params"]["at"] == at
    assert build_cells(doc) == [("Cw", (3, 3, 0))]
    assert doc["materials"] == {"wall": 1}
    assert cmd.seal_lines(doc) == ["3,3,0 floor: door unsuitable at 3,3,0 (no wall or fortification beside it): "
                                   "wall instead"]
    assert bp.validate(doc) == []


def test_the_door_rule():
    """door_stands: a natural wall (rough, smooth), a constructed wall, a fortification or a tree trunk orthogonally
    beside the tile holds a door; a door or hatch, floor, open space, ramps, stairs, bridges, other buildings and
    diagonal walls do not; a hidden neighbour or one off the snapshot leaves it open (quickfort decides)."""
    def at(n_char, diag="."):
        g = {(0, -1): n_char, (-1, 0): ".", (1, 0): ".", (0, 1): ".", (1, 1): diag, (-1, -1): diag}
        return lambda x, y, z: g.get((x, y), ".")
    for c in "#SCFT":
        assert defense.door_stands(at(c), (0, 0, 0)) is True, c
    for c in "+._rv<>X=HB^w~":
        assert defense.door_stands(at(c, diag="#"), (0, 0, 0)) is False, c
    assert defense.door_stands(at("?"), (0, 0, 0)) is None
    assert defense.door_stands(at(None), (0, 0, 0)) is None
    assert defense.door_stands(at("?"), (0, 0, 0)) is None
    # a hidden neighbour does not hide a known wall on another side
    assert defense.door_stands(lambda x, y, z: {(0, -1): "?", (1, 0): "#"}.get((x, y), "."), (0, 0, 0)) is True


def test_explicit_pieces_close_and_unknown_tiles(tmp_path):
    """An explicit door gets the wall too (a note says so); close=grate/bars need no wall beside them (quickfort's
    generic rule) and keep their piece; a wall beside the tile, a hidden neighbour or no snapshot keep the door."""
    save = save_with(tmp_path, [hall()], [])
    assert cmd.seal_openings(save, "3,3,0 floor door")[0] == "3,3,0 floor door nodoor"
    assert defense.seal_pieces({"at": "3,3,0 floor door nodoor"})[0]["key"] == "Cw"
    assert cmd.seal_openings(save, "3,3,0 floor", close="grate")[0] == "3,3,0 floor"
    doc = cmd.place(save, "seal", {"at": "3,3,0 floor", "close": "bars"}, "S1", "c2")
    assert build_cells(doc) == [("B", (3, 3, 0))]
    assert cmd.seal_openings(save, "3,3,0 floor wall")[0] == "3,3,0 floor wall"
    assert cmd.seal_openings(save, "2,3,0 floor")[0] == "2,3,0 floor"            # (1,3) is rock: a door stands
    hidden = [r[:2] + "?" + r[3:] if y == 3 else r for y, r in enumerate(HALL)]
    assert cmd.seal_openings(save, "3,3,0 floor", snap=hall(hidden))[0] == "3,3,0 floor"
    bare = save_with(tmp_path / "bare", [], [])
    assert cmd.seal_openings(bare, "3,3,0 floor")[0] == "3,3,0 floor"           # no snapshot: quickfort decides
    # a shrub there: gathered first, then the wall
    doc = bp.emit("seal", {"at": "3,3,0 shrub nodoor"}, {"id": "S1", "anchor": [3, 3, 0], "rot": 0})
    got = [(st["label"], k) for st, k, *_ in cell_rects(doc)]
    assert got == [("seal.clear", "p"), ("seal.plant", "Cw")]


def test_nodoor_round_trip_and_a_neighbour():
    """The token survives parse/format with for=; the piece line names both reasons."""
    at = "3,3,0 floor for=3,2,0:door nodoor"
    (o,) = defense.parse_openings(at)
    assert (o["pos"], o["of"], o["nodoor"]) == ([3, 3, 0], [3, 2, 0], True)
    assert defense.format_openings([o]) == at
    (pc,) = defense.seal_pieces({"at": at})
    assert (pc["key"], pc["piece"]) == ("Cw", "wall")
    assert pc["why"] == ("3,2,0 door: wall at 3,3,0 (the neighbour on the same route: the route passes beside the "
                         "door); door unsuitable at 3,3,0 (no wall or fortification beside it): wall instead")
    assert defense.parse_openings("3,3,0 floor")[0]["nodoor"] is False
    with pytest.raises(ValueError, match="nodoor"):
        defense.parse_openings("3,3,0 floor nodoors")


def test_at_stays_within_the_param_limit(tmp_path):
    """Six openings with for= and nodoor run past bp.emit's 200 characters (bp.place would fail 'expected a string'):
    the rest waits for the next seal with a note."""
    rows = ["." * 40] * 2 + ["#" + ".+" * 19 + "#"] + ["#" + "." * 38 + "#"] * 2 + ["#" * 40]
    snap = {**tiny([rows, ["_" * 40] * 2 + ["#" * 40] * 4]), "id": "w1", "tick": 100, "purpose": "sites"}
    save = save_with(tmp_path, [snap], [])
    want = ";".join(f"{x},3,0 floor for={x},2,0:door" for x in range(2, 14, 2))
    at, notes = cmd.seal_openings(save, want)
    assert len(at) <= defense.AT_MAX and at.count(";") < 5
    assert at.split(";")[0] == "2,3,0 floor for=2,2,0:door nodoor"
    assert any(n.startswith(f"{5 - at.count(';')} more for the next seal") for n in notes), notes
    doc = cmd.place(save, "seal", {"at": want}, "S1", "c3")
    assert {k for k, _ in build_cells(doc)} == {"Cw"}


def test_the_simulation_knows_the_door_rule():
    """bp.as_built (and so validate's build_tile): a door with no wall or fortification beside it that stood before its
    stage is an error; a wall of the same stage does not hold it, one of an earlier project does."""
    snap = hall()
    door = bp.emit("seal", {"at": "3,3,0 floor door"}, {"id": "S1", "anchor": [3, 3, 0], "rot": 0})
    assert build_cells(door) == [("d", (3, 3, 0))]
    err = "build d at 3,3,0: no wall or fortification beside it"
    assert any(e.startswith(err) for e in bp.as_built(door, base=snap).errors)
    same = bp.emit("seal", {"at": "2,3,0 floor wall;3,3,0 floor door"}, {"id": "S1", "anchor": [2, 3, 0], "rot": 0})
    assert any(e.startswith(err) for e in bp.as_built(same, base=snap).errors)
    wall = bp.emit("seal", {"at": "2,3,0 floor wall"}, {"id": "S1", "anchor": [2, 3, 0], "rot": 0})
    assert bp.as_built([wall, door], base=snap).errors == []
    assert bp.as_built(bp.emit("seal", {"at": "2,3,0 floor door"}, {"id": "S1", "anchor": [2, 3, 0], "rot": 0}),
                       base=snap).errors == []
