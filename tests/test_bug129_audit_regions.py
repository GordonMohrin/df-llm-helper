"""BUG-129 (Run 14, region2-site90): the audit snapshot was refused for ~190 game years ('bbox 190x192x45 = 1641600 tiles
> 400000 ... stretched most by seal c1a14d660b9fb1de01 (+2 more) at z90'). The kernel now exports a big fort as regions
(the fort core plus each project piece as a part, a piece that does not fit dropped and named; tests/lua/
test_bug129_audit_regions.lua). The Python side: SNAPSHOT_READY carries `regions`, `drop`, `dropped`; and the audit stays
as strict as one box over the whole fort would be: a stair or ramp that leads to a tile the export did not read (' ')
above or below it is an attacker source, like a walkable tile beside one on its level (BUG-043)."""
from dfpilot import schema
from dfpilot.bp import topo

W7 = " " * 7


def _snap(z1=None):
    # z1: the core level; z0: not exported except one deep part (a seal far below). The down stair at 3,1,1 leads to
    # z0, which the export did not read; the up stair at 5,1,1 is on the file box's top level (nothing above it in the
    # box: the box face, as before). The pocket at 1,4,1 is a walkable border tile (a source that reaches nothing).
    return {"v": 2, "id": "reg1", "tick": 1, "purpose": "audit", "bbox": [0, 0, 0, 6, 4, 1],
            "parts": [[0, 0, 1, 6, 4, 1], [6, 4, 0, 6, 4, 0]], "margin": [0, 0, 0],
            "rows": {"z0": [W7, W7, W7, W7, "      #"],
                     "z1": z1 or ["#######", "#..>.<#", "#.....#", "#######", "#.#####"]},
            "bridges": {}, "traps": []}


MAN = {"v": 2, "zones": {"Z3": [[1, 2, 1, 5, 2, 1]]}}


def test_a_stair_down_to_unread_tiles_is_a_source():
    assert schema.validate("snapshot", _snap()) == []
    g = topo.Graph(_snap())
    src = topo.sources(g, MAN)
    assert g.idx((3, 1, 1)) in src, "the down stair: below it the export read nothing"
    assert g.idx((5, 1, 1)) not in src, "the box's top face is no source (unchanged)"
    assert g.idx((1, 4, 1)) in src
    res = topo.audit(_snap(), MAN)
    assert res["bypass"] is True and res["ok"] is False
    assert any(f.startswith("bypass:") for f in res["fails"]), res["fails"]


def test_a_ramp_and_open_space_over_unread_tiles_are_sources():
    # a ramp top (v) over z0, and a floor beside open space (_) over z0: a ramp below may climb to either
    g = topo.Graph(_snap(["#######", "#.v...#", "#.....#", "#_.####", "#.#####"]))
    src = topo.sources(g, MAN)
    assert g.idx((2, 1, 1)) in src
    assert g.idx((2, 3, 1)) in src and g.idx((1, 2, 1)) not in src     # 1,2,1 lies in Z3 (the fort's own box)
    assert topo.audit(_snap(["#######", "#.v...#", "#.....#", "#######", "#.#####"]), MAN)["bypass"] is True
    # the fort's own geometry starts no attacker, also over unread tiles (as on its level)
    g = topo.Graph(_snap(["#######", "#.....#", "#..>..#", "#######", "#.#####"]))
    assert g.idx((3, 2, 1)) not in topo.sources(g, MAN)
    assert topo.audit(_snap(["#######", "#.....#", "#..>..#", "#######", "#.#####"]), MAN)["bypass"] is False


def test_snapshot_ready_regions_drop():
    ev = {"n": 3, "tick": 1, "type": "SNAPSHOT_READY", "cls": "C", "msg": "snapshot aud1",
          "d": {"id": "aud1", "path": "snap/aud1.json", "purpose": "audit", "margin": "8,8,1", "regions": 7,
                "drop": 1, "dropped": "seal c1a14d660b9fb1de01"}}
    assert schema.validate("event", ev) == []
    assert schema.validate("event", {**ev, "d": {**ev["d"], "drop": "one"}}) != []
