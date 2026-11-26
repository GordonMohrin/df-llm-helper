"""NEU19 BUG-927 (Run 17 i2 Whirledrampart: bp/c1a1c57ffc32132601.json, a seal file the kernel does not know ('no project' for bp.cancel and bp.resume), kept `plan check` warning
'seal c1a1c57ffc32132601 +6 is open: the runner pauses bedrooms, stockroom in PEACE' for years, with state.proj null so plan.open_seals fell back to every unfinished seal file; retire() refuses a
file that may be a finished project, the player may not delete in dfllm-runtime). Now a seal file the kernel answered 'none' for is MARKED orphaned (bp/.orphans.json, the file stays), logged
once, and ignored by plan.open_seals and cmd.seal_records."""
from __future__ import annotations

import json

import pytest
from test_bug441_445_f28 import _bp, _done, world  # noqa: F401  (the runtime fixture of round 28)

from dfpilot import cmd, files, plan, wake

pytestmark = pytest.mark.orphans
OLD = 3 * cmd.ORPHAN_AGE_S


def state_without_rows(save):
    st = files.read_state(save)
    st.pop("proj", None)
    return st


def test_a_dead_seal_file_counts_as_an_open_seal_until_it_is_marked(world):
    save, _ = world
    _bp(save, "c1a1dead", "seal", params={"at": "73,122,142 brook_top"}, age=OLD)
    st = state_without_rows(save)
    assert [x["proj"] for x in plan.open_seals(save, st)] == ["c1a1dead"], "state.proj null: every unfinished seal file (the i2 picture)"
    assert cmd.orphan_seal_candidates(save) == ["c1a1dead"]
    assert cmd.mark_orphan(save, "c1a1dead", "cli") is True
    assert plan.open_seals(save, st) == [], "the warning is gone"
    assert plan.fort_facts(save, st)["seals"] == []
    assert (save / "bp" / "c1a1dead.json").is_file(), "the file itself is not touched"
    assert cmd.orphan_seal_candidates(save) == [], "not asked again"
    assert cmd.mark_orphan(save, "c1a1dead", "cli") is False
    log = (save / "cli.log").read_text("utf-8")
    assert log.count("orphan:ignored") == 1, "logged once"


def test_a_marked_seal_that_the_kernel_lists_again_counts(world):
    save, _ = world
    _bp(save, "c1a1back", "seal", age=OLD)
    cmd.mark_orphan(save, "c1a1back", "cli")
    st = state_without_rows(save)
    st["proj"] = [["c1a1back", "seal.build", 10, ""]]
    assert [x["proj"] for x in plan.open_seals(save, st)] == ["c1a1back"]


def test_young_files_done_projects_non_seals_and_state_rows_are_not_asked(world, monkeypatch):
    save, _ = world
    _bp(save, "c1a1young", "seal", age=5)
    _bp(save, "c1a1done", "seal", age=OLD)
    _done(save, "c1a1done")
    _bp(save, "c1a1core", "fortcore", age=OLD)
    _bp(save, "c1a1live", "seal", age=OLD)
    st = dict(files.read_state(save), proj=[["c1a1live", "seal.build", 10, ""]])
    monkeypatch.setattr(files, "read_state", lambda d: st)
    assert cmd.orphan_seal_candidates(save) == []


def test_seal_records_skip_a_marked_file(world):
    save, _ = world
    p = _bp(save, "c1a1dead", "seal", params={"at": "79,131,141 floor"}, age=OLD)
    cmd.mark_orphan(save, "c1a1dead", "cli")
    assert cmd.seal_records(save) == {} and p.is_file()


def test_settle_orphan_retires_a_never_finished_file_and_marks_a_doubtful_one(world):
    save, _ = world
    a = _bp(save, "c1a1never", "seal", age=OLD)
    assert cmd.settle_orphan(save, "c1a1never", "cli") == "retired" and not a.exists()
    (save / "events.1.jsonl").write_text("", encoding="utf-8")            # an event log that rotated: a done event may be gone
    b = _bp(save, "c1a1doubt", "seal", age=OLD)
    assert cmd.settle_orphan(save, "c1a1doubt", "cli") == "marked" and b.is_file()
    assert "c1a1doubt" in cmd.read_orphans(save)


def test_follow_marks_a_doubtful_seal_the_kernel_does_not_hold(world, monkeypatch):
    save, _ = world
    (save / "events.1.jsonl").write_text("", encoding="utf-8")
    p = _bp(save, "c1a1ghost", "seal", age=OLD)
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir, f.auto = save, True
    sent = []

    def fake_send(verb, args, what, now, snap=None, need=None):
        sent.append((verb, args))
        f.jobs.setdefault("replies", {})["c9"] = {"verb": verb, "what": what, "since": now, "tpl": None, "proj": None}
        return "c9"
    monkeypatch.setattr(f, "_send", fake_send)
    f._sweep_orphans(5000.0)
    f._sweep_orphans(5000.0 + wake.ORPHAN_FIRST_S)
    assert sent == [("inspect", {"what": "persist", "key": "bp.c1a1ghost", "field": "tpl"})], sent
    monkeypatch.setattr(files, "read_outbox", lambda d, cid, timeout_s=0: {"ok": True, "msg": "bp.c1a1ghost.tpl: none", "data": {}})
    f._read_replies(5200.0)
    assert p.is_file() and "c1a1ghost" in cmd.read_orphans(save), "kept on disk, marked"
    assert plan.open_seals(save, state_without_rows(save)) == []


def test_bp_resume_no_project_marks_the_file(world, monkeypatch):
    save, _ = world
    (save / "events.1.jsonl").write_text("", encoding="utf-8")
    p = _bp(save, "c1a1resume", "seal", age=OLD)
    monkeypatch.setattr(files, "read_outbox", lambda d, cid, timeout_s=0: {"ok": False, "msg": "bp.resume: no project c1a1resume"})
    cmd.send(save, "bp.resume", {"proj": "c1a1resume"}, by="cli", wait_s=1.0)
    assert p.is_file() and "c1a1resume" in cmd.read_orphans(save)


def test_a_finished_seal_whose_done_event_rotated_out_is_not_marked(world):
    save, box = world
    (save / "events.1.jsonl").write_text("", encoding="utf-8")            # the log rotated: PROJECT_DONE may be gone
    x0, y0, z0, x1, y1, z1 = box["snap"]["bbox"]
    at = (x0 + 5, y0 + 5, z1 - 1)
    p = _bp(save, "c1a1fin", "seal", params={"at": "%d,%d,%d floor" % at}, age=OLD)
    pc = cmd.load_bp("defense").seal_pieces({"at": "%d,%d,%d floor" % at})[0]
    px, py, pz = pc["at"]
    row = list(box["snap"]["rows"][f"z{pz}"][py - y0])
    row[px - x0] = "+"                                                    # its door stands on the map
    box["snap"]["rows"][f"z{pz}"][py - y0] = "".join(row)
    assert cmd.settle_orphan(save, "c1a1fin", "cli") == "kept"
    assert "c1a1fin" not in cmd.read_orphans(save) and p.is_file()
    row[px - x0] = "."                                                    # the opening is still open: nothing was built
    box["snap"]["rows"][f"z{pz}"][py - y0] = "".join(row)
    assert cmd.settle_orphan(save, "c1a1fin", "cli") == "marked"


def test_seal_records_read_a_marked_file_again_when_the_kernel_lists_it_and_the_mark_is_cleared(world):
    save, _ = world
    _bp(save, "c1a1back", "seal", params={"at": "79,131,141 floor"}, age=OLD)
    cmd.mark_orphan(save, "c1a1back", "cli")
    assert cmd.seal_records(save) == {}
    st = dict(files.read_state(save), proj=[["c1a1back", "seal.build", 10, ""]])
    assert cmd.seal_records(save) == {}, "the state read from disk lists no such row yet"
    import dfpilot.files as F
    orig = F.read_state
    try:
        F.read_state = lambda d: st
        assert cmd.seal_records(save), "listed again: counts"
    finally:
        F.read_state = orig
    assert "c1a1back" not in cmd.read_orphans(save), "mark cleared"
