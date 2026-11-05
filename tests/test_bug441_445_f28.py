"""BUG-441 .. BUG-445 (Run 16b i2 Roadvises, 16c i3 Castletongs, 05.11.2026; Gordon: forts UNDER the aquifer, the aquifer pierced level by
level by aqshaft as safely as possible, no surface fort).
BUG-441: follow's own fortcore stage 1 (queued 1 minute after adopt, before the aquifer was known) landed above and in the aquifer
and `bp sites aqshaft` said every site lay beside it. No automatic fortcore before the span is known (a probe shaft first), none
while an aquifer level is known (the core goes below the lowest one by `plan propose`), and a queued, not started core above or in
the aquifer is re-sited (cancelled).
BUG-442: a bp file the kernel does not know (bp/y372s0b0.json) blocked every new fortcore stage 1; it is retired (bp.cancel 'no
project', follow's sweep with `inspect persist key=bp.<id>`, plan apply).
BUG-443 / BUG-444 (Lua): tests/lua/test_bug443_444_ring_stall.lua. BUG-445: tests/lua/test_embark_bug445.lua + surfacecore refusal."""
from __future__ import annotations

import copy
import json
import os
import time

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema, wake
from test_bug412_413_aquifer_default import AQ, Z, _snap  # noqa: F401  (the aquifer world)

DAY = 1200
pytestmark = pytest.mark.orphans


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):                      # the runtime fixture's own projects: out of these tests' way
        old.unlink()
    (d / "events.1.jsonl").unlink(missing_ok=True)             # a complete event log (nothing rotated out): the rotated case is tested on its own
    box = {"snap": _snap(), "man": {"v": 2}}
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: box["snap"])
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: box["man"])
    monkeypatch.setattr(plan, "fort_manifest", lambda _d: box["man"])
    yield d, box
    reset_paths()


def _bp(save, pid, tpl, anchor=(110, 110, 130), params=None, age=None):
    (save / "bp").mkdir(exist_ok=True)
    p = save / "bp" / f"{pid}.json"
    p.write_text(json.dumps({"tpl": tpl, "anchor": list(anchor), "rot": 0, "params": params or {}, "id": pid}))
    if age is not None:
        t = time.time() - age
        os.utime(p, (t, t))
    return p


def _done(save, *pids):
    n = files.last_event_n(save) + 50
    append_events(save, [ev(n + i, "PROJECT_DONE", "", {"proj": pid}, tick=1) for i, pid in enumerate(pids)])


# ---------------------------------------------------------------- BUG-441: the span gate
def test_gate_refuses_while_an_aquifer_level_is_known_and_names_the_route(world):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    g = plan.core_span_gate(save, {"stage": 1}, box["snap"])
    assert g["action"] == "refuse" and g["levels"] == [112, 115, 119, 120], g
    assert "z112" in g["why"] and "lowest" in g["why"] and "aqshaft" in g["why"] and "p.aquifer=pass" in g["why"], g["why"]


def test_gate_probes_first_when_nothing_is_known_waits_while_it_digs_and_places_once_it_found_no_aquifer(world):
    save, box = world
    assert plan.core_span_gate(save, {"stage": 1}, box["snap"])["action"] == "probe"
    _bp(save, "c1a1probe", "aqshaft")
    g = plan.core_span_gate(save, {"stage": 1}, box["snap"])
    assert g["action"] == "wait" and "probe" in g["why"], g
    _done(save, "c1a1probe")
    assert plan.core_span_gate(save, {"stage": 1}, box["snap"])["action"] == "place"
    # the probe found a level: the route is plan propose's
    box["man"] = {"v": 2, "aquifer_levels": [118]}
    assert plan.core_span_gate(save, {"stage": 1}, box["snap"])["action"] == "refuse"


def test_gate_is_off_with_plan_core_probe_false(world, tmp_path):
    save, box = world
    cfg = tmp_path / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "baseline.json").write_text(json.dumps({"v": 2, "plan": {"core_probe": False}}))
    assert plan.core_probe_on() is False
    assert plan.core_span_gate(save, {"stage": 1}, box["snap"])["action"] == "place"


def _follow(save, box, monkeypatch):
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    sent, failed = [], []
    monkeypatch.setattr(f, "_send", lambda *a, **k: sent.append((a, k)) or "c1")
    monkeypatch.setattr(f, "_fail", lambda what, err, now: failed.append((what, str(err))))
    monkeypatch.setattr(files, "read_snapshot", lambda p: box["snap"])
    return f, sent, failed


def test_follow_places_the_probe_shaft_instead_of_the_starter_core_then_waits(world, monkeypatch):
    save, box = world
    f, sent, failed = _follow(save, box, monkeypatch)
    job = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
    f.jobs["starter"] = job
    f._place("starter", job, 1000.0)
    assert not failed, failed
    assert len(sent) == 1 and sent[0][0][0] == "bp.place", sent
    args = sent[0][0][1]
    # review of round 28: a surface column (no core, no manifest zones.Z4), named so that cmd.place needs no ranking
    assert args["tpl"] == "aqshaft" and args["site"] == "S1", args
    assert set(args["p"]) == {"x", "y", "top", "depth"} and args["p"]["depth"] == plan.CORE_PROBE_DEPTH and args["p"]["top"] == Z, args
    # the probe is placed (its bp file exists): the next starter says it waits, nothing is sent
    _bp(save, "c1a1probe", "aqshaft")
    job2 = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
    f.jobs["starter"] = job2
    f._place("starter", job2, 1000.0)
    assert len(sent) == 1 and failed and "BUG-441" in failed[0][1] and "probe" in failed[0][1], (sent, failed)


def test_follow_places_no_dry_site_core_while_an_aquifer_is_known(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [Z - 20]}          # known, deeper than every candidate: the site itself is dry
    monkeypatch.setattr(plan, "wet_core_guard", lambda d, p, s=None: (p, ""))
    f, sent, failed = _follow(save, box, monkeypatch)
    job = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
    f.jobs["starter"] = job
    f._place("starter", job, 1000.0)
    assert not sent and failed and "BUG-441" in failed[0][1] and "plan propose" in failed[0][1], (sent, failed)
    # an aquifer=pass core and the later stages are not the starter's business
    job2 = {"snap": "c0", "since": 1000.0, "params": {"stage": 2}, "tpl": "fortcore", "site": "same", "path": "snap/x.json"}
    f.jobs["starter"] = job2
    f._place("starter", job2, 1000.0)
    assert len(sent) == 1


# ---------------------------------------------------------------- BUG-441: a queued core above the aquifer is re-sited
def _row(pid, label="s1.dig", pct=0):
    return [pid, label, pct, "running"]


def test_core_over_aquifer_finds_a_queued_not_started_core_that_reaches_into_the_aquifer(world):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "depth": 3, "refuge": 3})
    st = {"proj": [_row("c1a1core")]}
    hit = plan.core_over_aquifer(save, st)
    assert hit and hit["proj"] == "c1a1core" and hit["levels"] == [112, 115, 119, 120] and "z112" in hit["why"], hit
    assert hit["started"] is False
    # any dug tile = started (review of round 28: never cancelled, but reported with started True), a later stage, an aquifer=pass core,
    # a retrofit: not touched
    h1 = plan.core_over_aquifer(save, {"proj": [_row("c1a1core", pct=1)]})
    assert h1 and h1["started"] is True and h1["pct"] == 1, h1
    assert plan.core_over_aquifer(save, {"proj": [_row("c1a1core", label="s2.dig")]}) is None
    assert plan.core_over_aquifer(save, {"proj": []}) is None                    # unknown to the state
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "aquifer": "pass"})
    assert plan.core_over_aquifer(save, st) is None
    # a core whose deepest level lies under the lowest known level is fine
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 112), params={"stage": 1, "depth": 3, "refuge": 3})
    assert plan.core_over_aquifer(save, st) is None
    # no aquifer known: nothing to re-site (the probe decides)
    box["man"] = {"v": 2}
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "depth": 3, "refuge": 3})
    assert plan.core_over_aquifer(save, st) is None


def test_follow_cancels_the_queued_core_above_the_aquifer_once(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "depth": 3, "refuge": 3})
    st = copy.deepcopy(files.read_state(save))
    st["mode"], st["proj"] = "PEACE", [_row("c1a1core")]
    monkeypatch.setattr(files, "read_state", lambda d: st)
    f, sent, failed = _follow(save, box, monkeypatch)
    f.auto = True
    wakes = []
    monkeypatch.setattr(f, "_synth", lambda typ, msg, now: wakes.append((typ, msg)))
    f._check_core_site(10_000.0)
    assert sent and sent[0][0][:2] == ("bp.cancel", {"proj": "c1a1core"}), sent
    assert wakes and wakes[0][0] == "PROJECT_STALE" and "BUG-441" in wakes[0][1] and "aqshaft" in wakes[0][1], wakes
    # the fort is coreless now: not silently (review of round 28)
    assert wakes[1][0] == "DECISION_NEEDED" and "core_resite" in wakes[1][1] and "plan propose" in wakes[1][1], wakes
    f._check_core_site(10_400.0)                                   # tried: not again within STALE_RETRY_S
    assert len(sent) == 1
    st["mode"] = "SIEGE"
    f._core_site_tried.clear()
    f._check_core_site(20_000.0)
    assert len(sent) == 1, "never in a fight"


# ---------------------------------------------------------------- BUG-442: orphan bp files
def test_orphan_candidates_skip_young_files_done_projects_state_rows_and_plan_builds_not_due(world, monkeypatch):
    save, _ = world
    st = copy.deepcopy(files.read_state(save))
    st["proj"] = [["c1a1live", "s1.dig", 10, "running"]]
    st["t"] = {**(st.get("t") or {}), "y": 372, "season": 1}
    monkeypatch.setattr(files, "read_state", lambda d: st)
    (save / "plan.json").write_text(json.dumps({"year": 372}))
    old = 3 * cmd.ORPHAN_AGE_S
    _bp(save, "y372s0b0", "fortcore", age=old)                     # a plan build of a season that is due: asked
    _bp(save, "y372s3b0", "traps", age=old)                        # season 3 is not due yet: no project expected
    _bp(save, "c1a1new", "fortcore", age=5)                       # just written: on its way to the kernel
    _bp(save, "c1a1live", "fortcore", age=old)                     # a row of the state's project list
    _bp(save, "c1a1done", "fortcore", age=old)
    _bp(save, "c1a1dead", "explore", age=old * 2)
    _done(save, "c1a1done")
    assert cmd.orphan_candidates(save) == ["c1a1dead", "y372s0b0"]                         # oldest first


def test_kernel_knows_reads_the_persist_reply():
    assert cmd.kernel_knows({"ok": True, "msg": "bp.x.tpl", "data": {"value": "fortcore"}}) is True
    assert cmd.kernel_knows({"ok": True, "msg": "bp.x.tpl: none", "data": {}}) is False
    assert cmd.kernel_knows({"ok": False, "msg": "unknown persist key"}) is None
    assert cmd.kernel_knows(None) is None
    assert cmd.no_such_project({"ok": False, "msg": "bp.cancel: no project y372s0b0"})
    assert not cmd.no_such_project({"ok": True, "msg": "cancelled"})


def test_bp_cancel_no_project_retires_the_dead_file_and_frees_the_fortcore_site(world, monkeypatch):
    save, _ = world
    doc = cmd.emit_at("fortcore", {"stage": 1}, {"id": "S1", "anchor": [68, 70, 123], "rot": 0}, "S1", "y372s0b0")
    p = save / "bp" / "y372s0b0.json"
    files.write_json_atomic(p, doc)
    assert cmd.first_core(save, "new") is not None                       # the dead file is 'the fort's fortcore already'
    monkeypatch.setattr(files, "read_outbox", lambda d, cid, timeout_s=0: {"ok": False, "msg": "bp.cancel: no project y372s0b0"})
    cmd.send(save, "bp.cancel", {"proj": "y372s0b0"}, by="cli", wait_s=1.0)
    assert not p.exists() and (save / "bp" / ".cancelled" / "y372s0b0.json").is_file()
    assert cmd.first_core(save, "new") is None


def test_retire_orphans_asks_the_kernel_and_retires_only_what_it_does_not_hold(world, monkeypatch):
    save, _ = world
    old = 3 * cmd.ORPHAN_AGE_S
    a, b = _bp(save, "c1a1ghost", "fortcore", age=old), _bp(save, "c1a1held", "traps", age=old)

    def reply(d, cid, timeout_s=0):
        doc = json.loads((save / "inbox" / next(p for p in os.listdir(save / "inbox") if cid in p)).read_text()) \
            if (save / "inbox").is_dir() and any(cid in p for p in os.listdir(save / "inbox")) else {}
        key = ((doc.get("args") or {}).get("key")) or ""
        if key.endswith("ghost"):
            return {"ok": True, "msg": "bp.c1a1ghost.tpl: none", "data": {}}
        return {"ok": True, "msg": "bp.c1a1held.tpl", "data": {"value": "traps"}}
    monkeypatch.setattr(files, "read_outbox", reply)
    got = cmd.retire_orphans(save, wait_s=1.0)
    assert got == ["c1a1ghost"], got
    assert not a.exists() and b.exists()


def test_follow_sweep_asks_about_candidates_and_retires_the_unknown_one(world, monkeypatch):
    save, box = world
    old = 3 * cmd.ORPHAN_AGE_S
    a = _bp(save, "c1a1ghost", "fortcore", age=old)
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir, f.auto = save, True
    sent = []

    def fake_send(verb, args, what, now, snap=None, need=None):
        sent.append((verb, args))
        f.jobs.setdefault("replies", {})["c9"] = {"verb": verb, "what": what, "since": now, "tpl": None, "proj": None}
        return "c9"
    monkeypatch.setattr(f, "_send", fake_send)
    f._sweep_orphans(5000.0)                                     # the first look only sets the clock: asked ORPHAN_FIRST_S later
    assert sent == []
    f._sweep_orphans(5000.0 + wake.ORPHAN_FIRST_S)
    assert sent == [("inspect", {"what": "persist", "key": "bp.c1a1ghost", "field": "tpl"})], sent
    assert f.jobs["replies"]["c9"]["orphan"] == "c1a1ghost"
    f._sweep_orphans(5200.0)                                     # not again within ORPHAN_EVERY_S
    assert len(sent) == 1
    monkeypatch.setattr(files, "read_outbox", lambda d, cid, timeout_s=0: {"ok": True, "msg": "bp.c1a1ghost.tpl: none", "data": {}})
    f._read_replies(5200.0)
    assert not a.exists() and (save / "bp" / ".cancelled" / "c1a1ghost.json").is_file()
    # no reply (DF closed): no AUTO_FAIL
    b = _bp(save, "c1a1other", "fortcore", age=old)
    f.jobs["replies"] = {"c10": {"verb": "inspect", "what": "orphan check", "since": 1.0, "tpl": None, "proj": None, "orphan": "c1a1other"}}
    failed = []
    monkeypatch.setattr(f, "_fail", lambda what, err, now: failed.append(err))
    monkeypatch.setattr(files, "read_outbox", lambda d, cid, timeout_s=0: None)
    f._read_replies(9000.0)
    assert not failed and b.exists()


def test_plan_apply_sweeps_orphans_first(world, monkeypatch):
    save, _ = world
    called = []
    monkeypatch.setattr(cmd, "retire_orphans", lambda d, wait_s=5.0, by="cli": called.append((wait_s, by)) or [])
    monkeypatch.setattr(plan, "check", lambda *a, **k: (["stop here"], []))
    errs, msg = plan.apply(save, {"year": 1, "seasons": []}, by="llm", wait_s=2.0)
    assert called == [(2.0, "llm")] and errs == ["stop here"], (called, errs)
    called.clear()
    plan.apply(save, {"year": 1, "seasons": []}, by="llm", wait_s=0)
    assert called == [], "no waiting, no sweep"


def test_follow_never_cancels_a_core_with_a_dug_tile_and_says_a_decision(world, monkeypatch):
    """Review of round 28: i2 Roadvises had a blocked stage-1 core (23 % dug) over the aquifer and follow stayed silent."""
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "depth": 3, "refuge": 3})
    st = copy.deepcopy(files.read_state(save))
    st["mode"], st["proj"] = "PEACE", [_row("c1a1core", label="s1.build", pct=23)]
    monkeypatch.setattr(files, "read_state", lambda d: st)
    f, sent, failed = _follow(save, box, monkeypatch)
    f.auto = True
    wakes = []
    monkeypatch.setattr(f, "_synth", lambda typ, msg, now: wakes.append((typ, msg)))
    f._check_core_site(10_000.0)
    assert not sent, "a dug core is not cancelled"
    assert len(wakes) == 1 and wakes[0][0] == "DECISION_NEEDED" and "core_over_aquifer" in wakes[0][1], wakes
    assert "23 %" in wakes[0][1] and "bp.cancel" in wakes[0][1] and "plan propose" in wakes[0][1], wakes


# ---------------------------------------------------------------- BUG-441 review: the probe on a fresh embark
def test_old_ranking_cannot_place_the_probe_without_z4_but_the_surface_column_can(world):
    """The real path: no core, no zones.Z4 in the manifest. `bp sites aqshaft` raises, the probe column places through cmd.place."""
    from dfpilot.bp import sites
    save, box = world
    box["man"] = {"v": 2}
    with pytest.raises(ValueError, match="zones.Z4"):
        sites.rank(box["snap"], "aqshaft", {"depth": plan.CORE_PROBE_DEPTH}, box["man"])
    args, why = plan.core_probe_args(save, box["snap"])
    assert args and args["tpl"] == "aqshaft" and "probe column" in why, (args, why)
    p = args["p"]
    assert (p["x"], p["y"], p["top"], p["depth"]) == (164, 154, Z, plan.CORE_PROBE_DEPTH), p       # the middle of the snapshot
    doc = cmd.place(save, "aqshaft", p, "S1", "c1a1probe", snap=box["snap"])
    assert doc["tpl"] == "aqshaft" and doc["anchor"] == [164, 154, Z], doc


def test_probe_column_keeps_four_tiles_from_open_water_and_off_other_walk_groups(world):
    save, box = world
    box["man"] = {"v": 2}
    box["snap"] = _snap(water=(167, 154, Z))                       # open water 3 tiles from the middle column
    args, _ = plan.core_probe_args(save, box["snap"])
    p = args["p"]
    assert max(abs(p["x"] - 167), abs(p["y"] - 154)) >= 5, p       # not within 4 tiles of it
    # the same rules as any aqshaft: cmd.place accepts it
    assert cmd.place(save, "aqshaft", p, "S1", "c1a1probe", snap=box["snap"])["anchor"][2] == Z
    # a cavern level in its way: no column at all, and the reason says so
    snap = _snap()
    snap["marks"] = {"cavern": [[150, 150, Z - 5]]}
    box["snap"] = snap
    args, why = plan.core_probe_args(save, snap)
    assert args is None and "no open surface floor column" in why and "cavern" in why, (args, why)


def test_follow_without_a_probe_column_says_a_decision_then_places_the_core_no_loop(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2}
    snap = _snap()
    snap["marks"] = {"cavern": [[150, 150, Z - 5]]}                # every column is refused
    box["snap"] = snap
    f, sent, failed = _follow(save, box, monkeypatch)
    wakes = []
    monkeypatch.setattr(f, "_synth", lambda typ, msg, now: wakes.append((typ, msg)))
    monkeypatch.setattr(plan, "wet_core_guard", lambda d, p, s=None: (p, ""))

    def ask():
        job = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
        f.jobs["starter"] = job
        f._place("starter", job, 1000.0)
    ask()
    assert not sent and failed, (sent, failed)                                       # not silent: a failure line ...
    assert wakes and wakes[0][0] == "DECISION_NEEDED" and "core_probe_noprobe" in wakes[0][1], wakes
    assert "bp.place" in wakes[0][1] and "core_probe = false" in wakes[0][1], wakes   # ... and the commands
    ask()                                                                            # the next ask places the core: no endless loop
    assert sent and sent[-1][0][1]["tpl"] == "fortcore", sent
    assert len(wakes) == 1


# ---------------------------------------------------------------- BUG-441 review: the wait has an end
def _state_with(save, tick, **extra):
    st = copy.deepcopy(files.read_state(save))
    st["t"] = {**(st.get("t") or {}), "tick": tick, "wall": 2_000_000_000, "tps": 500, "y": 372, "season": 1}
    st.update(extra)
    return st


def test_stalled_probe_ends_the_wait_with_project_blocked_and_a_decision_then_the_core(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2}
    p = _bp(save, "c1a1probe", "aqshaft", params={"depth": plan.CORE_PROBE_DEPTH})
    n = files.last_event_n(save) + 10
    append_events(save, [ev(n, "CMD", "", {"id": "c1a1probe", "ok": 1, "verb": "bp.place"}, tick=1000)])
    st = _state_with(save, 1000 + 10 * DAY)
    monkeypatch.setattr(files, "read_state", lambda d: st)
    g = plan.core_span_gate(save, {"stage": 1}, box["snap"])
    assert g["action"] == "wait" and g["proj"] == "c1a1probe", g                    # 10 days: it digs
    st = _state_with(save, 1000 + (plan.PROBE_WAIT_DAYS + 5) * DAY)
    monkeypatch.setattr(files, "read_state", lambda d: st)
    g = plan.core_span_gate(save, {"stage": 1}, box["snap"])
    assert g["action"] == "stalled" and "c1a1probe" in g["why"], g
    # follow: the first ask says PROJECT_BLOCKED + DECISION_NEEDED with the command, the next one places the core
    f, sent, failed = _follow(save, box, monkeypatch)
    wakes = []
    monkeypatch.setattr(f, "_synth", lambda typ, msg, now: wakes.append((typ, msg)))
    monkeypatch.setattr(plan, "wet_core_guard", lambda d, pp, s=None: (pp, ""))
    job = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
    f.jobs["starter"] = job
    f._place("starter", job, 1000.0)
    assert not sent and [w[0] for w in wakes] == ["PROJECT_BLOCKED", "DECISION_NEEDED"], (sent, wakes)
    assert "why=stalled" in wakes[0][1] and "bp.cancel" in wakes[1][1] and "c1a1probe" in wakes[1][1], wakes
    job = {"snap": "c0", "since": 1000.0, "params": {"stage": 1}, "tpl": "fortcore", "site": "S1", "path": "snap/x.json"}
    f.jobs["starter"] = job
    f._place("starter", job, 1000.0)
    assert sent and sent[-1][0][1]["tpl"] == "fortcore", sent
    p.unlink()


def test_a_finished_probe_that_dug_less_than_the_probe_depth_does_not_count_as_a_known_span(world, monkeypatch):
    save, box = world
    box["man"] = {"v": 2}
    _bp(save, "c1a1probe", "aqshaft", params={"depth": 6})
    _done(save, "c1a1probe")
    g = plan.core_span_gate(save, {"stage": 1}, box["snap"])
    assert g["action"] == "short" and "less than" in g["why"], g
    _bp(save, "c1a1probe", "aqshaft", params={"depth": plan.CORE_PROBE_DEPTH})
    assert plan.core_span_gate(save, {"stage": 1}, box["snap"])["action"] == "place"


# ---------------------------------------------------------------- BUG-442 review: a finished project is no orphan
def _core_doc(save, pid, anchor=(160, 150, Z)):
    doc = cmd.emit_at("fortcore", {"stage": 1}, {"id": "S1", "anchor": list(anchor), "rot": 0}, "S1", pid)
    p = save / "bp" / f"{pid}.json"
    files.write_json_atomic(p, doc)
    t = time.time() - 3 * cmd.ORPHAN_AGE_S
    os.utime(p, (t, t))
    return doc, p


def _dug(snap, doc):
    """The snapshot as the project left it: its dig tiles open floor."""
    for x, y, z in cmd.dig_cells(doc):
        row = list(snap["rows"][f"z{z}"][y - snap["bbox"][1]])
        row[x - snap["bbox"][0]] = "."
        snap["rows"][f"z{z}"][y - snap["bbox"][1]] = "".join(row)


def test_finished_core_whose_done_event_rotated_out_is_not_an_orphan_and_keeps_its_placed_record(world, monkeypatch):
    save, box = world
    doc, p = _core_doc(save, "c1a1core")
    assert cmd.dig_cells(doc), "the core digs"
    st = _state_with(save, 5_000_000)
    monkeypatch.setattr(files, "read_state", lambda d: st)
    box["snap"]["tick"] = 5_000_000
    placed = cmd._placed(save, "fortcore")
    files.write_json_atomic(placed, {"anchor": doc["anchor"], "rot": 0, "from": "S1", "bp": "c1a1core"})
    (save / "events.1.jsonl").write_text("")                      # the log rotated: PROJECT_DONE is not in it any more
    # the map shows it dug: provably NOT an orphan, whatever the kernel says (persist key bp.<id> is cleared at completion)
    _dug(box["snap"], doc)
    assert cmd.never_finished(save, "c1a1core") is False
    assert "c1a1core" not in cmd.orphan_candidates(save)
    assert cmd.retire_orphan(save, "c1a1core") is False and p.exists() and placed.is_file()
    # the explicit 'no project' answer of a pruned finished project is no orphan either
    monkeypatch.setattr(files, "read_outbox", lambda d, cid, timeout_s=0: {"ok": False, "msg": "bp.cancel: no project c1a1core"})
    cmd.send(save, "bp.cancel", {"proj": "c1a1core"}, by="cli", wait_s=1.0)
    assert p.exists() and placed.is_file() and not (save / "bp" / ".cancelled" / "c1a1core.json").exists()
    # with its PROJECT_DONE still in the log, retire() itself refuses and never resets .placed
    (save / "events.1.jsonl").unlink()
    _done(save, "c1a1core")
    assert cmd.retire(save, "c1a1core") is False and p.exists() and placed.is_file()


def test_never_started_core_after_a_log_rotation_is_an_orphan_only_with_the_snapshot_to_prove_it(world, monkeypatch):
    save, box = world
    doc, p = _core_doc(save, "c1a1ghost")
    st = _state_with(save, 5_000_000)
    monkeypatch.setattr(files, "read_state", lambda d: st)
    (save / "events.1.jsonl").write_text("")
    box["snap"]["tick"] = 5_000_000
    assert cmd.never_finished(save, "c1a1ghost") is True and cmd.orphan_candidates(save) == ["c1a1ghost"]    # the i2 y372s0b0 case
    box["snap"]["tick"] = 5_000_000 - 2 * schema.TICKS["MONTH"]                                          # a snapshot from before the dig: no proof
    assert cmd.never_finished(save, "c1a1ghost") is False and cmd.orphan_candidates(save) == []
    box["snap"]["tick"] = 5_000_000
    box["snap"]["bbox"] = [0, 0, 0, 5, 5, 5]                                                             # the dig tiles lie outside it: no proof
    box["snap"]["rows"] = {f"z{z}": ["#" * 6 for _ in range(6)] for z in range(6)}
    assert cmd.never_finished(save, "c1a1ghost") is False
    # a complete log (nothing rotated out) with no PROJECT_DONE: never finished, as before
    (save / "events.1.jsonl").unlink()
    assert cmd.never_finished(save, "c1a1ghost") is True
    placed = cmd._placed(save, "fortcore")
    files.write_json_atomic(placed, {"anchor": doc["anchor"], "rot": 0, "from": "S1", "bp": "c1a1ghost"})
    assert cmd.retire_orphan(save, "c1a1ghost") is True and not p.exists()
    assert not placed.exists(), "an orphan's own record goes with it (as before)"



# ---------------------------------------------------------------- BUG-445: surfacecore is no fallback
def test_bp_place_surfacecore_is_refused_unless_the_config_allows_it(world, tmp_path):
    save, _ = world
    with pytest.raises(cmd.BpError) as e:
        cmd.send(save, "bp.place", {"tpl": "surfacecore", "site": "S1"}, by="cli", wait_s=0)
    assert "BUG-445" in str(e.value) and "under the aquifer" in str(e.value), str(e.value)


def test_config_schema_knows_the_new_keys():
    from dfpilot import fairplay
    assert fairplay.PLAN_LIM["core_probe"] == "bool"
    assert fairplay.CONFIG_LIM_OK if hasattr(fairplay, "CONFIG_LIM_OK") else True
    assert not fairplay.plan_errors()
    assert schema.validate_args("inspect", {"what": "persist", "key": "bp.c1a1ghost", "field": "tpl"}) == []
