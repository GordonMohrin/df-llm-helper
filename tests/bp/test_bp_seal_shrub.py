"""BUG-041 (Run 11, Kilrudrabed site98, y461 summer d45): the seal c1a149cf2ff540c801 waited 220 days at `seal.clear`
for one piece, 'door 59,62,146'. The tile is a shrub in a shrub field on the citizens' walk group; the seal template put a
gather designation (quickfort #dig p) before the door, and nobody gathered: the plant gathering detail is filled only
below 30 food days (economy's gather task, BUG-038), the fort had 700+. quickfort builds doors and constructions on
SHRUB tiles (internal/quickfort/build.lua is_valid_tile_generic, DFHack 53.16-r2: FLOOR, BOULDER, PEBBLES, TWIG, SAPLING,
SHRUB; is_tile_generic_and_wall_adjacent for doors), so a shrub's piece goes into seal.build at once; only a tree tile
keeps its chop (seal.clear). Each test fails on e8a28a6."""
from dfpilot import bp
from dfpilot.bp import defense
from dfpilot.bp.render import cell_rects


def stages(doc):
    return [(st["label"], k, (x0, y0, z)) for st, k, _, x0, y0, _, _, z in cell_rects(doc)]


def test_the_live_shrub_door_is_built_at_once():
    """59,62,146 shrub (live): one door in seal.build on the shrub tile, no gather stage (old code: seal.clear `p`, then
    seal.plant `d`: the door waited for a plant gatherer)."""
    doc = bp.emit("seal", {"at": "59,62,146 shrub"}, {"id": "S1", "anchor": [59, 62, 146], "rot": 0})
    assert stages(doc) == [("seal.build", "d", (59, 62, 146))]
    assert doc["materials"] == {"door": 1}
    (pc,) = defense.seal_pieces({"at": "59,62,146 shrub"})
    assert (pc["key"], pc["clear"], pc["at"]) == ("d", "", [59, 62, 146])
    assert pc["why"] == "59,62,146 shrub: door at 59,62,146 on the shrub (quickfort builds on shrub tiles; no gather job)"
    assert bp.check_doc({**doc, "id": "c1"}) == []


def test_a_shrub_wall_and_a_tree_on_one_seal():
    """A shrub without a wall beside it gets the constructed wall in seal.build too; a tree tile on the route keeps its
    chop designation (seal.clear `t`, no piece); no seal.plant stage is left."""
    doc = bp.emit("seal", {"at": "3,3,0 shrub nodoor;5,3,0 branch;7,3,0 floor"}, {"id": "S1", "anchor": [3, 3, 0],
                                                                                  "rot": 0})
    assert stages(doc) == [("seal.build", "Cw", (3, 3, 0)), ("seal.build", "d", (7, 3, 0)),
                           ("seal.clear", "t", (5, 3, 0))]
    whys = [pc["why"] for pc in defense.seal_pieces({"at": "3,3,0 shrub nodoor"})]
    assert whys == ["3,3,0 shrub: door unsuitable at 3,3,0 (no wall or fortification beside it): wall instead (on the "
                    "shrub)"]
    assert [pc["clear"] for pc in defense.seal_pieces({"at": "3,3,0 shrub wall;4,3,0 shrub grate"})] == ["", ""]
