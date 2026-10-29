"""BUG-209..213 (live round 3, the fresh fort "Earthboat" played from embark): doctor/status/next on a save nobody adopted,
the entrance reading of a seal at=last, follow's seal at=audit before the trap hall and on fortcore tiles, the status
proj and UNREADY lines, the audit wait printed as an int."""
import json
import types
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import brief, cmd, doctor, files, guide, paths, supervise, wake
from dfpilot.cli import main

NOW = 1333056                                       # the fixture state's t.abs
BYPASS = "bypass: wall 100,127,122 floor -> 139,128,117"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **extra):
    st = files.read_state(save)
    st.update(extra)
    st["seq"] = st["seq"] + 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


def READY(**kw):
    return dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 100, "min_traps": 0},
                 "fail": ["open_perimeter"], "open": 2}, **kw)


# ---------------------------------------------------------------- BUG-209: a save nobody adopted
def test_doctor_flags_a_missing_active_while_df_runs_here(save, monkeypatch):
    (save.parent / "ACTIVE").unlink()
    monkeypatch.setattr(doctor, "df_up", lambda df=None: True)
    lines, bad = doctor.diagnose(save)
    hit = [b for b in bad if b.startswith("ACTIVE missing")]
    assert len(hit) == 1 and "not adopted" in hit[0] and "dfhack-run dfllm adopt" in hit[0] and "'region7'" in hit[0], bad
    monkeypatch.setattr(doctor, "df_up", lambda df=None: False)     # DF closed: a note, no problem
    lines, bad = doctor.diagnose(save)
    assert not any(b.startswith("ACTIVE missing") for b in bad)
    assert any(x.startswith("ACTIVE missing: no dfllm fort is loaded (DF does not run from") for x in lines), lines


def test_doctor_does_not_ask_for_adopt_while_active_names_the_folder(save, monkeypatch):
    monkeypatch.setattr(doctor, "df_up", lambda df=None: pytest.fail("no process check while ACTIVE exists"))
    _lines, bad = doctor.diagnose(save)
    assert not any("ACTIVE missing" in b for b in bad)


def test_df_up_reads_the_process_image_of_this_folder_only(tmp_path, monkeypatch):
    df = tmp_path / "DF"
    df.mkdir()
    assert doctor.df_up(df) is False                                # no Dwarf Fortress.exe here: no process check
    (df / supervise.DF_EXE).write_bytes(b"")
    out = b'"Dwarf Fortress.exe","4242","Console","1","1.000 K"\r\n'
    import subprocess
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: types.SimpleNamespace(stdout=out, stderr=b"", returncode=0))
    img = {"p": str(df / supervise.DF_EXE)}
    monkeypatch.setattr(supervise, "_win", lambda: types.SimpleNamespace(image=lambda pid: img["p"]))
    assert doctor.df_up(df) is True
    img["p"] = str(tmp_path / "other" / supervise.DF_EXE)            # another DF copy (another port) runs
    assert doctor.df_up(df) is False
    img["p"] = ""                                                    # the image cannot be read
    assert doctor.df_up(df) is None


def test_status_line_one_says_the_folder_is_a_fallback(save):
    assert "(not ACTIVE)" not in brief.status_text(save).splitlines()[0]
    (save.parent / "ACTIVE").unlink()
    head = brief.status_text(save).splitlines()[0]
    assert "region7 (fallback: newest folder, not ACTIVE)" in head, head
    paths.set_overrides(runtime=str(save.parent), save="region7")   # pinned with --save: not a fallback
    head = brief.status_text(save).splitlines()[0]
    assert "region7 (not ACTIVE)" in head and "fallback" not in head, head


def test_next_answers_adopt_for_a_loaded_fort_without_active(save, monkeypatch, capsys):
    (save.parent / "ACTIVE").unlink()
    monkeypatch.setattr(doctor, "df_up", lambda df=None: True)
    assert main(["--runtime", str(save.parent), "next", "--peek"]) == 0
    out = capsys.readouterr().out
    assert out.splitlines()[0] == f"NEXT: {guide.ADOPT_CMD}" and "not adopted" in out, out
    monkeypatch.setattr(doctor, "df_up", lambda df=None: False)     # DF closed: the old answer (doctor)
    assert main(["--runtime", str(save.parent), "next", "--peek"]) == 0
    assert capsys.readouterr().out.splitlines()[0] == "NEXT: dfllm doctor"


def test_next_answers_adopt_before_the_first_runtime_folder_exists(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    rt = tmp_path / "rt"
    rt.mkdir()
    try:
        monkeypatch.setattr(doctor, "df_up", lambda df=None: True)
        assert main(["--runtime", str(rt), "next"]) == 0
        assert capsys.readouterr().out.splitlines()[0] == "NEXT: dfhack-run dfllm adopt"
        monkeypatch.setattr(doctor, "df_up", lambda df=None: False)
        assert main(["--runtime", str(rt), "next"]) == 2
        assert "no save" in capsys.readouterr().out
    finally:
        reset_paths()


# ---------------------------------------------------------------- BUG-210: the entrance reading of seal at=last
def test_last_entrances_takes_the_newer_state_over_an_old_siege_unready(save):
    append_events(save, [ev(8813, "SIEGE_UNREADY", "u", {"fails": ["open_perimeter"], "ents": ["94,79,140 shrub"]},
                            tick=NOW - 34 * 1200)])
    put_state(save, ready=READY(ents=["60,80,140 floor", "25,103,140 floor"]))
    assert cmd.last_entrances(save) == ["60,80,140 floor", "25,103,140 floor"]
    assert [e["pos"] for e in cmd.current_openings(save) if e["src"] == "ents"] == [(60, 80, 140), (25, 103, 140)]
    put_state(save, ready=READY(open=0, fail=["audit"]))            # the newer check: no way in is open
    assert cmd.last_entrances(save) == []


def test_last_entrances_keeps_the_longer_event_list_of_the_same_reading(save):
    six = [f"{x},50,140 floor" for x in range(10, 16)]
    append_events(save, [ev(8813, "SIEGE_UNREADY", "u", {"fails": ["open_perimeter"], "ents": six}, tick=NOW - 50)])
    put_state(save, ready=READY(open=6, ents=six[:3]))
    assert cmd.last_entrances(save) == six
    st = put_state(save, ready=READY(ents=["1,1,140 floor"]))      # the event is newer than the state: the event
    st["t"] = dict(st["t"], abs=NOW - 100)
    assert cmd.entrance_reading(save, st)[0] == six


def test_last_entrances_falls_back_to_the_event_before_readiness_checked(save):
    append_events(save, [ev(8813, "SIEGE_UNREADY", "u", {"ents": ["5,5,140 floor"]}, tick=NOW - 50)])
    assert cmd.last_entrances(save) == ["5,5,140 floor"]           # the fixture's ready has no `open`


# ---------------------------------------------------------------- BUG-211: follow's seal at=audit
class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def _follower():
    out = []
    return wake.Follower(out=out.append, clock=Clock()), out


def _auto_seal_lines(save):
    p = save / "cli.log"
    return [ln for ln in p.read_text("utf-8").splitlines() if "auto:seal" in ln] if p.exists() else []


def test_follow_places_no_audit_seal_while_the_fort_has_no_trap_hall(save):
    f, _ = _follower()
    f.poll()
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [cmd.NO_HALL, BYPASS], "min_traps": 0})])
    f.poll()
    assert list((save / "inbox").glob("*.json")) == [] and _auto_seal_lines(save) == []


def test_follow_logs_the_audit_seal_once_per_walls_set(save):
    f, _ = _follower()
    f.poll()
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()
    append_events(save, [ev(8814, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()                                                         # within the cooldown: no second request, no line
    assert len(list((save / "inbox").glob("*.json"))) == 1
    assert len(_auto_seal_lines(save)) == 1, _auto_seal_lines(save)


def test_audit_walls_on_a_fortcore_tile_are_never_open(save):
    core = cmd.emit_at("fortcore", {"stage": 1}, {"id": "S1", "anchor": [100, 82, 140], "rot": 0}, "S1", "c1fc00")
    files.write_json_atomic(save / "bp" / "c1fc00.json", core)
    x, y, z = sorted(cmd.bp_cells(core))[len(cmd.bp_cells(core)) // 2]
    wall = f"bypass: wall {x},{y},{z} floor -> 53,81,{z}"
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [wall, BYPASS], "min_traps": 35})])
    a = cmd.audit_routes(save)
    assert a["core"] == {f"{x},{y},{z} floor wall": "c1fc00"}
    assert a["open"] == ["100,127,122 floor wall"]
    assert cmd.no_trap_hall(a["fails"]) is False and cmd.no_trap_hall([cmd.NO_HALL]) is True


# ---------------------------------------------------------------- BUG-212: status proj and UNREADY lines
def test_status_keeps_the_proj_line_and_one_next_hint_under_a_long_unready_line(save):
    ents = [f"{x},62,117 floor" for x in range(50, 53)]
    put_state(save, ready=READY(open=7, ents=ents, pd=12, pw="w" * 60, route=BYPASS[:60],
                                fail=["open_perimeter", "audit_old", "bypass", "no_outer", "no_kern", "office",
                                      "refuge_dry", "hospital_out"], office="o" * 200),
              proj=[["c1a1", "s1.build", 34, ""], ["c1a2", "s1.dig", 5, "waits:Bed"], ["c1a3", "s0.dig", 1, ""]])
    out = brief.status_text(save)
    proj = [ln for ln in out.splitlines() if ln.startswith("proj ")]
    assert proj and proj[0].startswith("proj c1a2 s1.dig 5% BLOCKED:waits:Bed, c1a1 s1.build 34%"), out
    un = next(ln for ln in out.splitlines() if ln.startswith("SIEGE UNREADY"))
    assert un.count("next:") <= 1 and ";" not in un.split("next:", 1)[-1], un
    full = brief.line_unready(brief.Ctx(save), cmds=True)
    assert full.split("next: ", 1)[1].count("; ") >= 3                # brief keeps every hint


def test_status_says_the_bypass_waits_for_the_trap_hall(save):
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [cmd.NO_HALL, BYPASS]}, tick=NOW - 10)])
    put_state(save, ready=READY(fail=["bypass"], open=0, route=BYPASS))
    un = brief.line_unready(brief.Ctx(save), cmds=False)
    assert "no trap hall yet: the bypass waits for fortcore stage 2" in un and "at=audit (or" not in un, un


# ---------------------------------------------------------------- BUG-213: the audit wait as an int
def test_audit_prints_its_wait_as_whole_seconds(save, monkeypatch, capsys):
    monkeypatch.setattr(wake, "audit_timeout", lambda d: (97.4, 2048))
    monkeypatch.setattr(cmd, "send", lambda *a, **k: (None, None))
    args = types.SimpleNamespace(snap=None, timeout=None)
    wake.run_audit(args, save)
    out = capsys.readouterr().out
    assert "audit: waiting up to 97 s for the fresh snapshot" in out, out
