"""BUG-313 (Run 15, three forts): the refuge hatches 55,82,133 (Earthboat), 89,72,137 (Drillchamber) and 86,53,126
(Inkintense) stood 'not suspended, no builder has taken it; 1 item attached' for hundreds of days beside idle dwarves; the
BUG-274 re-place gave a fresh job nobody took either. Each lies on the up/down stair one level above the refuge, inside a shaft
walled in on all 8 sides of that level (the snapshots: `#X#` rows), so no builder has a tile to build it from. `seal
at=refuge` (cmd.refuge_stair) now puts the hatch on the first level of the same stair with a tile beside it (Earthboat: the
dormitory level 55,82,135). Each test fails on 9ef2ccb."""
import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema

BBOX = [50, 77, 131, 60, 87, 139]
MAN = {"v": 2, "refuge": {"anchor": [55, 84, 132], "burrow": "Tiefe+"}, "stairs": {"civ": [[55, 82, 132, 138]]},
       "zones": {"Z4": [[50, 77, 131, 60, 87, 139]]}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def earthboat(save, boxed=(133, 134), open_levels=(132, 135, 138), extra=None):
    """The Earthboat shaft (snap s155173869-3): refuge floor on z132 with '<', z133/z134 'X' in walls, z135 a room level
    with 'X', z136/z137 walled 'X', z138 the core level with '>'. Rock '#' everywhere else (revealed)."""
    x0, y0, z0, x1, y1, z1 = BBOX
    tiles = {}
    for z in open_levels:
        for y in range(78, 87):
            for x in range(51, 60):
                tiles[(x, y, z)] = "."
    tiles[(55, 82, 132)] = "<"
    for z in range(133, 138):
        tiles[(55, 82, z)] = "X"
    tiles[(55, 82, 138)] = ">"
    for k, v in (extra or {}).items():
        tiles[k] = v
    rows = {f"z{z}": ["".join(tiles.get((x, y, z), "#") for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
            for z in range(z0, z1 + 1)}
    doc = {"v": 2, "id": "e1", "tick": 155_173_869, "purpose": "sites", "bbox": BBOX, "rows": rows, "bridges": {},
           "traps": []}
    assert schema.validate("snapshot", doc) == []
    files.write_json_atomic(save / "snap" / "e1.json", doc)
    assert schema.validate("manifest", MAN) == []
    files.write_json_atomic(save / "manifest.json", MAN)
    return doc


def test_a_head_walled_in_on_its_level_moves_up_to_the_first_level_with_a_floor_beside_it(save):
    snap = earthboat(save)
    assert cmd.stair_boxed(snap, 55, 82, 133) is True
    assert cmd.stair_boxed(snap, 55, 82, 135) is False
    rs = cmd.refuge_stair(save)
    assert (rs["state"], rs["head"], rs["man"]) == ("moved", "55,82,135 stair_updown", "55,82,133 stair_updown"), \
        "old code: ok at 55,82,133 (the tile no builder can build from)"
    assert "no tile beside it on its level to build from" in rs["note"] and "hatch moved to 55,82,135" in rs["note"]
    assert cmd.seal_openings(save, "refuge")[0] == "55,82,135 stair_updown"
    sites, _ = cmd.rank_sites(save, "seal", {"at": "55,82,135 stair_updown"})
    assert sites and sites[0]["anchor"] == [55, 82, 135]


def test_the_plan_check_demands_the_moved_hatch(save):
    earthboat(save)
    st = files.read_state(save)
    st["phase"] = "P1"
    st.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    st["alert"]["ref"] = {"ex": 1, "sep": 1, "beds": 13, "need": 13}
    fort = plan.fort_facts(save, st)
    r = fort["refuge"]
    assert (r["head"], r["head_state"], r["head_open"]) == ("55,82,135 stair_updown", "moved", True)


def test_a_hatch_already_standing_higher_up_is_the_head(save):
    earthboat(save, extra={(55, 82, 135): "+"})
    rs = cmd.refuge_stair(save)
    assert rs["head"].startswith("55,82,135") and rs["state"] == "moved"


@pytest.mark.parametrize("extra", [{(54, 82, 133): "."}, {(54, 82, 133): "?"}])
def test_a_head_with_a_floor_beside_it_or_an_unknown_neighbour_stays(save, extra):
    """A floor beside the head (a builder stands there) or a hidden neighbour (unknown, nothing read): as before."""
    earthboat(save, extra=extra)
    rs = cmd.refuge_stair(save)
    assert (rs["state"], rs["head"]) == ("ok", "55,82,133 stair_updown")


def test_no_level_of_the_stair_has_a_floor_beside_it_the_head_stays(save):
    earthboat(save, open_levels=(132,))
    assert cmd.refuge_stair(save)["head"] == "55,82,133 stair_updown"
