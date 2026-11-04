"""BUG-333 (Run 15d Drillchamber y377 spr d4): status '3 ways in without door or bridge: 12,170,146 sapling, 14,170,146
sapling, 11,169,146 sapling'; `bp.place tpl=seal at=last`, also after `bp sites seal --fresh`: 'nothing to close ... its
tile is not on the snapshot' (cli.log 1793287951; 21,85,146 sapling the same at 1793283019). The neighbour search needs
the snapshot, the piece on the sapling (BUG-323) does not: a sapling off the snapshot gets its piece on itself."""
import json

from dfpilot import cmd, files

from bp_fixtures import tiny

FORT = [".............",
        ".............",
        "######.######",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 3


def save_with(tmp_path, ents):
    d = tmp_path / "save"
    s = {**tiny([FORT, ROOF], {"shrub": [], "sapling": []}), "id": "s100", "tick": 100, "purpose": "sites"}
    files.write_json_atomic(d / "snap" / "s100.json", s)
    e = {"n": 7, "tick": 200, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready",
         "d": {"fails": ["open_perimeter"], "routes": len(ents), "open": len(ents), "ents": ents, "traps": 0}}
    (d / "events.jsonl").write_text(json.dumps(e) + "\n", encoding="utf-8")
    return d


def test_saplings_off_the_snapshot_get_their_piece(tmp_path):
    save = save_with(tmp_path, ["40,30,0 sapling", "42,30,0 sapling"])
    at, notes = cmd.seal_openings(save, "last")         # old: BpError 'nothing to close (... not on the snapshot ...)'
    assert at == "40,30,0 floor;42,30,0 floor", (at, notes)
    assert sum("not on the snapshot, the piece goes on the sapling" in n for n in notes) == 2, notes


def test_a_door_route_off_the_snapshot_still_waits_for_it(tmp_path):
    save = save_with(tmp_path, ["40,30,0 door"])
    try:
        cmd.seal_openings(save, "last")
    except cmd.BpError as e:
        assert "its tile is not on the snapshot" in str(e)
    else:
        raise AssertionError("a door's route needs the snapshot's neighbour")
