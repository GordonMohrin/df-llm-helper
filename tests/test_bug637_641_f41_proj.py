"""Round 41 (stale projects and sites; offline, live-untested): BUG-637 a parked build_lost project is cancelled by the kernel (Lua:
tests/lua/test_bug637_lost_cancel.lua), BUG-638 a seal for solid rock is a phantom (Lua: tests/lua/test_bug638_phantom_seal.lua; here the plan
check side), BUG-639 the sites snapshot wait and the surface fallback for the room templates, BUG-640 `hospital furnish=1` is no new hospital
for plan check, BUG-641 a DECISION offers only the `bp sites ... surface=1` commands that can place something."""
from __future__ import annotations

import json
import re

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import cmd, fairplay, files, plan, schema, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    yield d
    reset_paths()


# ---------------------------------------------------------------- BUG-637
def test_the_autocancel_event_and_its_hint_are_known():
    d = {"proj": "y376s0b0", "tpl": "hospital", "stage": "build", "why": "build_lost", "ticks": 1, "autocancel": 61,
         "cmd": "dfllm cmd bp.place '{\"tpl\":\"hospital\",\"site\":\"S1\"}'"}
    assert schema.validate_event_d("PROJECT_BLOCKED", d) == []
    hint = wake.next_hint("PROJECT_BLOCKED", {"d": d})
    assert "place it again" in hint and "bp.place" in hint and "bp sites hospital --fresh" in hint
    seal = wake.next_hint("PROJECT_BLOCKED", {"d": {**d, "tpl": "seal", "cmd": None}})
    assert "next audit places a seal again" in seal


def test_lost_days_is_a_known_queue_key_with_a_range(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"runner": {"queue": {"lost_days": 90}}}))
    assert fairplay.runner_errors(p) == []
    p.write_text(json.dumps({"runner": {"queue": {"lost_days": 4000}}}))
    assert any("lost_days" in e for e in fairplay.runner_errors(p))


# ---------------------------------------------------------------- BUG-638
MAN = {"v": 2, "refuge": {"anchor": [67, 46, 138], "burrow": "Tiefe+"}, "stairs": {"civ": [[67, 44, 138, 141]]},
       "zones": {"Z4": [[60, 40, 136, 75, 50, 141]]}}


def test_a_phantom_hatch_tile_ends_the_refuge_demand(save):
    """Wallfree y374-y378: the manifest's stair head 67,44,139 was never dug; the kernel cancelled the seal (solid rock) and said so."""
    files.write_json_atomic(save / "manifest.json", MAN)
    for p in (save / "snap").glob("*.json"):
        p.unlink()
    assert cmd.refuge_stair(save)["state"] == "ok" and cmd.refuge_stair(save)["head"] == "67,44,139 stair_updown"
    tick = files.current_tick(save)
    n = files.last_event_n(save) + 1
    append_events(save, [ev(n, "PROJECT_BLOCKED", "y374s0b0 (seal) cancelled: 67,44,139 # is solid rock",
                            {"proj": "y374s0b0", "tpl": "seal", "stage": "seal.build", "why": "build_lost", "ticks": 5,
                             "phantom": ["67,44,139 #"]}, tick=tick)])
    rs = cmd.refuge_stair(save)
    assert (rs["state"], rs["head"], rs["man"]) == ("nostair", None, "67,44,139 stair_updown"), rs
    assert "no stair found (not dug)" in rs["note"]
    assert cmd.phantom_tiles(save) == {"67,44,139"}


def test_a_phantom_tile_that_became_a_stair_is_demanded_again(save):
    files.write_json_atomic(save / "manifest.json", MAN)
    tick = files.current_tick(save)
    append_events(save, [ev(files.last_event_n(save) + 1, "PROJECT_BLOCKED", "x", {"proj": "p", "phantom": ["67,44,139 #"]}, tick=tick)])
    bbox = [60, 40, 136, 75, 50, 141]
    x0, y0, z0, x1, y1, z1 = bbox
    tiles = {(67, 44, 139): "X", (67, 44, 138): "<"}
    rows = {f"z{z}": ["".join(tiles.get((x, y, z), "#") for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
            for z in range(z0, z1 + 1)}
    doc = {"v": 2, "id": "e2", "tick": tick, "purpose": "sites", "bbox": bbox, "rows": rows, "bridges": {}, "traps": []}
    files.write_json_atomic(save / "snap" / "e2.json", doc)
    rs = cmd.refuge_stair(save, doc)
    assert rs["state"] == "ok" and rs["head"] == "67,44,139 stair_updown", "a stair was dug there since: the hatch is demanded"


# ---------------------------------------------------------------- BUG-639
def test_a_job_waits_minutes_for_its_sites_snapshot(save, monkeypatch):
    assert wake.AUTO_SNAP_TIMEOUT_S >= 180 > wake.AUTO_TIMEOUT_S, "Valleyhame: the export was written 1 to 3 minutes after the request"
    fails = []
    f = wake.Follower(out=lambda s: None, clock=lambda: 0.0)
    f.dir = save
    monkeypatch.setattr(f, "_fail", lambda what, err, now: fails.append((what, str(err))))
    f.jobs["farms"] = {"snap": "c9", "since": 0.0, "tpl": "farms", "params": {}, "site": "S1"}
    f._run_jobs(90.0)                                  # 90 s: the export (168,480 tiles) is still running
    assert fails == [] and "farms" in f.jobs
    assert f._request_place("farms", "farms", {}, "S1", 120.0) is False, "no second snapshot request while the first one is out"
    f._run_jobs(301.0)
    assert len(fails) == 1 and fails[0][0] == "farms" and "no sites snapshot within 300s" in fails[0][1], fails
    assert "farms" not in f.jobs
    # a snapshot reply is waited for as long as the job
    f.jobs["replies"] = {"c10": {"verb": "snapshot", "what": "tombs snapshot", "since": 0.0, "tpl": None, "proj": None}}
    f._read_replies(100.0)
    assert "c10" in f.jobs["replies"] and len(fails) == 1


def test_fresh_wait_without_a_box_follows_the_last_export(save):
    assert cmd.fresh_wait(None, 60) == 60.0, "no save dir: as before"
    for p in (save / "snap").glob("*.json"):
        p.unlink()
    w = cmd.fresh_wait(None, 60, save)                 # no snapshot yet: the default box of a fort
    assert w == 30 + cmd.SNAP_DEFAULT_TILES / cmd.SNAP_TILES_PER_S and 60 < w <= cmd.SNAP_WAIT_MAX_S
    assert cmd.fresh_wait(None, 500, save) == 500.0, "the flag is a minimum"
    bbox = [0, 0, 100, 399, 399, 109]                  # the last export: 1,600,000 tiles
    rows = {f"z{z}": ["#" * 400 for _ in range(400)] for z in range(100, 110)}
    files.write_json_atomic(save / "snap" / "big.json", {"v": 2, "id": "big", "tick": 1, "purpose": "sites", "bbox": bbox,
                                                         "rows": rows, "bridges": {}, "traps": []})
    assert cmd.fresh_wait(None, 60, save) == cmd.SNAP_WAIT_MAX_S, "bounded"


# ---------------------------------------------------------------- BUG-639: the surface variant of a room without a core
X0, Y0, Z = 100, 100, 130
W, H = 70, 50


def _flat_snap(sid="s639") -> dict:
    """A flat surface of open floor with sky above, no dug level (the Valleyhame start)."""
    return {"v": 2, "id": sid, "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["." * W for _ in range(H)],
                     f"z{Z + 1}": ["_" * W for _ in range(H)]}, "marks": {}}


@pytest.fixture
def nocore(save, monkeypatch):
    snap = _flat_snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: {"v": 2})
    return save, snap


def test_bedrooms_without_a_core_floor_fall_back_to_the_surface_variant(nocore):
    save, snap = nocore
    assert cmd.no_core_floor(save) is True
    assert cmd.surface_alt(save, "bedrooms", {"n": 4}) == {"n": 4, "surface": 1}
    assert cmd.surface_alt(save, "tombs", {}) is None, "tombs have no surface variant"
    assert cmd.surface_alt(save, "bedrooms", {"surface": 1}) is None
    doc = cmd.place(save, "bedrooms", {"n": 4}, "S1", "y377s0b2", snap=snap)
    assert doc["params"].get("surface") == 1 and all(st["mode"] != "dig" for st in doc["stages"])
    assert "BUG-639" in cmd.PLACE_NOTES["y377s0b2"]


def test_a_room_with_a_core_floor_or_a_core_coming_keeps_the_error(nocore, monkeypatch):
    save, snap = nocore
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: {"v": 2, "zones": {"Z4": [[100, 100, 128, 120, 120, 131]]}})
    assert cmd.no_core_floor(save) is False and cmd.surface_alt(save, "bedrooms", {}) is None
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: {"v": 2})
    monkeypatch.setattr(cmd, "first_core", lambda _d, skip="": ("c1", [110, 110, Z]))
    assert cmd.no_core_floor(save) is False, "a fortcore project will dig the Z4 floor: the rooms wait for it"
    with pytest.raises(cmd.BpError):
        cmd.place(save, "bedrooms", {"n": 4}, "S1", "y377s0b3", snap={**snap, "rows": {k: ["#" * W for _ in range(H)] for k in snap["rows"]}})


def test_the_sites_hint_names_the_surface_variant_and_the_tombs_limit(nocore):
    save, _ = nocore
    h = cmd.no_site_hint(save, "bedrooms", "s639", 0, [], {})
    assert "surface variant" in h and "bedrooms surface=1 --fresh" in h and "bp.place fortcore first" not in h, h
    t = cmd.no_site_hint(save, "tombs", "s639", 0, [], {})
    assert "no surface variant" in t and "bp.place fortcore" in t, t


# ---------------------------------------------------------------- BUG-640: the hospital table is no new hospital
def _doc_with(builds):
    return {"phase_target": "P3", "year": 437, "seasons": [{"build": list(builds)}, {"build": []}, {"build": []}, {"build": []}]}


DRY = {"water": {"src": []}}                 # the kernel reports no accepted water: a NEW hospital would be refused


def test_hospital_furnish_is_not_refused_for_water_but_a_new_hospital_still_is():
    furn = {"tpl": "hospital", "site": "S1", "p": {"furnish": 1}}
    errs, _ = plan.hospital_gate(_doc_with([furn]), DRY, {}, None)
    assert errs == [], "old code: ERROR 'no accepted water ... its patients would die of thirst' for the table of a finished hospital"
    errs, _ = plan.hospital_gate(_doc_with([{"tpl": "hospital", "site": "S1"}]), DRY, {}, None)
    assert errs and "would die of thirst" in errs[0]
    both, _ = plan.hospital_gate(_doc_with([furn, {"tpl": "hospital", "site": "S1", "p": {"bench": 0}}]), DRY, {}, None)
    assert both and "seasons[0]" in both[0]


# ---------------------------------------------------------------- BUG-641: commands that can work
FARM = "dfllm cmd bp.place '{\"tpl\":\"farms\",\"site\":\"S1\",\"p\":{\"surface\":1}}'"
SITES = "dfllm bp sites farms surface=1 --near 94,51,146 --within 12 --fresh"


def test_the_thirst_decision_drops_the_farm_commands_when_no_farm_site_stands(monkeypatch, tmp_path):
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "none")
    water = "dfllm cmd inspect what=water_sources"
    d = {"id": "thirst", "q": "4 thirsty, drink 0 d", "cmds": [water, FARM, SITES]}
    cmds, dropped = wake.workable_food_cmds(d, tmp_path)
    assert FARM not in cmds and SITES not in cmds and water in cmds, "old code: thirst was not filtered, the dead farm command stayed"
    assert cmds[-1] == wake.TRADE_DRINK_CMD and dropped
    h = wake.next_hint("DECISION_NEEDED", {"d": d}, tmp_path)
    assert "bp.place" not in h.split("[not offered")[0] and "not offered: bp.place farms" in h, h
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "surface")
    assert wake.workable_food_cmds(d, tmp_path)[0][:3] == [water, FARM, SITES]
    only_farm = {"id": "thirst", "cmds": [FARM]}
    monkeypatch.setattr(plan, "farm_site", lambda save_dir, urgent=False: "none")
    assert wake.workable_food_cmds(only_farm, tmp_path)[0] == [wake.TRADE_DRINK_CMD]
    verb, _, raw = wake.TRADE_DRINK_CMD.removeprefix("dfllm cmd ").partition(" ")
    assert schema.validate_args(verb, json.loads(raw.strip("'"))) == []
    assert wake.workable_food_cmds({"id": "famine", "cmds": [FARM]}, tmp_path)[0] == [wake.TRADE_FOOD_CMD], "famine as before"
