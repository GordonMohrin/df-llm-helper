"""FR-102 large rooms (suites, grand_dining, grand_tavern, grand_temple: sizes, tiers, the beauty stage) and FR-103 the deep
core (deepcore stages 1-3) with its anchor search (bp/deep.py) on revealed tiles only."""
import pytest

from dfpilot import bp
from dfpilot.bp import deep, grand, sites
from dfpilot.bp.emit import cell_key
from dfpilot.bp.primitives import merge_manifest

from bp_fixtures import SITE, fort_docs, set_tiles, terrain

GRAND = list(grand.ROOMS)


def _cells(doc, mode=None):
    for st in doc["stages"]:
        if mode and st["mode"] != mode:
            continue
        for ch in st["chunks"]:
            for dx, dy, dz, t in ch["cells"]:
                yield (ch["pos"][0] + dx, ch["pos"][1] + dy, ch["pos"][2] + dz), t, st


def _tiles(doc, mode):
    for (x, y, z), t, _ in _cells(doc, mode):
        w, h = (int(v) for v in t[t.index("(") + 1:-1].split("x")) if "(" in t else (1, 1)
        for dy in range(h):
            for dx in range(w):
                yield x + dx, y + dy, z


@pytest.fixture(scope="module")
def deepw():
    """The fortcore on a 32-level map (as test_bp_explore): core z25, refuge z22, hidden rock down to z1."""
    w = bp.as_built(fort_docs(anchor=[50, 20, 30]), base=terrain(z0=1, z1=32, surf=30).snapshot())
    return w.snapshot(purpose="sites"), w.manifest


@pytest.mark.parametrize("tpl", GRAND)
@pytest.mark.parametrize("size", grand.SIZES)
@pytest.mark.parametrize("rot", range(4))
def test_rooms_both_stages_validate_clean(tpl, size, rot):
    docs = [bp.emit(tpl, {"size": size, "stage": k}, {**SITE, "rot": rot}) for k in (1, 2)]
    assert [str(f) for f in bp.validate(docs)] == []
    assert [d["class"] for d in docs] == ["living", "beauty"]          # beauty: PEACE + R1 + policy (runner)
    r1, r2 = (d["manifest"]["rooms"] for d in docs)
    assert r1 == r2 and r1[0]["use"] == "used" and r1[0]["tier"] == grand.TIERS[tpl][size]
    assert "zones" in docs[0]["manifest"] and "zones" not in docs[1]["manifest"]      # only the dig joins Z4


@pytest.mark.parametrize("tpl", GRAND)
def test_beauty_stage_smooths_then_engraves_only_the_room_and_its_walls(tpl):
    d1 = bp.emit(tpl, {"size": "grand"}, SITE)
    d2 = bp.emit(tpl, {"size": "grand", "stage": 2}, SITE)
    assert [s["label"] for s in d2["stages"]] == ["beauty.smooth", "beauty.engrave"]
    assert {cell_key(t) for _, t, _ in _cells(d2)} == {"s", "e"} and d2["materials"] == {}
    dug = set(_tiles(d1, "dig"))
    x0, y0, x1, y1 = (min(p[0] for p in dug) - 1, min(p[1] for p in dug), max(p[0] for p in dug) + 1,
                      max(p[1] for p in dug) + 1)
    w = bp.as_built([d1, d2])
    for x, y, z in _tiles(d2, None):
        assert x0 <= x <= x1 and y0 <= y <= y1 and z == SITE["anchor"][2]
    assert w.errors == []


def test_sizes_and_tiers():
    small = bp.emit("bedrooms", {"n": 8}, SITE)["manifest"]["zones"]["Z4"][0]
    lg = bp.emit("suites", {"n": 8}, SITE)["manifest"]["zones"]["Z4"][0]
    gr = bp.emit("suites", {"n": 8, "size": "grand"}, SITE)["manifest"]["zones"]["Z4"][0]
    area = [(b[3] - b[0] + 1) * (b[4] - b[1] + 1) for b in (small, lg, gr)]
    assert area[0] < area[1] < area[2]
    s = bp.emit("suites", {"n": 6, "size": "grand"}, SITE)
    assert s["materials"]["statue"] == 6 and s["materials"]["bed"] == 6 and s["materials"]["door"] == 7
    assert "statue" not in bp.emit("suites", {"n": 6}, SITE)["materials"]
    assert bp.emit("grand_temple", {"size": "grand"}, SITE)["materials"]["statue"] == 6
    din = bp.emit("grand_dining", {"seats": 40, "size": "grand"}, SITE)
    assert din["materials"]["table"] == din["materials"]["chair"] == 40 and din["materials"]["statue"] >= 8
    tav = bp.emit("grand_tavern", {}, SITE)
    assert any("location=tavern" in t for _, t, _ in _cells(tav, "zone")) and tav["materials"]["chest"] == 2
    assert bp.emit("suites", {"tier": 1500}, SITE)["manifest"]["rooms"][0]["tier"] == 1500
    with pytest.raises(ValueError, match="size"):
        bp.emit("suites", {"size": "huge"}, SITE)


def test_suites_and_grand_temple_are_private_the_deep_dorm_too():
    for tpl in ("suites", "grand_temple"):
        r = bp.emit(tpl, {}, SITE)["manifest"]["rooms"][0]
        assert sites._private(r)
    assert not sites._private(bp.emit("grand_dining", {}, SITE)["manifest"]["rooms"][0])
    rs = {r["id"].rsplit("_", 1)[-1]: r for r in bp.emit("deepcore", {"stage": 2}, SITE)["manifest"]["rooms"]}
    assert sites._private(rs["dorm"]) and not sites._private(rs["wshop"])


@pytest.mark.parametrize("rot", range(4))
def test_deepcore_three_stages(rot):
    docs = [bp.emit("deepcore", {"stage": k, "depth": 6}, {**SITE, "rot": rot}) for k in (1, 2, 3)]
    assert [str(f) for f in bp.validate(docs)] == []
    z = SITE["anchor"][2] - 6
    assert [d["class"] for d in docs] == ["living"] * 3                  # PEACE only (runner class gating)
    z4 = docs[0]["manifest"]["zones"]["Z4"]
    assert min(b[2] for b in z4) == z and max(b[5] for b in z4) == SITE["anchor"][2]
    assert docs[1]["materials"]["workshop"] == 6 and docs[1]["materials"]["bed"] == 12
    assert {w["type"] for w in docs[1]["manifest"]["workshops"]} >= {"Still", "Kitchen", "Masons"}
    piles = [t for _, t, _ in _cells(docs[2], "place")]
    assert len(piles) == 4 and all("name=dfllm-deep-" in t for t in piles)
    zones = [t for _, t, _ in _cells(docs[2], "zone")]
    assert any(t.startswith("D{name=DeepDorm}") for t in zones) and any(t.startswith("h{") for t in zones)
    bur = {p[2] for p, t, _ in _cells(docs[2], "burrow") if "Kern+" in t}
    assert bur == set(range(z, SITE["anchor"][2] + 1))                  # Kern+ over every shaft level and the rooms
    assert [r["id"].rsplit("_", 1)[-1] for r in docs[2]["manifest"]["rooms"]] == ["hall"]
    # stage 1 builds the vestibule door at once: the old core room the shaft opens from stays closed
    assert [t for _, t, st in _cells(docs[0], "build")] == ["d"]


def test_deep_rank_on_the_fort(deepw):
    snap, man = deepw
    zr = man["refuge"]["anchor"][2]
    best = bp.rank(snap, "deepcore", {"depth": 8}, manifest=man)
    assert best and all(s["depth"] == 8 for s in best)
    refuge = [r["bbox"] for r in man["rooms"] if r["id"].endswith("_refuge")]
    s = best[0]
    docs = [bp.emit("deepcore", {"stage": k, "depth": 8}, s) for k in (1, 2, 3)]
    w = bp.as_built(docs, base=snap)
    assert w.errors == []
    m = man
    for d in docs:
        m = merge_manifest(m, d["manifest"])
    w.manifest = m
    assert bp.audit(w.snapshot(), m)["ok"]                          # the second core opens no way in
    assert [str(f) for f in bp.validate(fort_docs(anchor=[50, 20, 30]) + docs)] == []
    for (x, y, z), _, _ in _cells(docs[0], "dig"):                   # never beside the refuge
        assert not any(b[0] - 2 <= x <= b[3] + 2 and b[1] - 2 <= y <= b[4] + 2 and b[2] - 1 <= z <= b[5] + 1
                       for b in refuge)
    assert s["anchor"][2] > zr
    with pytest.raises(ValueError, match="Z4"):
        bp.rank(snap, "deepcore", {}, manifest={"v": 2})


def test_deep_pick_takes_the_deepest_known_dry_level_and_needs_one(deepw):
    snap, man = deepw
    r = deep.pick(snap, man, [20, 15, 14])
    assert r["z"] == 14 and r["depth"] == r["anchor"][2] - 14 and "known dry" in r["why"]
    assert "explore first" in deep.pick(snap, man, [])["why"]
    zr = man["refuge"]["anchor"][2]
    assert "anchor" not in deep.pick(snap, man, [zr, zr - 1])            # never on or beside the refuge level


def test_deep_pick_keeps_off_caverns_aquifers_breaches_and_soil(deepw):
    snap, man = deepw
    cave = {**snap, "marks": {"cavern": [[5, 5, 12]]}}                 # a revealed cavern on z12
    assert deep.pick(cave, man, [14])["why"].startswith("deepcore: no site")     # 14 is within CAVERN_GAP above it
    assert deep.pick(cave, man, [16])["z"] == 16
    assert deep.pick(snap, {**man, "aquifer_levels": [18]}, [14]).get("z") is None     # the shaft would pass it
    assert deep.pick(snap, {**man, "caverns": [[9, 9, 20]]}, [14]).get("z") is None
    b = {**man, "breaches": [{"pos": [9, 9, 17], "why": "damp"}]}
    assert deep.pick(snap, b, [14]).get("z") is None and deep.pick(snap, b, [19])["z"] == 19
    best = deep.pick(snap, man, [14])
    from dfpilot.bp.primitives import Xform
    hub = list(Xform(best["anchor"], best["rot"]).pos(0, 5, -best["depth"]))
    soil = {**snap, "marks": {"soil": [hub]}}
    other = deep.pick(soil, man, [14])
    assert other.get("anchor") != best["anchor"] or other.get("rot") != best["rot"]


def test_deep_pick_refuses_revealed_open_space_at_the_deep_level(deepw):
    snap, man = deepw
    best = deep.pick(snap, man, [14])
    from dfpilot.bp.primitives import Xform
    X = Xform(best["anchor"], best["rot"])
    hole = set_tiles(snap, [X.pos(u, v, -best["depth"]) for u in range(-14, 21) for v in (1, 18)], "_")
    again = deep.pick(hole, man, [14])
    assert (again.get("anchor"), again.get("rot")) != (best["anchor"], best["rot"])
