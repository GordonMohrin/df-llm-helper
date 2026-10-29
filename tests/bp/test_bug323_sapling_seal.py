"""BUG-323 (Run 15c Inkintense y377 sum): `bp.place tpl=seal at=last` noted `79,85,133 sapling: left out, no single
neighbouring tile closes its route on the snapshot`; the way in stayed open, and on the open ground a sapling regrew on
the openings 2-3 times a year (87,100,133 floor -> shrub -> floor, 86,100,133 sapling), so R0 open_perimeter never
cleared. quickfort builds doors and walls on SAPLING tiles (internal/quickfort/build.lua is_valid_tile_generic,
is_valid_tile_has_space, DFHack 53.16): where no neighbour closes the route the piece goes on the sapling itself."""
import json

from dfpilot import bp, cmd, files
from dfpilot.bp import defense
from dfpilot.bp.render import cell_rects

from bp_fixtures import tiny

# z0: rows 0-1 open sky, a 1-wide mouth (6,2) straight into the hall (rows 3-5) under rock: no neighbour of the mouth
# closes it (the hall is wide behind it, the open sky in front of it)
FORT = [".............",
        ".............",
        "######.######",
        "#...........#",
        "#...........#",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 5


def save_with(tmp_path, marks, ents):
    d = tmp_path / "save"
    s = {**tiny([FORT, ROOF], marks), "id": "s100", "tick": 100, "purpose": "sites"}
    files.write_json_atomic(d / "snap" / "s100.json", s)
    e = {"n": 7, "tick": 200, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready",
         "d": {"fails": ["open_perimeter"], "routes": len(ents), "open": len(ents), "ents": ents, "traps": 0}}
    (d / "events.jsonl").write_text(json.dumps(e) + "\n", encoding="utf-8")
    return d


def test_a_sapling_no_neighbour_closes_gets_its_piece_on_itself(tmp_path):
    save = save_with(tmp_path, {"shrub": [], "sapling": [[6, 2, 0]]}, ["6,2,0 sapling"])
    at, notes = cmd.seal_openings(save, "last")          # old: BpError 'nothing to close (... left out ...)'
    assert at == "6,2,0 floor", (at, notes)
    assert any("the piece goes on the sapling" in n for n in notes), notes
    doc = bp.emit("seal", {"at": at}, {"id": "S1", "anchor": [6, 2, 0], "rot": 0})
    got = [(st["label"], k, (x0, y0, z)) for st, k, _, x0, y0, _, _, z in cell_rects(doc)]
    assert got == [("seal.build", "d", (6, 2, 0))]          # a door: the rock beside it holds it
    assert bp.check_doc({**doc, "id": "c1"}) == []


def test_a_shrub_on_the_same_mouth_keeps_its_piece_on_the_shrub(tmp_path):
    save = save_with(tmp_path, {"shrub": [[6, 2, 0]], "sapling": []}, ["6,2,0 shrub"])
    assert cmd.seal_openings(save, "last")[0] == "6,2,0 shrub"
    assert defense.seal_pieces({"at": "6,2,0 shrub"})[0]["at"] == [6, 2, 0]
