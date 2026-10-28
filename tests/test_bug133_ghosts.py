"""BUG-133 (Run 14 region2-site90, y502-y716: ghosts 0 -> 49, no memorial slab ever placed): the Python side.

follow places the mason's workshop economy asks for (PROJECT_REQUEST workshops why=slabs types [Masons]) the way it places
the mandatory shops of a reclaimed fort; the lint lets act.slab_place ask the walk groups (the slab list of Build >
Furniture > Slab greys out a slab nobody can walk to); the contracts name the new act and the GHOSTS fields; the new
care knobs are range-checked. Every test fails on dec5132."""
import json

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import cmd, fairplay, files, schema
from dfpilot import lint as L


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    for p in cmd.bp_files(d):
        p.unlink()
    yield d
    reset_paths()


def test_follow_places_the_masons_economy_asks_for_the_ghosts(save, monkeypatch):
    from test_cli_wake import F, Clock
    calls = install_fake_bp(monkeypatch)
    from dfpilot.bp.rooms import MOODABLE_TYPES
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(9101, "PROJECT_REQUEST", "workshops: no mason's workshop for the memorial slabs of 41 ghost(s)",
                            {"tpl": "workshops", "n": 1, "why": "slabs", "types": ["Masons"]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    assert f.jobs["slabs"]["params"] == {"skip": ",".join(t for t in MOODABLE_TYPES if t != "Masons")}
    assert f.jobs["slabs"]["need"] == ["Masons"]
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(9102, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert [ln for ln in out if "AUTO_FAIL" in ln] == []
    assert calls["emit"]


def _rules(src: str, name: str) -> set:
    return {f["rule"] for f in L.lua_source(src, name)}


def test_slab_place_may_ask_the_walk_groups_nothing_else_may():
    src = "function I.slab_place(id, x, y, z) return dfhack.maps.canWalkBetween(xyz2pos(x, y, z), xyz2pos(x, y, z)) end"
    assert "tile-read" not in _rules(src, "lua/dfllm/act.lua")
    assert "tile-read" in _rules(src, "lua/dfllm/care.lua")
    other = "function I.pull(id, x, y, z) return dfhack.maps.canWalkBetween(xyz2pos(x, y, z), xyz2pos(x, y, z)) end"
    assert "tile-read" in _rules(other, "lua/dfllm/act.lua")


def test_contracts_name_the_slab_act_and_the_ghost_fields():
    assert schema.ACT["slab_place"] == ["care"]
    _, by, spec = schema.EVENTS["GHOSTS"]
    assert by == "care" and {"slabs", "mem"} <= set(spec.opt)
    assert schema.validate_event_d("GHOSTS", {"ghosts": 2, "slabs": ["loose", "placed"], "mem": "1 loose, 1 placed"}) == []
    assert schema.validate_event_d("GHOSTS", {"ghosts": 2, "slabs": "loose"}) != []


def test_the_new_care_knobs_are_checked(tmp_path):
    base = json.loads((fairplay.REPO / "config" / "baseline.json").read_text("utf-8"))
    assert base["care"]["tomb_assign_per_run"] == 20 and base["care"]["memorials"] == 2
    assert base["economy"]["slabs"]["restock_cap"] == 20
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"care": {"tomb_assign_per_run": -1, "memorials": 500}}), encoding="utf-8")
    errs = fairplay.care_errors(p)
    assert len(errs) == 2 and "tomb_assign_per_run" in errs[0] and "memorials" in errs[1]
