"""WP3 validators: every template passes; single stair, shortcut bridge, refuge on the attack path, doors as
barriers, diagonal leaks, unclosed rooms and the trap-hall rules are rejected."""
import copy

import pytest

from df_llm_helper import bp
from df_llm_helper.bp.render import cell_rects
from df_llm_helper.bp.validate import check_world

from bp_fixtures import FORT, SITE, L, dig, fort_docs, mutation, shortcut

TPLS = sorted(bp.TEMPLATES)


def codes(findings):
    return sorted({f.code for f in findings})


@pytest.mark.parametrize("rot", range(4))
@pytest.mark.parametrize("tpl", TPLS)
def test_templates_validate_clean(tpl, rot):
    docs = bp.emit_all(tpl, {}, {**SITE, "rot": rot})
    found = bp.validate(docs)
    assert [str(f) for f in bp.errors(found)] == []
    # farm plots on tiles not known as soil only warn: quickfort skips them (build.lua:102-104)
    assert {f.code for f in found if f.level != "error"} == ({"farm_soil"} if tpl == "farms" else set())


def test_farm_plots_on_marked_soil_do_not_warn():
    d = bp.emit("farms", {"plots": 1}, SITE)
    w = bp.as_built(d)
    soil = {**w.snapshot(), "marks": {"soil": [[x, y, b[5]] for b in [d["manifest"]["rooms"][0]["bbox"]]
                                               for x in range(b[0], b[3] + 1) for y in range(b[1], b[4] + 1)]}}
    assert bp.as_built(d, base=soil).warnings == []
    assert len(bp.as_built(d).warnings) == 1


@pytest.mark.parametrize("rot", range(4))
def test_fortcore_every_stage_is_clean(rot):
    docs = fort_docs(rot)
    for k in (1, 2, 3):
        assert [str(f) for f in bp.validate(docs[:k])] == []


def test_partial_fortcore_is_not_final():
    docs = fort_docs()
    got = codes(check_world(docs[:2], final=True))
    assert {"bridges", "burrows", "refuge"} <= set(got)


def with_extra(extra, final=True):
    return codes(check_world(fort_docs() + [extra], final=final))


def test_plain_bypass():
    assert with_extra(mutation([dig(shortcut())])) == ["bypass"]


def test_door_is_never_a_barrier():
    door = L(-6, 38, -2)
    assert with_extra(mutation([dig(shortcut()), ("m.b", "build", [(*door, "d")])])) == ["door_barrier"]


def test_shortcut_bridge():
    br = L(-8, 30, -2)
    lev = [list(L(-4, 41, -2)), list(L(-3, 40, -2))]
    m = {"v": 2, "bridges": {"B9": {"role": "inner", "fp": [*br, *br], "levers": lev}}}
    assert with_extra(mutation([dig(shortcut()), ("m.b", "build", [(*br, "gw")])], m)) == ["shortcut_bridge"]
    # an unlisted bridge on the shortcut is a shortcut bridge too
    assert with_extra(mutation([dig(shortcut()), ("m.b", "build", [(*br, "gw")])])) == ["shortcut_bridge"]


def test_diagonal_leak_on_the_attack_path():
    tun = [L(u, 12, -2) for u in range(-8, -4)] + [L(-8, v, -2) for v in range(13, 35)] + \
        [L(u, 34, -2) for u in range(-7, -4)]               # ends at (-5,34): only diagonal to the gatehouse
    assert with_extra(mutation([dig(tun)])) == ["diagonal_leak"]


def test_single_stair():
    civ = fort_docs()[2]["manifest"]["stairs"]["civ"][0]
    m = {"v": 2, "stairs": {"mil": [[civ[0] + 1, civ[1], FORT[2] - 2, FORT[2] - 1]]}}
    assert "single_stair" in with_extra(mutation([], m))
    docs = copy.deepcopy(fort_docs())
    for d in docs:
        d["manifest"]["stairs"].pop("mil")
    assert "single_stair" in codes(check_world(docs))


def test_refuge_on_attack_path():
    m = {"v": 2, "refuge": {"anchor": list(L(0, 10, -2)), "burrow": "Tiefe+"}}
    assert "refuge_on_attack_path" in with_extra(mutation([], m))


def test_refuge_depth_and_well():
    docs = copy.deepcopy(fort_docs())
    docs[2]["manifest"]["refuge"]["anchor"] = list(L(2, 45, -2 - 3))     # on the core level
    assert any("not >= 3 below" in f.msg for f in check_world(docs) if f.code == "refuge")
    docs = copy.deepcopy(fort_docs())
    for st in docs[2]["stages"]:
        for ch in st["chunks"]:
            ch["cells"] = [c for c in ch["cells"] if not (st["mode"] == "build" and c[3] == "l")]
    assert codes(check_world(docs)) == ["refuge_well"]


def test_cage_trap_on_the_main_path():
    t = L(2, 18, -2)
    assert "cage_trap" in with_extra(mutation([("m.b", "build", [(*t, "Tc")])]), final=False)


def test_trap_hall_shape():
    docs = copy.deepcopy(fort_docs())
    for d in docs:
        d["manifest"]["zones"]["Z2"] = d["manifest"]["zones"]["Z2"][:3]   # 10 tiles, 2 bends
    msgs = [f.msg for f in check_world(docs) if f.code == "trap_hall"]
    assert any("< 40" in m for m in msgs) and any("bends" in m for m in msgs)
    wide = L(3, 19, -2)                                                   # widen the hall next to a run
    assert "trap_hall" in with_extra(mutation([dig([wide])]))


def test_gallery_exposed_and_unroofed():
    docs = fort_docs()
    w = bp.as_built(docs)
    w.set(*L(4, 29, -1), ".")                 # a fortification tile turned into floor
    snap = w.snapshot()
    res = bp.audit(snap, w.manifest)
    assert any(x.startswith("gallery: reachable") for x in res["fails"])
    w.set(*L(4, 29, -1), "F")
    w.set(*L(5, 29, 0), "_")                  # hole in the gallery roof
    assert "gallery: not roofed" in bp.audit(w.snapshot(), w.manifest)["fails"]


def bedroom_doc():
    """4 bedrooms and their zone bboxes (west 1, east 2, west 3, east 4), from the `b(3x3)` zone cells."""
    d = bp.emit("bedrooms", {"n": 4}, SITE)
    zones = sorted([(x0, y0, z, x1, y1, z) for st, k, _, x0, y0, x1, y1, z in cell_rects(d) if k == "b"
                    and st["mode"] == "zone"], key=lambda b: (b[1], b[0]))
    return d, zones


def test_unclosed_room():
    d, rooms = bedroom_doc()
    r = rooms[0]                                              # west room 1: open its far wall
    hole = (r[0] - 1, r[1] + 1, r[2])
    got = codes(check_world([d, mutation([dig([hole])], anchor=SITE["anchor"])]))
    assert got == ["unclosed_room"]
    assert check_world([d]) == []
    beside = (r[3] + 1, r[1], r[2])            # the wall to the corridor beside the door: a leak inside the block
    assert codes(check_world([d, mutation([dig([beside])], anchor=SITE["anchor"])])) == ["unclosed_room"]


def test_diagonal_leak_between_rooms():
    d, rooms = bedroom_doc()
    r1, r3 = rooms[0], rooms[2]
    # dig the wall-row tile beside room 1's corner: room 1 and room 3 now touch only diagonally
    gap = (r1[0] - 1, r1[4] + 1, r1[2])
    got = codes(check_world([d, mutation([dig([gap])], anchor=SITE["anchor"])]))
    assert got == ["diagonal_leak"] and r3[1] == r1[4] + 2


def test_build_on_rock_and_bad_cells():
    d = bp.emit("temple", {}, SITE)
    rock = (SITE["anchor"][0] + 20, SITE["anchor"][1], SITE["anchor"][2])
    assert codes(check_world([d, mutation([("m.b", "build", [(*rock, "b")])], anchor=SITE["anchor"])])) == \
        ["build_tile"]
    bad = copy.deepcopy(d)
    bad["stages"][0]["chunks"][0]["cells"][0][3] = "zz{"
    bad["stages"][1]["chunks"][0]["cells"][0][3] = "Q"
    assert codes(bp.check_doc(bad)) == ["cell"]
    heavy = copy.deepcopy(d)
    heavy["stages"][0]["chunks"][0]["cells"] = [[0, 0, 0, "d(30x1)"], [0, 1, 0, "d(30x1)"]]
    assert codes(bp.check_doc(heavy)) == ["chunk"]
    zone = copy.deepcopy(d)
    zs = [s for s in zone["stages"] if s["mode"] == "zone"][0]
    zs["chunks"][0]["cells"][0][3] = "m"
    assert codes(bp.check_doc(zone)) == ["cell"]                 # zones need explicit extents
    assert codes(bp.check_doc({**d, "class": "palace"})) == ["schema"]
