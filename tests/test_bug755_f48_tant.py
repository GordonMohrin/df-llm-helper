"""Round 48 (tantrums and squads; offline, live-untested): BUG-755 (more patients than beds: `hospital furnish=2` is one bed inside the
hospital room that stands, and plan propose drafts it for the audit's `no_bed` gap). The Lua parts have their own tests
(tests/lua/test_bug754_repair_prio.lua, test_bug756_doctors.lua, test_bug757_recall.lua, test_bug511_pullers.lua, test_perimeter_keeper.lua,
test_bug755_hospital_bed_ask.lua)."""
from __future__ import annotations

import pytest

from dfpilot import bp, plan
from dfpilot.bp import rooms

from tests.test_bug581_585_f37_econ import Z, _draft, _man, _snap


def test_furnish_2_is_one_bed_inside_a_hospital_room():
    assert rooms.PARAMS["hospital"]["furnish"] == (0, 0, 2)
    found = bp.rank(_snap(), "hospital", {"furnish": 2}, manifest=_man(), n=3)
    assert found, "old code: furnish=2 was out of range"
    x, y, z = found[0]["anchor"]
    assert 95 <= x <= 101 and 101 <= y <= 105 and z == Z
    assert "a bed inside the hospital room" in found[0]["why"]
    doc = bp.emit("hospital", {"furnish": 2}, dict(found[0], id="S1"))
    assert [st["mode"] for st in doc["stages"]] == ["build"]
    assert [c[3] for ch in doc["stages"][0]["chunks"] for c in ch["cells"]] == ["b"]
    assert doc["materials"] == {"bed": 1}, doc["materials"]
    assert bp.validate(dict(doc, id="y1s0b4")) == []
    one = bp.emit("hospital", {"furnish": 1}, dict(found[0], id="S1"))          # furnish=1 stays the table
    assert [c[3] for ch in one["stages"][0]["chunks"] for c in ch["cells"]] == ["t"]


@pytest.fixture
def bed_state(monkeypatch):
    box = {"s": {"water": {"gaps": ["no_bed"]}}, "man": _man(), "files": [], "done": set()}
    monkeypatch.setattr(plan.files, "read_state", lambda sd: box["s"])
    monkeypatch.setattr(plan._cmd, "fort_manifest", lambda sd: box["man"])
    monkeypatch.setattr(plan, "bp_files", lambda sd: box["files"])
    monkeypatch.setattr(plan, "done_projects", lambda sd: box["done"])
    return box


def test_propose_drafts_beds_for_the_no_bed_gap_up_to_the_open_limit(bed_state, tmp_path):
    doc = _draft()
    notes = plan.hospital_table(tmp_path, doc, None, {})
    beds = [b for b in doc["seasons"][0]["build"]]
    assert beds == [{"tpl": "hospital", "site": "S1", "p": {"furnish": 2}}] * plan.HOSPITAL_BED_OPEN
    assert any("BUG-755" in n and "no_bed" in n for n in notes)
    again = _draft(beds)                                           # the draft already holds them: nothing more
    plan.hospital_table(tmp_path, again, None, {})
    assert len(again["seasons"][0]["build"]) == plan.HOSPITAL_BED_OPEN
    bed_state["man"] = {"v": 2, "rooms": []}                       # no hospital room stands: nothing to furnish
    none = _draft()
    plan.hospital_table(tmp_path, none, None, {})
    assert none["seasons"][0]["build"] == []


def test_a_bed_project_does_not_count_as_the_table_and_the_table_is_still_drafted(bed_state, tmp_path, monkeypatch):
    bed_state["s"] = {"water": {"gaps": ["no_table", "no_bed"]}}
    doc = _draft([{"tpl": "hospital", "site": "S1", "p": {"furnish": 2}}])
    plan.hospital_table(tmp_path, doc, None, {})
    ps = [b["p"]["furnish"] for b in doc["seasons"][0]["build"]]
    assert ps.count(1) == 1, "old code: a furnish=2 build counted as the table"
    assert ps.count(2) >= 1
