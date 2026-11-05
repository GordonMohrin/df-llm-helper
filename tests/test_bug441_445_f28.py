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
    assert args["tpl"] == "aqshaft" and args["site"] == "S1" and args["p"] == {"depth": plan.CORE_PROBE_DEPTH}, args
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
def _row(pid, label="s1.dig", pct=5):
    return [pid, label, pct, "running"]


def test_core_over_aquifer_finds_a_queued_not_started_core_that_reaches_into_the_aquifer(world):
    save, box = world
    box["man"] = {"v": 2, "aquifer_levels": [120, 119, 115, 112]}
    _bp(save, "c1a1core", "fortcore", anchor=(110, 110, 125), params={"stage": 1, "depth": 3, "refuge": 3})
    st = {"proj": [_row("c1a1core")]}
    hit = plan.core_over_aquifer(save, st)
    assert hit and hit["proj"] == "c1a1core" and hit["levels"] == [112, 115, 119, 120] and "z112" in hit["why"], hit
    # dug past CORE_UNSTARTED_PCT, a later stage, an aquifer=pass core, a retrofit: not touched
    assert plan.core_over_aquifer(save, {"proj": [_row("c1a1core", pct=60)]}) is None
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
