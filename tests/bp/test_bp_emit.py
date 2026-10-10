"""WP3 emitter: CONTRACTS §9.8 documents, chunk rule, params, rotation, fortcore stages, golden files."""
import json

import pytest

from df_llm_helper import bp, schema as S
from df_llm_helper.bp import fortcore
from df_llm_helper.bp.emit import MAX_W, cell_key
from df_llm_helper.bp.primitives import merge_manifest, parse_cell

from bp_fixtures import SITE, golden

TPLS = sorted(bp.TEMPLATES)
ROOMS = [t for t in TPLS if t != "fortcore"]


def all_docs(tpl, rot=0, params=None):
    return bp.emit_all(tpl, params, {**SITE, "rot": rot})


@pytest.mark.parametrize("rot", range(4))
@pytest.mark.parametrize("tpl", TPLS)
def test_docs_follow_the_contract(tpl, rot):
    for d in all_docs(tpl, rot):
        assert "id" not in d
        assert S.validate("bp", {**d, "id": "c123"}) == []
        assert S.validate("manifest", d["manifest"]) == []
        assert bp.check_doc(d) == []
        for st in d["stages"]:
            for ch in st["chunks"]:
                assert 1 <= len(ch["cells"]) <= MAX_W
                weight = 0
                for dx, dy, dz, text in ch["cells"]:
                    key, _, ext, err = parse_cell(text)
                    assert err is None and min(dx, dy, dz) >= 0
                    w, h = ext or (1, 1)
                    weight += w * h if st["mode"] in ("dig", "burrow") else 1
                    if st["mode"] in ("zone", "place", "burrow"):
                        assert ext is not None, text          # explicit extents keep entities apart
                assert weight <= MAX_W
        assert len(json.dumps(d)) < 12000                     # persist budget per bp.<id>


@pytest.mark.parametrize("tpl", TPLS)
def test_rotation_keeps_contents(tpl):
    def summary(rot):
        docs = all_docs(tpl, rot)
        tiles = sum(w * h for d in docs for st in d["stages"] if st["mode"] == "dig"
                    for ch in st["chunks"] for *_, t in ch["cells"]
                    for w, h in [parse_cell(t)[2] or (1, 1)])
        return [d["materials"] for d in docs], tiles, [len(d["manifest"].get("rooms", [])) for d in docs]
    base = summary(0)
    assert all(summary(r) == base for r in (1, 2, 3))


def test_bridge_keys_rotate_with_the_template():
    keys = []
    for rot in range(4):
        d = all_docs("fortcore", rot)[1]
        b = [t for st in d["stages"] for ch in st["chunks"] for *_, t in ch["cells"] if cell_key(t)[:1] == "g"]
        keys.append(b[0][:2])
    assert keys == ["gw", "gd", "gx", "ga"]                  # raises toward the field in every rotation


def test_params_are_checked():
    assert bp.check_params("bedrooms", {"n": 20}) == {"n": 20, "tier": 500, "burrow": "Kern+"}
    for tpl, p in [("bedrooms", {"n": 0}), ("bedrooms", {"n": "4"}), ("bedrooms", {"rooms": 4}),
                   ("dining", {"tavern": 1}), ("bedrooms", {"n": True}), ("tombs", {"burrow": "a b"}),
                   ("workshops", {"skip": "Forge"}), ("workshops", {"skip": ",".join(bp.MOODABLE_TYPES)}),
                   ("fortcore", {"stage": 4}), ("nope", {})]:
        with pytest.raises(ValueError):
            bp.emit(tpl, p, SITE)
    for site in ({"anchor": [1, 2]}, {"anchor": [1, 2, 3], "rot": 4}, "S1", {"anchor": [-1, 0, 0]}):
        with pytest.raises(ValueError):
            bp.emit("temple", {}, site)
    with pytest.raises(ValueError, match="outside the map"):
        bp.emit("fortcore", {"stage": 3}, {"anchor": [50, 50, 8]})      # refuge would sit below z 0
    with pytest.raises(ValueError, match="outside the map"):
        bp.emit("bedrooms", {}, {"anchor": [2, 50, 8]})                 # rooms reach x < 0
    assert bp.emit("fortcore", {"stage": 3}, {"anchor": [50, 50, 12]})["manifest"]["refuge"]["anchor"][2] == 4


def test_site_forms_and_design_inbox_example():
    d = bp.emit("bedrooms", {"n": 20}, {"id": "S2", "anchor": [60, 40, 120], "rot": 1, "score": 900, "why": ""})
    assert (d["site"], d["anchor"], d["rot"], d["params"]["n"]) == ("S2", [60, 40, 120], 1, 20)
    assert d["materials"] == {"bed": 20, "cabinet": 20, "chest": 20, "door": 20}
    assert bp.emit("temple", None, ([20, 20, 5], 2))["rot"] == 2


def test_fortcore_stage_projects():
    docs = all_docs("fortcore")
    assert [d["class"] for d in docs] == ["infra", "defense", "defense"]
    assert [d["params"]["stage"] for d in docs] == [1, 2, 3]
    assert {s["label"].split(".")[0] for s in docs[0]["stages"]} == {"s1"}
    br = [sorted(d["manifest"].get("bridges", {})) for d in docs]
    assert br == [[], ["B1"], ["B1", "B2", "O1"]]
    m = docs[0]["manifest"]
    for d in docs[1:]:
        m = merge_manifest(m, d["manifest"])
    assert S.validate("manifest", m) == []
    assert m == merge_manifest(m, docs[2]["manifest"])        # cumulative fragments merge idempotently
    roles = {n: (b["role"], len(b["levers"])) for n, b in m["bridges"].items()}
    assert roles == {"O1": ("outer", 2), "B1": ("inner", 2), "B2": ("core", 2)}
    o1 = m["bridges"]["O1"]["fp"]
    assert o1[3] - o1[0] + 1 == 3 and o1[2] == o1[5]
    civ, mil = m["stairs"]["civ"][0], m["stairs"]["mil"][0]
    assert civ[:2] != mil[:2] and civ[2] == m["refuge"]["anchor"][2]
    assert set(m["burrows"]) == {"Kern+", "Tiefe+"} and m["killboxes"][0]["id"] == "K1"
    z2 = sum((b[3] - b[0] + 1) * (b[4] - b[1] + 1) for b in m["zones"]["Z2"])
    assert z2 == len(fortcore.hall_tiles()) == 45
    assert {w["type"] for w in m["workshops"]} == {"Carpenters", "Masons", "Craftsdwarfs", "Still", "Kitchen"}


@pytest.mark.parametrize("depth,refuge", [(2, 3), (3, 3), (6, 5)])
def test_fortcore_depth_params(depth, refuge):
    d = bp.emit("fortcore", {"stage": 3, "depth": depth, "refuge": refuge}, SITE)
    ze = SITE["anchor"][2] - 2
    assert d["manifest"]["refuge"]["anchor"][2] == ze - depth - refuge
    assert bp.validate(all_docs("fortcore", 0, {"depth": depth, "refuge": refuge})) == []


def test_fortcore_traps():
    mats = [d["materials"] for d in all_docs("fortcore")]
    armed = sum(m.get("weapon_trap", 0) + m.get("stonefall_trap", 0) for m in mats)
    assert armed >= 30 and not any("cage_trap" in m for m in mats)
    assert mats[1]["weapon_trap"] == 14 and armed == 41


def test_moodable_workshops_complete():
    d = bp.emit("workshops", {}, SITE)
    assert sorted(w["type"] for w in d["manifest"]["workshops"]) == sorted(bp.MOODABLE_TYPES)
    assert len(bp.MOODABLE_TYPES) == 12
    part = bp.emit("workshops", {"skip": "Carpenters,Masons,Craftsdwarfs"}, SITE)
    assert len(part["manifest"]["workshops"]) == 9 and part["materials"]["workshop"] == 9


def test_room_templates_contents():
    tombs = bp.emit("tombs", {"n": 25}, SITE)
    zones = [t for st in tombs["stages"] if st["mode"] == "zone" for ch in st["chunks"] for *_, t in ch["cells"]]
    assert zones == ["T(1x1)"] * 25 and tombs["materials"]["coffin"] == 25
    hosp = bp.emit("hospital", {"beds": 10}, SITE)
    cells = [t for st in hosp["stages"] for ch in st["chunks"] for *_, t in ch["cells"]]
    assert "m{location=hospital name=Hospital allow=residents}(7x5)" in cells
    assert hosp["materials"]["well"] == 1 and hosp["materials"]["bed"] == 10
    din = bp.emit("dining", {"seats": 40, "tavern": True}, SITE)
    assert din["materials"]["table"] == din["materials"]["chair"] == 40
    assert any("location=tavern" in t for st in din["stages"] for ch in st["chunks"] for *_, t in ch["cells"])
    assert bp.emit("temple", {}, SITE)["manifest"]["rooms"][0]["tier"] == 2000
    assert {r["use"] for r in bp.emit("bedrooms", {}, SITE)["manifest"]["rooms"]} == {"used"}
    assert bp.emit("farms", {}, SITE)["manifest"]["rooms"][0]["use"] == "utility"


@pytest.mark.parametrize("tpl", ROOMS)
def test_rooms_touch_the_anchor_row_only_through_the_doorway(tpl):
    """Room templates dig nothing at v<=1 except the doorway (0,1): the wall ring check of sites.rank
    skips the anchor row, so any other tile there could leak diagonally into the anchor's corridor."""
    dug = bp.TEMPLATES[tpl][0](bp.check_params(tpl, {})).dug()
    assert {(u, v) for u, v in dug[0] if v <= 1} == {(0, 1)}
    assert all(v >= 1 for tiles in dug.values() for _, v in tiles)


def test_list_templates():
    names = [t["tpl"] for t in bp.list_templates()]
    assert names == TPLS and len(names) == 9
    assert all(t["about"] for t in bp.list_templates())


def test_fortcore_builds_no_farm_plots():
    """quickfort builds farm plots only on soil or mud (build.lua:102-104) and counts every other tile as
    build_unsuitable: plots in fortcore stage 1 would block the stage on a stone core level."""
    for d in all_docs("fortcore"):
        assert "farm_plot" not in d["materials"]
        assert not [t for st in d["stages"] for ch in st["chunks"] for *_, t in ch["cells"]
                    if st["mode"] == "build" and cell_key(t) == "p"]
    farms = bp.emit("farms", {"plots": 3}, SITE)
    assert farms["class"] == "infra" and farms["materials"] == {"door": 1, "farm_plot": 3}
    cells = [t for st in farms["stages"] for ch in st["chunks"] for *_, t in ch["cells"] if st["mode"] == "build"]
    assert cells.count("p(5x7)") == 3


@pytest.mark.parametrize("tpl", ROOMS)
def test_rooms_join_z4(tpl):
    """Every room adds its dug bbox to Z4, so later rooms can open from it (sites.rank anchors in Z4)."""
    d = bp.emit(tpl, {}, SITE)
    (z4,) = d["manifest"]["zones"]["Z4"]
    for st in d["stages"]:
        for ch in st["chunks"]:
            for dx, dy, dz, _ in ch["cells"]:
                x, y, z = ch["pos"][0] + dx, ch["pos"][1] + dy, ch["pos"][2] + dz
                assert z4[0] <= x <= z4[3] and z4[1] <= y <= z4[4] and z4[2] <= z <= z4[5]
    assert z4[2] <= SITE["anchor"][2] == z4[5]


def test_bedrooms_are_one_manifest_room():
    """One rooms entry per bedrooms project keeps the manifest under the 8 KB inspect reply limit."""
    d = bp.emit("bedrooms", {"n": 40}, SITE)
    (room,) = d["manifest"]["rooms"]
    assert room["tpl"] == "bedrooms" and room["use"] == "used" and room["tier"] == 500
    assert len(json.dumps(d["manifest"])) < 400


@pytest.mark.parametrize("tpl", TPLS)
def test_golden(tpl):
    want, got = golden(f"{tpl}.json", all_docs(tpl))
    assert got == want, f"golden {tpl}.json changed (DFLLM_REGEN_GOLDEN=1 to accept)"
