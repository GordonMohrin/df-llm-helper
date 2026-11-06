"""Round 35 (care, mood, trade; offline, live-untested): BUG-559 (care burrow in BREACH, patient_out decision), BUG-560 (mood
items), BUG-561 (trade bins), BUG-562 (workshops gone from the manifest are built again at their old place). The Lua parts have
their own tests (tests/lua/test_bug559_care_breach.lua, test_bug560_mood_unforbid.lua, test_trade.lua / test_trade_act.lua)."""
from __future__ import annotations

import pytest

from dfpilot import bp, fairplay, plan, schema, wake
from dfpilot.bp import rooms, sites

X0, Y0, Z = 90, 100, 134
W, H = 30, 30


def _snap(blocked=()) -> dict:
    """30x30 open floor at z134 (a dug workshop hall), rock above and below; `blocked` tiles are walls."""
    rows = [["." for _ in range(W)] for _ in range(H)]
    for x, y in blocked:
        rows[y - Y0][x - X0] = "#"
    rock = ["#" * W for _ in range(H)]
    return {"v": 2, "id": "s562", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": rock, f"z{Z}": ["".join(r) for r in rows], f"z{Z + 1}": rock}, "marks": {}}


GONE = [{"type": "Craftsdwarfs", "pos": [99, 119, Z], "w": 5}, {"type": "Clothiers", "pos": [107, 116, Z], "w": 6}]


def _man(**kw) -> dict:
    return {"v": 2, "workshops": [{"type": "Masons", "pos": [95, 105, Z]}], "gone": GONE, **kw}


# ---------------------------------------------------------------- BUG-562
def test_a_gone_shop_is_ranked_at_its_old_place_and_built_there():
    found = bp.rank(_snap(), "workshops", {"skip": ",".join(n for n in rooms.MOODABLE_TYPES if n != "Craftsdwarfs"),
                                           "rebuild": 1}, manifest=_man(), n=3)
    assert [s["anchor"] for s in found] == [[99, 119, Z]], found          # old code: 'zones.Z4' / no room site at all
    assert "where it stood" in found[0]["why"]
    doc = bp.emit("workshops", {"skip": ",".join(n for n in rooms.MOODABLE_TYPES if n != "Craftsdwarfs"), "rebuild": 1},
                  dict(found[0], id="S1"))
    assert [st["mode"] for st in doc["stages"]] == ["build"]
    assert doc["manifest"]["workshops"] == [{"type": "Craftsdwarfs", "pos": [99, 119, Z]}], doc["manifest"]
    cells = [(c["pos"], c["cells"]) for ch in [doc["stages"][0]] for c in ch["chunks"]]
    assert cells and cells[0][0] == [98, 118, Z], cells                    # the 3x3 starts at the NW corner of the old footprint
    assert bp.validate(dict(doc, id="y1s0b2")) == []


def test_rebuild_refuses_what_cannot_stand_again_and_says_why():
    skip = ",".join(n for n in rooms.MOODABLE_TYPES if n != "Clothiers")
    with pytest.raises(ValueError, match="not all open floor"):
        bp.rank(_snap(blocked=[(107, 116)]), "workshops", {"skip": skip, "rebuild": 1}, manifest=_man(), n=3)
    with pytest.raises(ValueError, match="standing workshop"):
        bp.rank(_snap(), "workshops", {"skip": skip, "rebuild": 1},
                manifest=_man(workshops=[{"type": "Masons", "pos": [108, 117, Z]}]), n=3)
    with pytest.raises(ValueError, match="no Clothiers in manifest.gone"):
        bp.rank(_snap(), "workshops", {"skip": skip, "rebuild": 1}, manifest={"v": 2, "gone": []}, n=3)
    with pytest.raises(ValueError, match="exactly one shop type"):
        bp.emit("workshops", {"rebuild": 1}, {"id": "S1", "anchor": [99, 119, Z], "rot": 0})
    # a plain workshops ranking is unchanged: room sites need the fort's Z4
    with pytest.raises(ValueError, match="zones.Z4"):
        bp.rank(_snap(), "workshops", {}, manifest=_man(), n=3)


def test_propose_drafts_a_rebuild_for_each_gone_type_no_workshop_stands_for(monkeypatch, tmp_path):
    doc = {"year": 3, "notes": "", "seasons": [{"build": []}, {"build": []}, {"build": []}, {"build": []}]}
    monkeypatch.setattr(plan._cmd, "fort_manifest", lambda save_dir: _man())
    notes = plan.gone_shops(tmp_path, doc, None)
    assert [b["p"] for b in doc["seasons"][0]["build"]] == [{"only": "Craftsdwarfs", "rebuild": 1}, {"only": "Clothiers", "rebuild": 1}]
    assert notes and "BUG-562" in notes[0]
    # already in the draft (a workshops build makes it) or standing again: not drafted twice
    doc2 = {"year": 3, "notes": "", "seasons": [{"build": [{"tpl": "workshops", "site": "S1", "p": {"only": "Clothiers"}}]},
                                                {"build": []}, {"build": []}, {"build": []}]}
    plan.gone_shops(tmp_path, doc2, None)
    assert [b["p"] for b in doc2["seasons"][0]["build"] if b["p"].get("rebuild")] == [{"only": "Craftsdwarfs", "rebuild": 1}]
    monkeypatch.setattr(plan._cmd, "fort_manifest",
                        lambda save_dir: _man(workshops=[{"type": "Craftsdwarfs", "pos": [99, 119, Z]},
                                                         {"type": "Clothiers", "pos": [107, 116, Z]}]))
    doc3 = {"year": 3, "notes": "", "seasons": [{"build": []}, {"build": []}, {"build": []}, {"build": []}]}
    assert plan.gone_shops(tmp_path, doc3, None) == [] and doc3["seasons"][0]["build"] == []


# ---------------------------------------------------------------- BUG-559
def test_patient_out_is_urgent_and_the_care_breach_keys_are_checked(tmp_path):
    assert "patient_out" in wake.URGENT_DECISIONS
    p = tmp_path / "baseline.json"
    p.write_text('{"water": {"care_breach": false, "care_breach_near": 40}}', encoding="utf-8")
    assert fairplay.water_errors(p) == []
    p.write_text('{"water": {"care_breach_near": 0}}', encoding="utf-8")
    assert fairplay.water_errors(p) and "care_breach_near" in fairplay.water_errors(p)[0]
    lua = (schema.__file__ and open(schema.__file__.replace("dfpilot\\schema.py", "lua\\dfllm\\water.lua")
                                    .replace("dfpilot/schema.py", "lua/dfllm/water.lua"), encoding="utf-8").read())
    assert "care_breach = true, care_breach_near = 30" in lua
