"""Round 37 (economy blockers; offline, live-untested): BUG-581 (the hospital without a traction bench, a table in the hospital room),
BUG-582 (trade goods for a caravan), BUG-583 (flux in trade.want, the link_stale question), BUG-584 (explore farther from the earlier probes,
rock types per finished probe), BUG-585 (the manager's office with its furniture, the warning after 5 days), BUG-586 (no stone traps, no
traction bench without usable stone). The Lua parts have their own tests (tests/lua/test_bug581_hospital_bench.lua,
test_bug582_trade_goods.lua, test_bug583_flux_link_stale.lua, test_bug584_probe_rocks.lua, test_zone_place.lua, test_economy_drink.lua)."""
from __future__ import annotations

import pytest

from dfpilot import bp, plan, schema
from dfpilot.bp import rooms, sites

X0, Y0, Z = 90, 100, 134
W, H = 30, 30


def _snap(blocked=(), room=(95, 101, 101, 105)) -> dict:
    """30x30 open floor at z134 with a walled box `room` (x0, y0, x1, y1) of floor inside; rock above and below."""
    rows = [["#" for _ in range(W)] for _ in range(H)]
    for y in range(room[1], room[3] + 1):
        for x in range(room[0], room[2] + 1):
            rows[y - Y0][x - X0] = "."
    for x, y in blocked:
        rows[y - Y0][x - X0] = "#"
    rock = ["#" * W for _ in range(H)]
    return {"v": 2, "id": "s581", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": rock, f"z{Z}": ["".join(r) for r in rows], f"z{Z + 1}": rock}, "marks": {}}


def _man(**kw) -> dict:
    return {"v": 2, "rooms": [{"id": "hosp1", "tpl": "hospital", "use": "utility", "bbox": [95, 101, Z, 101, 105, Z], "tier": 0}], **kw}


# ---------------------------------------------------------------- BUG-581
def test_hospital_without_a_bench_has_no_traction_bench_and_keeps_the_rest():
    full = bp.emit("hospital", {}, {"id": "S1", "anchor": [95, 100, Z], "rot": 0})
    lean = bp.emit("hospital", {"bench": 0}, {"id": "S1", "anchor": [95, 100, Z], "rot": 0})

    def keys(d):
        return sorted(c[3] for st in d["stages"] if st["mode"] == "build" for ch in st["chunks"] for c in ch["cells"])
    assert "R" in keys(full) and "R" not in keys(lean)
    assert [k for k in keys(full) if k != "R"] == keys(lean), "only the bench is left out"
    assert "traction_bench" in full["materials"] and "traction_bench" not in lean["materials"]
    surface = bp.emit("hospital", {"surface": 1, "bench": 0}, {"id": "S1", "anchor": [95, 100, Z], "rot": 0})
    assert "R" not in keys(surface) and "t" in keys(surface)


def test_furnish_is_one_table_inside_a_hospital_room():
    found = bp.rank(_snap(), "hospital", {"furnish": 1}, manifest=_man(), n=3)
    assert found, "old code: 'room sites need the fort manifest with zones.Z4'"
    x, y, z = found[0]["anchor"]
    assert 95 <= x <= 101 and 101 <= y <= 105 and z == Z
    assert found[0]["score"] >= 200, "a corner of the room (two wall sides) first: " + str(found[0])
    doc = bp.emit("hospital", {"furnish": 1}, dict(found[0], id="S1"))
    assert [st["mode"] for st in doc["stages"]] == ["build"]
    assert [c[3] for ch in doc["stages"][0]["chunks"] for c in ch["cells"]] == ["t"]
    assert doc["materials"] == {"table": 1}, doc["materials"]
    assert bp.validate(dict(doc, id="y1s0b3")) == []


def test_furnish_says_why_when_it_cannot():
    with pytest.raises(ValueError, match="no hospital room"):
        bp.rank(_snap(), "hospital", {"furnish": 1}, manifest={"v": 2, "rooms": []}, n=3)
    walled = _snap(room=(110, 110, 111, 111))                        # the room's tiles are all rock
    with pytest.raises(ValueError, match="no open floor tile"):
        bp.rank(walled, "hospital", {"furnish": 1}, manifest=_man(), n=3)


def _draft(builds=()):
    return {"year": 3, "notes": "", "seasons": [{"build": [dict(b) for b in builds]}, {"build": []}, {"build": []}, {"build": []}]}


@pytest.fixture
def hospital_state(monkeypatch, tmp_path):
    box = {"s": {"water": {"gaps": ["no_table", "no_diag", "no_plaster", "no_soap"]}}, "man": _man()}
    monkeypatch.setattr(plan.files, "read_state", lambda sd: box["s"])
    monkeypatch.setattr(plan._cmd, "fort_manifest", lambda sd: box["man"])
    monkeypatch.setattr(plan, "bp_files", lambda sd: [])
    monkeypatch.setattr(plan, "done_projects", lambda sd: set())
    return box


def test_propose_drafts_the_table_and_reports_the_gaps_it_cannot_build(hospital_state, tmp_path):
    doc = _draft()
    notes = plan.hospital_table(tmp_path, doc, None, {})
    assert doc["seasons"][0]["build"] == [{"tpl": "hospital", "site": "S1", "p": {"furnish": 1}}]
    joined = " | ".join(notes)
    assert "no_table" in joined and "no_diag" in joined and "no_plaster" in joined and "no_soap" in joined and "BUG-581" in doc["notes"]
    # once: a furnish build in the draft, or a hospital build of its own (it has a table), is not drafted over
    again = _draft([{"tpl": "hospital", "site": "S1", "p": {"furnish": 1}}])
    plan.hospital_table(tmp_path, again, None, {})
    assert len(again["seasons"][0]["build"]) == 1
    own = _draft([{"tpl": "hospital", "site": "S1"}])
    plan.hospital_table(tmp_path, own, None, {})
    assert len(own["seasons"][0]["build"]) == 1
    hospital_state["man"] = {"v": 2, "rooms": []}                 # no hospital room stands: nothing to furnish
    none = _draft()
    plan.hospital_table(tmp_path, none, None, {})
    assert none["seasons"][0]["build"] == []


def test_a_new_hospital_build_leaves_the_bench_out_without_stone(hospital_state, tmp_path):
    hospital_state["s"] = {}
    doc = _draft([{"tpl": "hospital", "site": "S1", "p": {"beds": 6}}])
    notes = plan.hospital_table(tmp_path, doc, None, {"nostone": "the stone digs found only soil (no hard stone yet)"})
    assert doc["seasons"][0]["build"][0]["p"] == {"beds": 6, "bench": 0} and notes and "mechanism" in notes[0]
    keep = _draft([{"tpl": "hospital", "site": "S1", "p": {"beds": 6}}])
    plan.hospital_table(tmp_path, keep, None, {"nostone": ""})
    assert keep["seasons"][0]["build"][0]["p"] == {"beds": 6}


# ---------------------------------------------------------------- BUG-584
def test_fort_manifest_lists_the_anchors_of_earlier_explore_projects(tmp_path):
    from dfpilot import cmd, files
    bpd = tmp_path / "bp"
    bpd.mkdir()
    files.write_json_atomic(bpd / "y1s0b0.json", {"tpl": "explore", "anchor": [10, 20, 30]})
    files.write_json_atomic(bpd / "y1s0b1.json", {"tpl": "bedrooms", "anchor": [1, 2, 3]})
    m = cmd._with_explored(tmp_path, {"v": 2})
    assert m["explored"] == [[10, 20, 30]]
    assert "explored" not in cmd._with_explored(tmp_path / "none", {"v": 2})


# ---------------------------------------------------------------- BUG-586 (and the stone reason of BUG-581)
def test_no_traps_while_stone_is_out_of_reach_and_df_refuses_the_rock_jobs():
    assert plan.nostone_reason({"stock": {"rhard": 1}}, None), "DF refuses the rock jobs: stone is out of reach"
    assert plan.nostone_reason({"stock": {}}, None) == ""
    doc = _draft([{"tpl": "traps", "site": "S1"}, {"tpl": "bedrooms", "site": "S1"}])
    note = plan.drop_impossible(doc, None, {"nostone": "DF cancels the rock jobs"})
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["bedrooms"] and "traps" in note and "BUG-500" in note
    kept = _draft([{"tpl": "traps", "site": "S1"}])
    assert plan.drop_impossible(kept, None, {"nostone": ""}) == "" and len(kept["seasons"][0]["build"]) == 1
    warn = plan.stone_gate(_draft([{"tpl": "traps", "site": "S1"}]), None, {"nostone": "x"})
    assert warn and "traps" in warn[0]


def test_the_state_key_stock_rhard_is_in_the_schema():
    assert "stock.rhard" in schema.STATE_OWNERS and schema.STATE_OWNERS["stock.rhard"] == "economy"
