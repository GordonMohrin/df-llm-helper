"""Run 16 (04.11.2026, fix round 19).
BUG-368: no trade depot without a fortcore (i2 Ostgate: NO_DEPOT / DEPOT_MISSING every year, no caravan traded, no metal or
leather): the `depot` template (5x5, open surface floor on the citizens' walk group, nothing dug) and plan propose drafting it.
BUG-369: `bp sites` without --fresh ranked on a snapshot that predated the dug core (0 sites, no workshops in the year plan,
'0 free sites' for a bp.place): a stale or empty ranking asks for a new snapshot by itself.
BUG-370: plan propose drafted explore/bedrooms in a walk group the citizens cannot reach and gallery_o1 with an open tunnel wall;
the draft's own check said ERROR: builds whose placement fails on their site are left out."""
from __future__ import annotations

import copy
import json
import os
import time
from pathlib import Path

import pytest
from cli_v2_helpers import FakeKern, append_events, ev, install_fake_bp, make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema
from dfpilot.cli import main

X0, Y0, Z = 100, 100, 130
W, H = 40, 30
SNAP_TICK = 9_000_000


def _snap(far=(), sid="s368") -> dict:
    rows = [["." for _ in range(W)] for _ in range(H)]
    snap = {"v": 2, "id": sid, "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["".join(r) for r in rows],
                     f"z{Z + 1}": ["_" * W for _ in range(H)]}, "marks": {}}
    if far:
        wg = [list("1" * W) for _ in range(H)]
        for x, y in far:
            wg[y - Y0][x - X0] = "0"
        snap["wg"] = {"home": 7, "rows": {f"z{Z}": ["".join(r) for r in wg]}}
    return snap


# ---------------------------------------------------------------- BUG-368: the depot template and its sites
def test_depot_template_is_a_5x5_surface_build_that_digs_nothing():
    doc = bp.emit("depot", {}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert [st["mode"] for st in doc["stages"]] == ["build"] and doc["class"] == "infra"
    assert [c[3] for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]] == ["D(5x5)"]
    assert doc["manifest"]["depot"] == [112, 112, Z] and doc["materials"] == {"trade_depot": 1}
    assert "zones" not in doc["manifest"] and not doc["manifest"].get("rooms")
    assert schema.validate("bp", dict(doc, id="y1s0b3")) == [] and bp.validate(dict(doc, id="y1s0b3")) == []
    rot = bp.emit("depot", {}, {"id": "S1", "anchor": [110, 110, Z], "rot": 1})
    assert rot["manifest"]["depot"] != doc["manifest"]["depot"]
    assert "depot" in [t["tpl"] for t in bp.list_templates()]


def test_depot_sites_need_no_fortcore_and_keep_to_the_walk_group():
    snap = _snap()
    found = bp.rank(snap, "depot", {}, n=3)                      # no manifest: a room template would raise
    assert found and "5x5 open surface floor for a trade depot" in found[0]["why"]
    near = bp.rank(snap, "depot", {}, n=1, near=[136, 125, Z], within=10)[0]
    assert near["anchor"][0] > X0 + 25
    far = [(x, y) for x in range(X0, X0 + 20) for y in range(Y0, Y0 + H)]
    only = bp.rank(_snap(far=far), "depot", {}, n=5)
    assert only and all(s["anchor"][0] >= X0 + 18 and s["walk"] == 7 for s in only), [s["anchor"] for s in only]
    everywhere = [(x, y) for x in range(X0, X0 + W) for y in range(Y0, Y0 + H)]
    assert bp.rank(_snap(far=everywhere), "depot", {}, n=3) == []                    # nothing the citizens reach
    assert "5x5 block of open surface floor" in cmd.no_site_hint(Path("."), "depot", "s1", 0, [], {})


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = _snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    yield d
    reset_paths()


def test_a_depot_project_is_placed_without_any_fortcore_and_feeds_the_manifest(save):
    doc = cmd.emit_bp(save, "depot", {}, "S1", "c1a1a6b000000000aa", write=True, snap=_snap())
    assert doc["tpl"] == "depot" and doc["manifest"]["depot"][2] == Z
    assert cmd.fort_manifest(save)["depot"] == doc["manifest"]["depot"]       # the keeper's centre after a siege
    assert plan.depot_planned(save, files.read_state(save)) is True


def _p0_state(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P0"
    s["proj"] = []
    return s


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_propose_drafts_a_depot_for_a_fort_without_one_and_not_beside_a_fortcore_stage_one(save):
    s = _p0_state(save)
    full = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": False}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)}, fort=full)
    deps = [b for b in _builds(doc) if b["tpl"] == "depot"]
    assert deps == [{"tpl": "depot", "site": "S1"}] and "BUG-368" in doc["notes"]
    assert schema.validate("plan", doc) == [] and plan.build_kind(deps[0]) == "depot"
    assert "depot" in plan.REBUILD_KINDS                                      # the rebuild after a siege runs it
    have = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)}, fort={**full, "depot": True})
    assert all(b["tpl"] != "depot" for b in _builds(have))
    # year 1: the fortcore stage 1 of the draft builds the depot in its bailey
    y1 = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(),
                      fort={"z4": False, "core_any": False, "core_dig": False, "startup": False, "depot": False})
    assert any(b["tpl"] == "fortcore" for b in _builds(y1)) and all(b["tpl"] != "depot" for b in _builds(y1))


def test_depot_planned_counts_the_kernel_manifest(save):
    assert plan.depot_planned(save, files.read_state(save)) is False
    (save / "manifest.json").write_text(json.dumps({"v": 2, "depot": [1, 2, 3]}), "utf-8")
    assert plan.depot_planned(save, files.read_state(save)) is True


# ---------------------------------------------------------------- BUG-369: a stale ranking asks for a new snapshot
def _new_snap_reply(save):
    def reply(doc):
        snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
        snap["id"] = doc["id"]
        snap["tick"] = SNAP_TICK + 500000
        files.write_json_atomic(save / "snap" / f"{doc['id']}.json", snap)
        return True, "exporting", {"id": doc["id"]}
    return reply


@pytest.fixture
def rt(tmp_path, monkeypatch):
    monkeypatch.setattr(cmd, "AUTO_SNAP", True)                # tests/conftest.py switches it off for every other test
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = json.loads((d / "snap" / "c201.json").read_text("utf-8"))
    snap["tick"] = SNAP_TICK                                  # newer than every event of the fixture
    files.write_json_atomic(d / "snap" / "c201.json", snap)
    yield d
    reset_paths()


def run(save, *argv):
    return main(["--runtime", str(save.parent), *argv])


def test_snapshot_stale_names_a_stage_finished_after_the_snapshot(rt):
    snap = files.read_snapshot(rt / "snap" / "c201.json")
    assert snap["tick"] == SNAP_TICK and cmd.snapshot_stale(rt, snap) is None
    append_events(rt, [ev(99001, "PROJECT_STAGE", d={"proj": "y3s1b0", "stage": "s1.dig", "pct": 90}, tick=SNAP_TICK + 100000)])
    why = cmd.snapshot_stale(rt, snap)
    assert why and "PROJECT_STAGE y3s1b0 s1.dig" in why and "c201" in why
    assert cmd.snapshot_stale(rt, dict(snap, purpose="audit")).startswith("snapshot c201 is a audit export")
    assert cmd.snapshot_stale(rt, None) == "no snapshot"


def test_bp_sites_without_fresh_refreshes_a_snapshot_that_predates_a_finished_stage(rt, monkeypatch, capsys):
    install_fake_bp(monkeypatch)
    append_events(rt, [ev(99001, "PROJECT_DONE", d={"proj": "y3s1b0", "tpl": "fortcore"}, tick=SNAP_TICK + 100000)])
    with FakeKern(rt, _new_snap_reply(rt)) as k:
        assert run(rt, "bp", "sites", "tombs", "--timeout", "5") == 0
    out = capsys.readouterr().out
    assert [d["verb"] for d in k.seen] == ["snapshot"] and k.seen[0]["args"] == {"purpose": "sites"}
    assert "snapshot refreshed (PROJECT_DONE y3s1b0" in out and f"on snapshot {k.seen[0]['id']}" in out, out


def test_bp_sites_without_fresh_leaves_a_current_snapshot_alone(rt, monkeypatch, capsys):
    install_fake_bp(monkeypatch)
    with FakeKern(rt, _new_snap_reply(rt)) as k:
        assert run(rt, "bp", "sites", "tombs") == 0
    assert k.seen == [] and "on snapshot c201" in capsys.readouterr().out


def test_bp_sites_asks_again_when_nothing_ranks_on_the_cached_snapshot(rt, monkeypatch, capsys):
    def ranker(snap, tpl, params, n):
        return [] if snap["id"] == "c201" else [{"id": "S1", "anchor": [45, 35, 120], "rot": 0, "score": 9, "why": "dug"}]
    install_fake_bp(monkeypatch, sites=ranker)
    with FakeKern(rt, _new_snap_reply(rt)) as k:
        assert run(rt, "bp", "sites", "workshops", "--timeout", "5") == 0
    out = capsys.readouterr().out
    assert [d["verb"] for d in k.seen] == ["snapshot"]
    assert "snapshot refreshed (nothing ranked on the cached snapshot)" in out and "S1 anchor [45, 35, 120]" in out, out


def test_a_silent_kernel_gets_no_request_and_the_old_snapshot_is_ranked(rt, monkeypatch, capsys):
    install_fake_bp(monkeypatch)
    append_events(rt, [ev(99001, "PROJECT_STAGE", d={"proj": "y3s1b0", "stage": "s1.dig", "pct": 90}, tick=SNAP_TICK + 100000)])
    old = time.time() - 3600
    os.utime(rt / "heartbeat", (old, old))
    assert run(rt, "bp", "sites", "tombs") == 0
    out = capsys.readouterr().out
    assert "the kernel does not beat, not refreshed" in out and "on snapshot c201" in out
    assert not (rt / "inbox").exists() or not list((rt / "inbox").glob("*.json"))


def test_bp_place_with_no_free_site_on_an_old_snapshot_refreshes_once_and_places(rt, monkeypatch, capsys):
    def ranker(snap, tpl, params, n):
        return [] if snap["id"] == "c201" else [{"id": "S1", "anchor": [45, 35, 120], "rot": 0, "score": 9, "why": "dug"}]
    install_fake_bp(monkeypatch, sites=ranker)
    append_events(rt, [ev(99001, "PROJECT_STAGE", d={"proj": "y3s1b0", "stage": "s1.dig", "pct": 90}, tick=SNAP_TICK + 100000)])
    with FakeKern(rt, _new_snap_reply(rt)) as k:
        code = run(rt, "cmd", "bp.place", "tpl=workshops", "site=S1", "--wait", "2")
    out = capsys.readouterr().out
    assert [d["verb"] for d in k.seen] == ["snapshot", "bp.place"], (k.seen, out)
    assert "snapshot refreshed (PROJECT_STAGE y3s1b0" in out and code == 0, out


# ---------------------------------------------------------------- BUG-370: propose leaves out what cannot be placed
def _plan_doc(save, builds):
    s = _p0_state(save)
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied={("fortcore", 1)},
                       fort={"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True})
    for se in doc["seasons"]:
        se["build"] = []
    doc["seasons"][0]["build"] = builds
    return doc


def test_fit_placeable_drops_builds_whose_site_is_out_of_reach_or_does_not_fit(save, monkeypatch):
    real = plan.place

    def fake(save_dir, tpl, params, label, bid, **kw):
        if tpl == "explore":
            raise cmd.BpError("explore: all 138 candidate site(s) lie in a walk group the citizens cannot reach (they stand "
                              "in walk group 6102, e.g. the far side of a brook or a cave); open a way there")
        if tpl == "gallery_o1":
            raise cmd.BpError("gallery_o1: the tunnel's east wall is open at 80,74,137")
        return real(save_dir, tpl, params, label, bid, **kw)
    monkeypatch.setattr(plan, "place", fake)
    builds = [{"tpl": "explore", "site": "S1"}, {"tpl": "gallery_o1", "site": "S1"},
              {"tpl": "workshops", "site": "S1", "p": {"surface": 1}}, {"tpl": "depot", "site": "S1"}]
    doc = _plan_doc(save, copy.deepcopy(builds))
    lines = plan.fit_placeable(save, doc, None)
    assert [b["tpl"] for b in _builds(doc)] == ["workshops", "depot"]
    assert len(lines) == 2 and "explore@S1 left out" in lines[0] and "walk group the citizens cannot reach" in lines[0]
    assert "gallery_o1@S1 left out" in lines[1] and "east wall is open" in lines[1]
    assert "BUG-370" in doc["notes"] and schema.validate("plan", doc) == []
    again = plan.fit_placeable(save, doc, None)
    assert again == [] and [b["tpl"] for b in _builds(doc)] == ["workshops", "depot"]       # stable


def test_fit_placeable_never_judges_fortcore_seal_or_traps_nor_a_same_build_without_its_base(save, monkeypatch):
    def fake(save_dir, tpl, params, label, bid, **kw):
        raise cmd.BpError(f"{tpl}: only 0 free site(s)")
    monkeypatch.setattr(plan, "place", fake)
    builds = [{"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}, {"tpl": "seal", "site": "S1", "p": {"at": "last"}},
              {"tpl": "gallery_o1", "site": "same"}]
    doc = _plan_doc(save, builds)
    assert plan.fit_placeable(save, doc, None) == []
    assert [b["tpl"] for b in _builds(doc)] == ["fortcore", "seal", "gallery_o1"]


def test_the_checked_draft_has_no_walk_group_error_after_the_fit(save, monkeypatch):
    real = plan.place

    def fake(save_dir, tpl, params, label, bid, **kw):
        if tpl == "explore":
            raise cmd.BpError("explore: all 9 candidate site(s) lie in a walk group the citizens cannot reach")
        return real(save_dir, tpl, params, label, bid, **kw)
    monkeypatch.setattr(plan, "place", fake)
    fort = {"z4": True, "core_any": True, "core_dig": False, "startup": True, "depot": True}
    doc = _plan_doc(save, [{"tpl": "explore", "site": "S1"}])
    errs, warn = plan.check(doc, _p0_state(save), tpls=plan.templates(), prev=None, fort=fort)
    plan._dry_place(save, doc, None, errs, warn)
    assert any("walk group" in e for e in errs), errs                     # before: the check's placement dry run says ERROR
    doc = _plan_doc(save, [{"tpl": "explore", "site": "S1"}])
    plan.fit_placeable(save, doc, None)
    errs, warn = plan.check(doc, _p0_state(save), tpls=plan.templates(), prev=None, fort=fort)
    plan._dry_place(save, doc, None, errs, warn)
    assert not any("walk group" in e for e in errs), errs
