"""seal at=last|all, Run 11 (Kilrudrabed, y429): `bp.place tpl=seal at=all|last` gave the same door 125,103,144 on every
repetition and never the new leaks (188,103,144 floor; 124,81,138 'open route without a roofed tile'; shrubs and
saplings at 188,88,144 and 177,99,144). The openings now come from SEAL_LEAK, the entrance check and REFUGE_FAIL;
those a seal project builds or built are left out; a shrub carries its piece (BUG-041), a sapling or a door the route passes
beside gets the neighbouring tile that closes the same route, an open route a wall on its first tile that cuts it
from the map edge (with the fort behind it)."""
import json

import pytest

from dfpilot import bp, cmd, files
from dfpilot.bp import defense
from dfpilot.bp.render import cell_rects

from bp_fixtures import tiny

# z0 the walk level, z1 the roof: rows 0-1 lie under the open sky, the fort (rows 2-6) under rock.
# (2,2) a door with an open floor (3,2) beside it, (6,2) and (9,2) 1-wide openings into the hall (rows 4-5).
FORT = [".............",
        ".............",
        "##+.##.##.###",
        "##..##.##.###",
        "#...........#",
        "#...........#",
        "#############"]
ROOF = ["_" * 13] * 2 + ["#" * 13] * 5


def fort(marks=None, tick=100, rows=None):
    s = tiny([rows or FORT, ROOF], marks)
    return {**s, "id": f"s{tick}", "tick": tick, "purpose": "sites"}


def ev(n, typ, d, tick, msg=""):
    cls = "B" if typ in ("SEAL", "PROJECT_DONE") else "A"
    return {"n": n, "tick": tick, "type": typ, "cls": cls, "msg": msg or typ.lower(), "d": d}


def unready(n, ents, tick=200):
    return ev(n, "SIEGE_UNREADY", {"fails": ["bypass"], "routes": len(ents), "open": len(ents), "ents": ents,
                                   "traps": 0}, tick, "siege unready")


def save_with(tmp_path, snaps, events, state=None):
    d = tmp_path / "save"
    for s in snaps:
        files.write_json_atomic(d / "snap" / f"{s['id']}.json", s)
    (d / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events), encoding="utf-8")
    if state is not None:
        files.write_json_atomic(d / "state.json", state)
    return d


def seal_doc(save, bid, at):
    doc = bp.emit("seal", {"at": at}, {"id": "S1", "anchor": defense.seal_anchor({"at": at}), "rot": 0})
    doc["id"] = bid
    cmd.write_bp(save, doc)
    return doc


def test_a_seal_under_way_or_built_is_never_placed_twice(tmp_path):
    """The Run 11 repetition: SIEGE_UNREADY kept naming 125,103,144 while its seal was pending, then while the
    entrance check reused an old answer; every `seal at=last` put a second door there (old code: both openings)."""
    save = save_with(tmp_path, [fort()], [unready(7, ["6,2,0 floor", "9,2,0 floor"])])
    seal_doc(save, "c1", "6,2,0 floor")
    at, notes = cmd.seal_openings(save, "last")
    assert at == "9,2,0 floor" and any("6,2,0: left out, seal project c1 builds its piece" in n for n in notes)
    # done before the snapshot was taken again: the snapshot of tick 100 cannot show the door, the project stands
    with open(save / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(ev(8, "PROJECT_DONE", {"proj": "c1"}, 300)) + "\n")
    at, notes = cmd.seal_openings(save, "last")
    assert at == "9,2,0 floor" and any("sealed by c1 (done" in n for n in notes)
    # a snapshot after it was done shows the doorway bare again (the door is gone): the seal places it again
    files.write_json_atomic(save / "snap" / "s400.json", fort(tick=400))
    assert cmd.seal_openings(save, "last", snap=fort(tick=400))[0] == "6,2,0 floor;9,2,0 floor"
    gone = [r[:6] + "+" + r[7:] if y == 2 else r for y, r in enumerate(FORT)]
    with pytest.raises(cmd.BpError, match="nothing to close"):
        cmd.seal_openings(save, "6,2,0 floor", snap=fort(tick=400, rows=gone))     # the snapshot shows the door


def test_seal_leak_is_a_source_and_gets_a_wall(tmp_path):
    """A SEAL_LEAK (the gates up, a route remains) names an opening the monthly SIEGE_UNREADY does not: it comes first,
    with a wall (walk groups pass doors, RULES §7); a newer sealed SEAL check ends it (old code: never read)."""
    leak = ev(9, "SEAL_LEAK", {"routes": 2, "pos": [9, 2, 0], "bld": "floor", "state": "no door", "why": "lever"}, 300,
              "LEAK at 9,2,0 (floor no door); 2 independent routes")
    save = save_with(tmp_path, [fort()], [unready(7, ["6,2,0 floor"]), leak])
    assert cmd.seal_openings(save, "last")[0] == "9,2,0 floor wall;6,2,0 floor"
    with open(save / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(ev(10, "SEAL", {"routes": 0, "sealed": 1, "why": "lever"}, 400, "seal verified")) + "\n")
    assert cmd.seal_openings(save, "last")[0] == "6,2,0 floor"


def test_shrubs_carry_their_piece_and_saplings_are_closed_beside(tmp_path):
    """188,88,144 shrub / 177,99,144 sapling. BUG-041 (Run 11 y461: a gather designation before the door waited 220
    days for a plant gatherer): the shrub's door goes on the shrub in seal.build (quickfort builds on SHRUB tiles); the
    sapling (no tree yet: neither quickfort's chop nor any player designation takes it) gets a door on the neighbour
    that closes its route (y429 code: doors on both plants, the snapshot's '.' read as floor)."""
    marks = {"shrub": [[6, 2, 0]], "sapling": [[9, 2, 0]]}
    save = save_with(tmp_path, [fort(marks)], [unready(7, ["6,2,0 shrub", "9,2,0 sapling"])])
    at, _ = cmd.seal_openings(save, "last")
    assert at == "6,2,0 shrub;9,3,0 floor for=9,2,0:sapling"
    doc = bp.emit("seal", {"at": at}, {"id": "S1", "anchor": [6, 2, 0], "rot": 0})
    got = [(st["label"], k, (x0, y0, z)) for st, k, _, x0, y0, _, _, z in cell_rects(doc)]
    assert got == [("seal.build", "d", (6, 2, 0)), ("seal.build", "d", (9, 3, 0))]
    assert doc["materials"] == {"door": 2}
    assert [pc["why"] for pc in defense.seal_pieces({"at": at})] == [
        "6,2,0 shrub: door at 6,2,0 on the shrub (quickfort builds on shrub tiles; no gather job)",
        "9,2,0 sapling: door at 9,3,0 (the neighbour on the same route: no piece and no player designation takes a "
        "sapling)"]
    assert bp.check_doc({**doc, "id": "c1"}) == []
    # a snapshot of an older kernel (no plant marks) cannot tell: the entrance check's kinds stand
    assert cmd.seal_openings(save, "last", snap=fort())[0] == at
    # a newer plant-aware snapshot without the marks: both are gone, plain doors
    bare = fort({"shrub": [], "sapling": []}, tick=300)
    assert cmd.seal_openings(save, "last", snap=bare)[0] == "6,2,0 floor;9,2,0 floor"
    # a seal under way builds a door behind the sapling already: its route is covered, the shrub alone is left
    seal_doc(save, "c5", "9,3,0 floor")
    at, notes = cmd.seal_openings(save, "last")
    assert at == "6,2,0 shrub" and "9,2,0 sapling: left out, a seal under way closes its route" in notes
    # a tree tile on the route: the chop designation, no piece (the felled tree takes its branches along)
    pcs = defense.seal_pieces({"at": "4,1,0 branch"})
    assert [(pc["key"], pc["clear"]) for pc in pcs] == [("", "t")] and "chop the tree" in pcs[0]["why"]


def test_a_door_the_route_passes_beside_gets_its_neighbour(tmp_path):
    """REFUGE_FAIL `Kern+: open to 1 entrance 127,121,143 Door`: the route runs beside the door; the piece goes on the
    neighbour that closes it. A door that closes its doorway on the snapshot is left out with a note."""
    rf = ev(9, "REFUGE_FAIL", {"burrow": "Kern+", "fallback": "Innen+", "why": "open to 1 entrance 2,2,0 Door (4 steps)",
                               "open": ["2,2,0 Door"]}, 300, "alert burrow Kern+ refused")
    save = save_with(tmp_path, [fort()], [rf])
    at, _ = cmd.seal_openings(save, "last")
    assert at == "3,2,0 floor for=2,2,0:door"
    assert defense.seal_pieces({"at": at})[0]["why"] == (
        "2,2,0 door: door at 3,2,0 (the neighbour on the same route: the route passes beside the door)")
    # the state says the alert's burrow passes now and the refuge is separated: the REFUGE_FAIL is history
    state = {"alert": {"want": "Kern+", "burrow": "Kern+", "tiles": 90, "inside": 4, "ok": 1,
                       "ref": {"ex": 1, "sep": 1, "beds": 4, "need": 4}}}
    assert cmd.current_openings(save, state) == []
    # a door in a 1-wide doorway closes it on the snapshot: nothing a neighbour could add
    walled = [r[:3] + "#" + r[4:] if y in (2, 3) else r for y, r in enumerate(FORT)]
    with pytest.raises(cmd.BpError, match="the door closes the doorway on the snapshot"):
        cmd.seal_openings(save, "last", snap=fort(rows=walled))


# a sky courtyard (rows 2-4) inside a wall ring, its 1-wide gap (7,1) to the field and the map edge (row 0), and a
# corridor (4,5) down into the roofed fort (rows 6-7)
YARD = ["...............",
        "#######.#######",
        "#.............#",
        "#.............#",
        "#.............#",
        "####.##########",
        "#.............#",
        "#.............#",
        "###############"]
YROOF = ["_" * 15] * 5 + ["#" * 15] * 4


def test_an_open_route_gets_a_wall_where_it_leaves_the_fort(tmp_path):
    """SEAL_LEAK 'open route from 124,81,138 to the map edge without a roofed tile': the citizen stands in an open-sky
    part of the fort; the wall goes on the route's first tile that cuts his side (with the fort behind it) from the
    map edge (old code: never read, and no tile to put a piece on)."""
    from dfpilot.bp.topo import SealGeo
    snap = {**tiny([YARD, YROOF]), "id": "y1", "tick": 100, "purpose": "sites"}
    leak = ev(9, "SEAL_LEAK", {"routes": 1, "pos": [7, 4, 0], "why": "lever"}, 300,
              "LEAK: open route from 7,4,0 to the map edge without a roofed tile; 1 independent route")
    save = save_with(tmp_path, [snap], [leak])
    at, _ = cmd.seal_openings(save, "last")
    assert at == "7,1,0 floor wall for=7,4,0:open"
    assert defense.seal_pieces({"at": at})[0]["why"] == (
        "7,4,0 open route: wall at 7,1,0 (the first tile that cuts the route from the map edge)")
    geo = SealGeo(snap)
    assert geo.route((7, 0, 0)) is None                                   # a citizen in the open field: no wall
    cut = [r.replace("####.####", "#########") if y == 5 else r for y, r in enumerate(YARD)]
    assert SealGeo({**snap, "rows": {"z0": cut, "z1": YROOF}}).route((7, 4, 0)) is None   # no fort behind it


def test_at_last_takes_six_and_leaves_the_rest_for_the_next_seal(tmp_path):
    rows = [".........................", ".........................", "#.#.#.#.#.#.#.#.#.#.#.#.#",
            "#.......................#", "#########################"]
    snap = {**tiny([rows, ["_" * 25] * 2 + ["#" * 25] * 3]), "id": "w1", "tick": 100, "purpose": "sites"}
    ents = [f"{x},2,0 floor" for x in range(1, 25, 2)][:8]
    save = save_with(tmp_path, [snap], [unready(7, ents[:6]), ev(8, "REFUGE_FAIL", {
        "burrow": "Kern+", "open": ents[6:]}, 300)])
    at, notes = cmd.seal_openings(save, "last")
    assert at == ";".join(ents[:6]) and notes[-1].startswith("2 more for the next seal")
    doc = cmd.place(save, "seal", {}, "S1", "c20")
    cmd.write_bp(save, doc)
    assert cmd.seal_openings(save, "last")[0] == ";".join(ents[6:])        # the next one takes the rest


def test_notes_reach_cli_log_and_stdout(tmp_path, capsys):
    import argparse
    save = save_with(tmp_path, [fort()], [unready(7, ["6,2,0 floor", "9,2,0 floor"])])
    seal_doc(save, "c1", "6,2,0 floor")
    rc = cmd.run(argparse.Namespace(verb="bp.place", args=['{"tpl":"seal","site":"S1"}'], by="cli", wait=0,
                                    id="c30"), save)
    out = capsys.readouterr().out
    assert rc == cmd.EXIT_OK and "  seal 9,2,0 floor: door at 9,2,0" in out
    assert "  seal note: 6,2,0: left out, seal project c1 builds its piece" in out
    log = (save / "cli.log").read_text(encoding="utf-8").splitlines()
    assert any("\tseal:note\t" in ln and "seal project c1 builds its piece" in ln for ln in log)
    assert any("\tseal:piece\t" in ln and ln.endswith("9,2,0 floor: door at 9,2,0") for ln in log)


def fortcore_save(tmp_path, events=()):
    """Fortcore stages 1-3 as built (bp_fixtures): Tiefe+ on z2 below the core, the civilians' stair 50,65,2..8."""
    from bp_fixtures import fort_world
    w, docs = fort_world(0, stages=3, big=True)
    snap = {**w.snapshot(), "id": "f1", "tick": 100, "purpose": "sites"}
    save = save_with(tmp_path, [snap], list(events))
    for i, d in enumerate(docs):
        cmd.write_bp(save, {**d, "id": f"fc{i + 1}"})
    return save, snap


def test_at_refuge_puts_a_hatch_on_the_refuge_stair_head(tmp_path):
    """BUG-031: fortcore's Tiefe+ hangs below Kern+ on the civilians' stair without a door or hatch, so whatever
    reaches Kern+ reaches it. `seal at=refuge` puts a hatch on the stair tile above the refuge level; with it (doors
    and hatches closed, as seal's refuge flood counts them) the core no longer reaches the refuge."""
    from dfpilot.bp.topo import Graph
    save, snap = fortcore_save(tmp_path)
    assert cmd.refuge_head(save) == "50,65,5 stair_updown"   # BUG-313: z3/z4 walled in
    at, _ = cmd.seal_openings(save, "refuge")
    assert at == "50,65,5 stair_updown"
    (pc,) = defense.seal_pieces({"at": at})
    assert (pc["key"], pc["at"], pc["why"]) == ("H", [50, 65, 5], "50,65,5 stair_updown: hatch at 50,65,5")
    doc = bp.emit("seal", {"at": at}, {"id": "S1", "anchor": [50, 65, 5], "rot": 0})
    core, refuge = (51, 65, 8), (52, 65, 2)                        # the core landing at ze, the refuge anchor
    g0 = Graph(snap, closed="+")
    assert g0.bfs([g0.idx(core)], climb=False)[0][g0.idx(refuge)]
    g1 = Graph(bp.as_built(doc, base=snap).snapshot(), closed="+")
    assert not g1.bfs([g1.idx(core)], climb=False)[0][g1.idx(refuge)]
    # under way, or built (the snapshot shows the hatch): nothing left for at=refuge
    seal_doc(save, "c7", at)
    with pytest.raises(cmd.BpError, match="seal project c7 builds its piece"):
        cmd.seal_openings(save, "refuge")
    hatched = bp.as_built(doc, base=snap).snapshot()
    (save / "bp" / "c7.json").unlink()
    with pytest.raises(cmd.BpError, match="shows a door or hatch there"):
        cmd.seal_openings(save, "refuge", snap={**hatched, "id": "f2", "tick": 200})


def test_refuge_fail_fix_is_used_as_given(tmp_path):
    """BUG-031's REFUGE_FAIL carries `fix` (the seal template's `at` for the tiles the flood entered by, beside the
    door it names): at=last and at=refuge take those tiles, not the door."""
    rf = ev(9, "REFUGE_FAIL", {"burrow": "Kern+", "fallback": "Tiefe+", "why": "open to 1 entrance 3,2,0 floor beside "
                               "door 2,2,0 (4 steps)", "open": ["3,2,0 floor"], "fix": "3,2,0 floor"}, 300)
    save = save_with(tmp_path, [fort()], [rf])
    assert cmd.seal_openings(save, "last")[0] == "3,2,0 floor"
    assert cmd.seal_openings(save, "refuge")[0] == "3,2,0 floor"           # no manifest refuge: no stair head
    assert cmd.refuge_open(save, {})[3] == ["3,2,0 floor"]


def test_plan_facts_see_the_open_stair_head(tmp_path):
    from dfpilot import plan
    save, _ = fortcore_save(tmp_path)
    f = plan.refuge_projects(save, {})
    assert (f["head"], f["head_open"], f["refuge_n"]) == ("50,65,5 stair_updown", True, 1)   # BUG-313
    seal_doc(save, "c8", "50,65,5 stair_updown")
    f = plan.refuge_projects(save, {})
    assert (f["head_open"], f["refuge_n"], f["seal"]) == (False, 0, True)   # the hatch is under way
