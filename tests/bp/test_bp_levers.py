"""Live L3 fortcore changes: lever rooms (puller burrows), a lever per bridge inside Tiefe+ (BREACH), and a
stage 4 without weapon traps (they took picks, axes and crossbows; quickfort ordered iron battle axes)."""
import pytest

from dfpilot import bp, schema as S
from dfpilot.bp import fortcore
from dfpilot.bp.emit import cell_key
from dfpilot.bp.primitives import merge_manifest, parse_cell

from bp_fixtures import SITE


def docs(rot=0, params=None):
    return bp.emit_all("fortcore", params, {**SITE, "rot": rot})


def manifest(ds):
    m = ds[0]["manifest"]
    for d in ds[1:]:
        m = merge_manifest(m, d["manifest"])
    return m


def cells(doc, mode=None, label=None):
    """(x, y, z, text, stage label) for every cell, expanded to absolute positions."""
    for st in doc["stages"]:
        if (mode and st["mode"] != mode) or (label and st["label"] != label):
            continue
        for ch in st["chunks"]:
            px, py, pz = ch["pos"]
            for dx, dy, dz, text in ch["cells"]:
                yield px + dx, py + dy, pz + dz, text, st["label"]


def burrow_tiles(ds, name):
    out = set()
    for d in ds:
        for x, y, z, text, _ in cells(d, mode="burrow"):
            key, props, ext, _ = parse_cell(text)
            if key == "a" and props and f"name={name} " in props + " ":
                w, h = ext
                out |= {(x + i, y + j, z) for i in range(w) for j in range(h)}
    return out


@pytest.mark.parametrize("rot", range(4))
def test_lever_rooms_hold_the_main_levers(rot):
    ds = docs(rot)
    m = manifest(ds)
    assert m["burrows"]["dfllm-levers"] == {"role": "other"} and m["burrows"]["dfllm-levers-b2"] == {"role": "other"}
    z3 = burrow_tiles(ds, "dfllm-levers")
    z4 = burrow_tiles(ds, "dfllm-levers-b2")
    assert 0 < len(z3) <= 16 and 0 < len(z4) <= 8, "small rooms: the pullers stay next to the levers"
    lv = {n: [tuple(p) for p in b["levers"]] for n, b in m["bridges"].items()}
    assert set(lv["O1"][:2]) | set(lv["B1"][:2]) <= z3
    assert set(lv["B2"][:2]) <= z4
    assert not z3 & z4
    kern, tiefe = burrow_tiles(ds, "Kern+"), burrow_tiles(ds, "Tiefe+")
    assert z3 <= kern and z4 <= kern, "the rooms lie inside Kern+ (SIEGE alert)"
    assert not (z3 | z4) & tiefe
    # the B1 room is created with B1 (stage 2), the B2 room with B2 (stage 3)
    assert burrow_tiles(ds[:2], "dfllm-levers") == z3 and not burrow_tiles(ds[:2], "dfllm-levers-b2")
    assert "dfllm-levers" in ds[1]["manifest"]["burrows"] and "dfllm-levers-b2" not in ds[1]["manifest"]["burrows"]


@pytest.mark.parametrize("rot", range(4))
def test_every_bridge_has_a_lever_inside_tiefe(rot):
    ds = docs(rot)
    m = manifest(ds)
    tiefe = burrow_tiles(ds, "Tiefe+")
    zr = m["refuge"]["anchor"][2]
    for n, b in m["bridges"].items():
        inside = [p for p in b["levers"] if tuple(p) in tiefe]
        assert len(inside) == 1 and inside[0][2] == zr, n
        assert b["levers"][-1] == inside[0], f"{n}: the refuge lever comes last (the main levers first)"
    # built in their own stage after the main levers (buildingplan gives the first mechanisms to O1/B2)
    s3 = ds[2]
    labels = [st["label"] for st in s3["stages"]]
    assert labels[-1] == "s3.lever" and labels.index("s3.build") < labels.index("s3.lever")
    built = {(x, y, z) for x, y, z, text, _ in cells(s3, label="s3.lever") if cell_key(text) == "Tl"}
    assert built == {tuple(b["levers"][-1]) for b in m["bridges"].values()}
    # nothing else of stage 3 stands on those tiles
    other = {(x, y, z) for x, y, z, _, lab in cells(s3) if lab in ("s3.build", "s3.place") and z == zr}
    assert not built & other


def test_refuge_levers_pass_the_audit_and_validators():
    ds = docs()
    assert bp.validate(ds) == []
    m = manifest(ds)
    assert S.validate("manifest", m) == []
    zr = m["refuge"]["anchor"][2]
    z4 = m["zones"]["Z4"]
    for b in m["bridges"].values():
        p = b["levers"][-1]
        assert any(z[0] <= p[0] <= z[3] and z[1] <= p[1] <= z[4] and z[2] <= p[2] <= z[5] for z in z4), p
        assert p[2] == zr


@pytest.mark.parametrize("rot", range(4))
def test_stage4_has_no_weapon_traps(rot):
    ds = docs(rot)
    keys = [cell_key(t) for d in ds for *_, t, _ in cells(d, mode="build")]
    assert "Tw" not in keys and "TS" not in keys, "a weapon trap takes any free weapon (picks, axes, crossbows)"
    s4 = ds[3]
    assert [st["label"] for st in s4["stages"]] == ["s4.build"] and s4["stages"][0]["orders"] == 1
    traps = [(x, y, z) for x, y, z, t, _ in cells(s4) if cell_key(t) == "Ts"]
    assert len(traps) == len(set(traps)) == 41
    assert s4["materials"] == {"mechanism": 41, "stonefall_trap": 41}, "only mechanisms are ordered"
    hall = {(x, y) for b in manifest(ds)["zones"]["Z2"] for x in range(b[0], b[3] + 1) for y in range(b[1], b[4] + 1)}
    assert all((x, y) in hall for x, y, _ in traps)


def test_stage_mechanisms_stay_in_order():
    """Live L2: the levers get mechanisms before anything else; refuge levers come after the main ones."""
    mats = [d["materials"] for d in docs()]
    assert mats[1]["lever"] == 2 and mats[2]["lever"] == 4 + len(fortcore.REFUGE_LEVERS)
    assert "lever" not in mats[3]


def test_retrofit_places_only_the_rooms_and_refuge_levers():
    """Live fort (Castlerisen, stages 1-3 placed before L3): `retrofit=2` adds the lever rooms and the refuge
    levers as a project of its own; re-placing whole stages would re-apply their zones."""
    full = docs()
    r3 = bp.emit("fortcore", {"stage": 3, "retrofit": 2}, SITE)
    assert S.validate("bp", {**r3, "id": "r3"}) == [] and bp.check_doc(r3) == []
    assert [st["label"] for st in r3["stages"]] == ["s3.lrooms", "s3.lever"]
    assert r3["stages"][1]["orders"] == 1 and r3["materials"] == {"lever": 3, "mechanism": 9}
    for name in ("dfllm-levers", "dfllm-levers-b2"):
        assert burrow_tiles([r3], name) == burrow_tiles(full, name)
    assert not burrow_tiles([r3], "Kern+") and not burrow_tiles([r3], "Tiefe+")
    built = {(x, y, z) for x, y, z, _, _ in cells(r3, mode="build")}
    assert built == {(x, y, z) for x, y, z, _, _ in cells(full[2], label="s3.lever")}
    assert merge_manifest(manifest(full), r3["manifest"]) == manifest(full), "the fragment adds nothing new twice"
    m_old = manifest(full[:2])                                  # what a pre-L3 fort's manifest lacks
    assert set(merge_manifest(m_old, r3["manifest"])["burrows"]) >= {"dfllm-levers", "dfllm-levers-b2"}
    with pytest.raises(ValueError, match="retrofit"):
        bp.emit("fortcore", {"stage": 2, "retrofit": 2}, SITE)   # refuge levers need the refuge (stage 3)
    for stage in (1, 4):          # stage 4 would mark the traps as reached in the runner's history
        for kind in (1, 2):
            with pytest.raises(ValueError, match="retrofit"):
                bp.emit("fortcore", {"stage": stage, "retrofit": kind}, SITE)


@pytest.mark.parametrize("stage", (2, 3))
def test_retrofit_rooms_only_is_a_burrow_project_with_a_rooms_fragment(stage):
    """`retrofit=1`: the rooms alone, done in one runner pass (gate gets the rooms, and the B2 room as the BREACH
    fallback, before any refuge lever is built); the fragment holds only the rooms, so finishing after the
    `retrofit=2` project (or a stage) never drops a refuge lever from a bridge's lever list."""
    full = docs()
    r = bp.emit("fortcore", {"stage": stage, "retrofit": 1}, SITE)
    assert S.validate("bp", {**r, "id": "r"}) == [] and bp.check_doc(r) == []
    assert [(st["label"], st["mode"]) for st in r["stages"]] == [(f"s{stage}.lrooms", "burrow")]
    assert r["materials"] == {}
    names = {"dfllm-levers"} | ({"dfllm-levers-b2"} if stage == 3 else set())
    assert r["manifest"] == {"v": 2, "burrows": {n: {"role": "other"} for n in names}}
    for name in names:
        assert burrow_tiles([r], name) == burrow_tiles(full, name)
    if stage == 2:
        assert not burrow_tiles([r], "dfllm-levers-b2")
    m_full = manifest(full)
    assert merge_manifest(m_full, r["manifest"]) == m_full, "after retrofit=2: the refuge levers stay"
    m_old = manifest(full[:stage])
    merged = merge_manifest(m_old, r["manifest"])
    assert set(merged["burrows"]) >= names and merged.get("bridges") == m_old.get("bridges")


@pytest.mark.parametrize("rot", range(4))
def test_core_station_lies_in_the_core_by_the_civilian_stair(rot):
    """BUG-030: stage 3's `stations.core` (the deep defense's station, posture CORE) lies on Kern+ next to the
    civilians' stair to the refuge, on another level than every bridge (a station at `b2` stands next to B2's footprint
    and holds its raise), outside the attack zones Z1-Z3 and the killing field."""
    ds = docs(rot)
    m = manifest(ds)
    core = m["stations"]["core"]
    assert "core" not in (ds[1]["manifest"].get("stations") or {}), "stage 3 brings it, with B2 and the refuge"
    assert tuple(core) in burrow_tiles(ds, "Kern+")
    civ = m["stairs"]["civ"][0]
    assert max(abs(core[0] - civ[0]), abs(core[1] - civ[1])) <= 2 and civ[2] <= core[2] <= civ[3]
    assert all(core[2] != b["fp"][2] for b in m["bridges"].values())
    inside = lambda p, b: b[0] <= p[0] <= b[3] and b[1] <= p[1] <= b[4] and b[2] <= p[2] <= b[5]  # noqa: E731
    attack = [b for k in ("Z1", "Z2", "Z3") for b in m["zones"].get(k, [])] + [k["bbox"] for k in m["killboxes"]]
    assert not any(inside(core, b) for b in attack)
    assert S.validate("manifest", m) == []
