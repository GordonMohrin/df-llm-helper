"""WP3 topo audit: movement model on tiny snapshots, worst-case audit of the fortcore, performance."""
import time

import pytest

from df_llm_helper import bp, schema as S
from df_llm_helper.bp.topo import Graph

from df_llm_helper.bp.render import World

from bp_fixtures import L, fort_world, set_tiles, shortcut, tiny


def reach(snap, a, b, **kw):
    g = Graph(snap, **{k: v for k, v in kw.items() if k in ("diag", "closed")})
    seen, _ = g.bfs([g.idx(a)], climb=kw.get("climb", True))
    return bool(seen[g.idx(b)])


def test_stairs_and_ramps():
    assert reach(tiny([["#<#"], ["#>#"]]), (1, 0, 0), (1, 0, 1))
    assert reach(tiny([["#X#"], ["#X#"], ["#>#"]]), (1, 0, 0), (1, 0, 2))
    assert not reach(tiny([["#<#"], ["#.#"]]), (1, 0, 0), (1, 0, 1))            # no down stair above
    assert reach(tiny([["r#"], ["v."]]), (0, 0, 0), (1, 0, 1))                   # ramp up to the ledge
    assert not reach(tiny([["r#"], ["#."]]), (0, 0, 0), (1, 0, 1))               # ramp under rock leads nowhere
    assert reach(tiny([["#X#"], ["#+#"]]), (1, 0, 0), (1, 0, 1))                 # hatch over a stair (worst case)


def test_diagonal_gaps_leak():
    s = tiny([[".#", "#."]])
    assert reach(s, (0, 0, 0), (1, 1, 0)) and not reach(s, (0, 0, 0), (1, 1, 0), diag=False)


def test_hidden_impassable_doors_and_bridges_open():
    assert not reach(tiny([[".?."]]), (0, 0, 0), (2, 0, 0))
    assert reach(tiny([[".+."]]), (0, 0, 0), (2, 0, 0))
    assert not reach(tiny([[".+."]]), (0, 0, 0), (2, 0, 0), closed="+")
    assert reach(tiny([[".H."]]), (0, 0, 0), (2, 0, 0))                          # raised = lowered (worst case)
    assert not reach(tiny([[".~."]]), (0, 0, 0), (2, 0, 0))


def test_top_of_wall_is_walkable():
    assert reach(tiny([["#<#"], ["_>_"], ["___"]]), (1, 0, 0), (0, 0, 1))       # stand on the wall top


@pytest.mark.parametrize("wall,above,ok", [("#", "_", True), ("S", "_", False), ("C", "_", False),
                                           ("F", "_", True), ("#", ".", False)])
def test_climbing(wall, above, ok):
    """Attacker at x0 climbs the wall at x1 onto its top and down the far side; an overhang (floor above the
    climber) or a smoothed/constructed wall stops it."""
    s = tiny([[f".{wall}."], [f"{above}__"], ["___"]])
    assert reach(s, (0, 0, 0), (2, 0, 0)) == ok
    assert not reach(s, (0, 0, 0), (2, 0, 0), climb=False)


@pytest.fixture(scope="module")
def built():
    w, docs = fort_world()
    return w.snapshot(), w.manifest


def test_fortcore_audit_passes(built):
    snap, man = built
    assert S.validate("snapshot", snap) == []
    res = bp.audit(snap, man)
    assert res == {"ok": True, "fails": [], "min_traps": 35, "bypass": False, "refuge_sep": True,
                   "civ_sep": True, "caverns": True}
    assert S.validate_args("audit", {**res, "snap": "c200"}) == []               # = the inbox verb args


def test_raised_bridges_do_not_count(built):
    snap, man = built
    w = World.from_snapshot(snap)
    w.manifest = man
    raised = w.raise_bridges().snapshot()
    assert raised["bridges"] == {"B1": "up", "B2": "up", "O1": "up"}
    assert bp.audit(raised, man) == bp.audit(snap, man)


def test_bypass_and_trap_hall_removal(built):
    snap, man = built
    s2 = set_tiles(snap, shortcut(), ".")
    res = bp.audit(s2, man)
    assert res["bypass"] and not res["ok"] and res["min_traps"] == 0
    hidden = set_tiles(snap, shortcut(), "?")                                     # unknown is not a path
    assert bp.audit(hidden, man)["ok"]


def test_cut_hall_means_no_attack_path(built):
    snap, man = built
    res = bp.audit(set_tiles(snap, [L(3, 18, -2)], "?"), man)    # mid-run (corners are cut diagonally)
    assert not res["bypass"] and res["min_traps"] == 0
    assert any(f.startswith("no attack path") for f in res["fails"])


def test_traps_counted_only_when_armed(built):
    snap, man = built
    assert bp.audit({**snap, "traps": []}, man)["min_traps"] == 0
    unarmed = [t[:5] + [0] for t in snap["traps"]]
    assert bp.audit({**snap, "traps": unarmed}, man)["min_traps"] == 0
    cage = [t[:3] + ["C", 0, 1] for t in snap["traps"]]
    res = bp.audit({**snap, "traps": cage}, man)
    assert res["min_traps"] == 0 and any(f.startswith("cage trap") for f in res["fails"])


def test_caverns(built):
    snap, man = built
    far = [[0, 0, snap["bbox"][2]]]
    assert bp.audit({**snap, "marks": {"cavern": far}}, man)["caverns"]
    tunnel = [L(0, v, -5) for v in (49, 50)]                                     # out of the core hub
    s2 = set_tiles(snap, tunnel, ".")
    res = bp.audit({**s2, "marks": {"cavern": [list(tunnel[-1])]}}, man)
    assert not res["caverns"] and not res["ok"]


def test_refuge_and_civ_separation(built):
    snap, man = built
    bad = {**man, "refuge": {"anchor": list(L(0, 10, -2)), "burrow": "Tiefe+"}}
    res = bp.audit(snap, bad)
    assert not res["refuge_sep"] and not res["ok"]
    in_hall = {**man, "stairs": {"civ": [[*L(2, 18, -2)[:2], 7, 8]], "mil": man["stairs"]["mil"]}}
    assert not bp.audit(snap, in_hall)["civ_sep"]
    nomil = {**man, "stairs": {"civ": man["stairs"]["civ"]}}
    assert not bp.audit(snap, nomil)["civ_sep"]
    assert not bp.audit(snap, {k: v for k, v in man.items() if k != "refuge"})["refuge_sep"]


def test_lever_rules(built):
    snap, man = built
    br = {n: dict(b) for n, b in man["bridges"].items()}
    br["B1"]["levers"] = br["B1"]["levers"][:1]
    br["O1"]["levers"] = [list(L(0, 12, -2)), list(L(1, 12, -2))]            # in the bailey: unreachable in alert
    fails = bp.audit(snap, {**man, "bridges": br})["fails"]
    assert "levers: B1 has 1 lever(s), needs 2" in fails
    assert "levers: a lever of O1 is outside Z3/Z4" in fails


def test_edge_fallback_to_bbox_border(built):
    snap, man = built
    res = bp.audit(snap, {k: v for k, v in man.items() if k != "edge"})
    assert res["ok"]


def test_second_entrance_across_the_river_is_a_bypass():
    """manifest `edge` only covers the entrance side: the far bank of the river must still be a source."""
    w, _ = fort_world(big=True)
    zc, top = L(0, 0, -5)[2], L(0, 0, 0)[2]
    x, y = 90, L(0, 44, 0)[1]                                     # east of the river (x 80-83), core row
    for z in range(zc, top + 1):
        w.set(x, y, z, "<" if z == zc else ">" if z == top else "X")
    for xx in range(L(19, 0, 0)[0] + 1, x):
        w.set(xx, y, zc, ".")                                     # tunnel into the core workshop room
    res = bp.audit(w.snapshot(), w.manifest)
    assert res["bypass"] and not res["ok"]
    assert any(f.startswith("bypass") for f in res["fails"])


def test_tight_bbox_through_the_fort_is_no_false_alarm(built):
    """Border tiles inside the fort's own geometry (here the core level cut by the bbox) are no sources."""
    snap, man = built
    w = World.from_snapshot(snap)
    x1 = L(10, 0, 0)[0]                                           # cut through the core workshops room
    b = snap["bbox"]
    cut = World([b[0], b[1], b[2], x1, b[4], b[5]])
    for z in range(b[2], b[5] + 1):
        for yy in range(b[1], b[4] + 1):
            for xx in range(b[0], x1 + 1):
                cut.set(xx, yy, z, w.get(xx, yy, z))
    cut.traps = [t for t in w.traps if t[0] <= x1]
    res = bp.audit(cut.snapshot(), man)
    assert not res["bypass"], res["fails"]


def test_missing_manifest_fails_closed(built):
    snap, _ = built
    res = bp.audit(snap, {"v": 2})
    assert not res["ok"] and res["bypass"] and not res["refuge_sep"]


def test_audit_speed_100x100x12():
    w, _ = fort_world(big=True)
    snap = w.snapshot()
    assert snap["bbox"] == [0, 0, 1, 99, 99, 12]
    t = time.perf_counter()
    res = bp.audit(snap, w.manifest)
    dt = time.perf_counter() - t
    assert res["ok"], res["fails"]
    assert dt <= 2.0, f"audit took {dt:.2f} s"
