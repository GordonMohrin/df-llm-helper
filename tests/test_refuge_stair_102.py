"""BUG-123..125 (Run 14 note 102, y710): `plan check` demanded `seal at=refuge` as the first build for a manifest stair at
77,68,125 that was undug, unrevealed rock; the seal then failed ("the tile is not revealed"), so every build including the
hospital was blocked and only an empty plan could be applied. Python side:
BUG-123 a manifest stair that is no stair on the map (unrevealed or revealed rock) is the warning "refuge: no stair found (not
dug)", never an error, and the stale manifest entry stays in the manifest; BUG-124 a real stair whose head tile is not revealed
moves the hatch to the nearest revealed tile of the same stair, or (none) is a warning that asks the player to look at the tile;
BUG-125 hospital, tombs (coffins), food and drink builds are never held back by the seal demand, a real exposed refuge (open
stair, revealed head, no hatch) is still demanded first for the other builds, and the seal ranking names the unrevealed tile.
Every test fails on f3f684b."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema

HEAD = (77, 68, 125)
BBOX = [70, 60, 122, 85, 75, 128]
MAN = {"v": 2, "refuge": {"anchor": [75, 66, 124], "burrow": "Tiefe+"}, "stairs": {"civ": [[77, 68, 124, 127]]},
       "zones": {"Z4": [[70, 60, 126, 85, 75, 127]]}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def snapshot(save, tiles, fill="?", sid="g1"):
    """A sites snapshot over BBOX: every tile `fill` (? hidden, # revealed rock) but `tiles` {(x, y, z): char}."""
    x0, y0, z0, x1, y1, z1 = BBOX
    rows = {}
    for z in range(z0, z1 + 1):
        rows[f"z{z}"] = ["".join(tiles.get((x, y, z), fill) for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
    doc = {"v": 2, "id": sid, "tick": 1_400_000, "purpose": "sites", "bbox": BBOX, "rows": rows, "bridges": {}, "traps": []}
    assert schema.validate("snapshot", doc) == []
    files.write_json_atomic(save / "snap" / f"{sid}.json", doc)
    return doc


def manifest(save, man=MAN):
    assert schema.validate("manifest", man) == []
    files.write_json_atomic(save / "manifest.json", man)


def facts(save):
    st = files.read_state(save)
    st = copy.deepcopy(st)
    st["phase"] = "P1"
    st.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    st["alert"]["ref"] = {"ex": 1, "sep": 1, "beds": 13, "need": 13}
    assert schema.validate("state", st) == []
    return st, plan.fort_facts(save, st)


def check(save, builds, st=None, fort=None, later=()):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["phase_target"] = "P1"
    doc["seasons"][1]["build"] += builds
    doc["seasons"][2]["build"] += later
    st, fort2 = (st, fort) if st else facts(save)
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev, fort=fort or fort2)
    return [e for e in errs if e.startswith("refuge")], [w for w in warn if w.startswith("refuge")]


DINING = {"tpl": "dining", "site": "S1"}
HOSPITAL = {"tpl": "hospital", "site": "S1"}
TOMBS = {"tpl": "tombs", "site": "S1"}


# ---------------------------------------------------------------- BUG-123: no stair on the map
@pytest.mark.parametrize("head_char", ["?", "#"])
def test_a_manifest_stair_that_is_no_stair_on_the_map_is_a_warning(save, head_char):
    """The head tile and the whole stair column undug: unrevealed ('?', the note) or revealed rock ('#')."""
    manifest(save)
    snapshot(save, {HEAD: head_char}, fill="?" if head_char == "?" else "#")
    st, fort = facts(save)
    assert fort["refuge"]["head"] is None and fort["refuge"]["head_open"] is False
    assert fort["refuge"]["head_state"] == "nostair" and fort["refuge"]["head_man"] == "77,68,125 stair_updown"
    errs, warn = check(save, [DINING, HOSPITAL], st, fort)
    assert errs == [], "old code: ERROR the civilians' stair enters Tiefe+ below 77,68,125 without a hatch"
    assert warn == ["refuge: no stair found (not dug) at the manifest's stair head 77,68,125; the stale manifest entry is "
                    "kept, no hatch is demanded (dfllm cmd inspect what=refuge, trust.hatch)"]


def test_the_seal_for_a_missing_stair_is_left_out_not_an_error(save):
    manifest(save)
    snapshot(save, {})
    with pytest.raises(cmd.SealClosed, match=r"refuge: no stair found \(not dug\)"):
        cmd.seal_openings(save, "refuge")
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    for se in doc["seasons"]:
        se["build"] = []
    doc["seasons"][1]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "refuge"}})
    left: list[str] = []
    docs, _, lines = plan.place_all(save, doc, None, left)
    assert not [d for d in docs if d["tpl"] == "seal"]
    assert any("no stair found" in x for x in left), left
    assert cmd.refuge_head(save) is None
    assert files.read_manifest(save)["stairs"] == MAN["stairs"], "the stale entry is flagged, not deleted"


# ---------------------------------------------------------------- BUG-124: a real stair, head not revealed
def test_the_hatch_moves_to_the_nearest_revealed_tile_of_the_same_stair(save):
    manifest(save)
    snapshot(save, {(77, 68, 124): "<", (77, 68, 126): "X", (77, 68, 127): ">"})        # 125 (the head) stays hidden
    assert cmd.refuge_head(save) == "77,68,126 stair_updown"
    assert cmd.seal_openings(save, "refuge")[0] == "77,68,126 stair_updown"
    st, fort = facts(save)
    r = fort["refuge"]
    assert (r["head"], r["head_state"], r["head_man"]) == ("77,68,126 stair_updown", "moved", "77,68,125 stair_updown")
    assert r["head_open"] is True
    errs, warn = check(save, [DINING], st, fort)
    assert len(errs) == 1 and "below 77,68,126 without a hatch" in errs[0], errs
    assert any("hatch moved to 77,68,126" in w and "77,68,125 is not revealed" in w for w in warn), warn
    # the ranking accepts the moved tile (old code: ValueError the tile is not revealed)
    at = cmd.seal_openings(save, "refuge")[0]
    sites, _ = cmd.rank_sites(save, "seal", {"at": at})
    assert sites and sites[0]["anchor"] == [77, 68, 126]


def test_a_real_stair_with_no_revealed_tile_above_asks_the_player(save):
    """Only the refuge level of the stair is revealed: the stair is real, the hatch has no tile. A warning, no error."""
    manifest(save)
    snapshot(save, {(77, 68, 124): "<"})
    st, fort = facts(save)
    r = fort["refuge"]
    assert (r["head"], r["head_state"], r["head_open"]) == (None, "hidden", False)
    errs, warn = check(save, [DINING, HOSPITAL], st, fort)
    assert errs == []
    assert warn == ["refuge: the civilians' stair is real (77,68,124 is a stair) but its hatch tile 77,68,125 is not revealed: "
                    "look at the tile in the game, then dfllm bp sites seal --fresh (the kernel asks once: DECISION_NEEDED "
                    "refuge_hatch)"]
    with pytest.raises(cmd.SealClosed, match="77,68,125 is not revealed"):
        cmd.seal_openings(save, "refuge")


# ---------------------------------------------------------------- BUG-125: life builds first, a real exposed refuge
def test_hospital_tombs_food_and_drink_are_never_held_back_by_the_seal_demand(save):
    manifest(save)
    snapshot(save, {(77, 68, 124): "<", (77, 68, 125): "X", (77, 68, 126): "X", (77, 68, 127): ">"})   # real, open head
    st, fort = facts(save)
    assert fort["refuge"]["head_open"] is True and fort["refuge"]["head_state"] == "ok"
    for tpl in ("hospital", "tombs", "farms", "stockroom", "cistern", "refuge_drink"):
        errs, _ = check(save, [{"tpl": tpl, "site": "S1"}], st, fort)
        assert errs == [], (tpl, errs)
    errs, _ = check(save, [HOSPITAL, TOMBS, DINING], st, fort)       # one other build: the seal is demanded first (d)
    assert len(errs) == 1 and "without a hatch" in errs[0] and "dining" in errs[0], errs


def test_a_real_exposed_refuge_is_still_demanded_first(save):
    manifest(save)
    snapshot(save, {(77, 68, 124): "<", (77, 68, 125): "X", (77, 68, 126): "X", (77, 68, 127): ">"})
    st, fort = facts(save)
    errs, _ = check(save, [DINING], st, fort)
    assert len(errs) == 1 and "the civilians' stair enters Tiefe+ below 77,68,125 without a hatch" in errs[0]
    assert '{"tpl":"seal","site":"S1","p":{"at":"refuge"}}' in errs[0]
    seal = {"tpl": "seal", "site": "S1", "p": {"at": "refuge"}}
    assert check(save, [seal, DINING], st, fort)[0] == []
    assert check(save, [DINING], st, fort, later=[seal])[0] != [], "a seal in a later season than the other new build"
    assert cmd.seal_openings(save, "refuge")[0] == "77,68,125 stair_updown"


def test_an_unrevealed_seal_tile_gets_a_clear_message(save):
    from dfpilot.bp import sites
    snap = snapshot(save, {(77, 68, 124): "<"})
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "seal", {"at": "77,68,125 stair_updown"})
    msg = str(e.value)
    assert "tile 77,68,125 is not revealed" in msg, msg
    assert "snapshot g1" in msg and "bp sites seal --fresh" in msg and "look at the tile in the game" in msg, msg
    assert "never reveal" in msg, msg
