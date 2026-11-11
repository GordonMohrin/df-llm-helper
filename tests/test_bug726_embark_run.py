"""BUG-726 (Run 16d i4 Pagedsculpture, the embark tools): (1) a `--budget` end leaves the sweep running in DF; the next rank/scan was answered
'run scanNNN is active; use stop' and the driver then showed the result of the OLD sweep: it stops the old run (naming its box), starts the
new one, and never hands back another run's status. (2) A rectangle scan reads ONE hovered tile, a hover row up to 16: 'brook=none seen' says
how many tiles were read. The world.goto edge fix is tests/lua/test_bug726_embark_edge.lua."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "embark"))
import embark as drv  # noqa: E402


def _status(out, run_id, state, i=3, n=40):
    (out / "status.json").write_text(json.dumps({"id": run_id, "state": state, "i": i, "n": n}), encoding="utf-8")


def _spec(out, run_id, cands):
    (out / f"spec-{run_id}.json").write_text(json.dumps({"id": run_id, "cands": cands}), encoding="utf-8")


def test_spec_box_text_names_the_box_of_a_run(tmp_path):
    _spec(tmp_path, "scan1", [[1, 17], [3, 17], [1, 19], [3, 19]])
    assert drv.spec_box_text(tmp_path, "scan1") == "box 1,17..3,19 (4 world tiles)"
    assert drv.spec_box_text(tmp_path, "nope") == ""
    assert drv.spec_box_text(tmp_path, None) == ""


def test_an_active_sweep_is_stopped_and_the_new_run_starts_once(tmp_path, monkeypatch):
    _spec(tmp_path, "scanOLD", [[0, 17], [5, 20]])
    _status(tmp_path, "scanOLD", "running")
    calls, lines = [], []

    def call(args, *a, **k):
        calls.append(args[0])
        if args[0] == "run":
            if calls.count("run") == 1:
                return "run scanOLD is active; use stop"            # dfhack-run answers rc 0 with the script's error text
            return "started scanNEW"
        if args[0] == "stop":
            _status(tmp_path, "scanOLD", "stopped")
            return "stopped"
        raise AssertionError(args)
    monkeypatch.setattr(drv, "call", call)
    got = drv.start_run(tmp_path / "spec-scanNEW.json", tmp_path, echo=lines.append, sleep=lambda s: None)
    assert got == "started scanNEW" and calls == ["run", "stop", "run"], calls
    assert any("scanOLD" in ln and "box 0,17..5,20 (2 world tiles)" in ln and "stopping it" in ln for ln in lines), lines


def test_a_run_that_stays_active_is_an_error_not_a_stale_result(tmp_path, monkeypatch):
    _status(tmp_path, "scanOLD", "running")
    monkeypatch.setattr(drv, "call", lambda args, *a, **k: "run scanOLD is active; use stop")
    with pytest.raises(SystemExit) as e:
        drv.start_run(tmp_path / "spec-scanNEW.json", tmp_path, echo=lambda *_: None, sleep=lambda s: None)
    assert "still active" in str(e.value) and "scanOLD" in str(e.value)


def test_a_free_dfhack_starts_with_one_call(tmp_path, monkeypatch):
    seen = []
    monkeypatch.setattr(drv, "call", lambda args, *a, **k: seen.append(args[0]) or "started")
    assert drv.start_run(tmp_path / "spec-x.json", tmp_path) == "started" and seen == ["run"]


def test_wait_never_returns_the_status_of_another_run(tmp_path):
    _status(tmp_path, "scanOLD", "running")
    t = {"now": 0.0}

    def sleep(s):
        t["now"] += s
    assert drv.wait("scanNEW", tmp_path, 3, clock=lambda: t["now"], sleep=sleep, echo=lambda *_: None) is None


def test_none_seen_says_how_many_tiles_were_read():
    row = {"tag": "x", "emb": [96, 96], "size": [4, 4], "rec": {"read": 6}}                     # a rectangle scan: one hovered tile
    txt = drv.brook_text(row, [])
    assert txt.startswith(" brook=none seen on 1 of 16 tiles") and "scan --hover" in txt, txt
    hover = {"tag": "x", "emb": [96, 96], "size": [4, 4], "rec": {"read": 6, "tiles": {"n": 4}}}
    assert drv.brook_text(hover, []).startswith(" brook=none seen on 4 of 16 tiles")
    full = {"tag": "x", "emb": [96, 96], "size": [4, 4], "rec": {"read": 6, "tiles": {"n": 16}}}
    assert drv.brook_text(full, []) == " brook=none seen"
