"""K2 (BUG-098, BUG-099, FR-81): the places around supervise that carry the alarm and the new click path.

wake (NEEDS_CLICK is a follower wake type with a first move), doctor (a fort that waits for a click is a problem), the
shell policy (the embark helper is driven from Python, never by a raw dfhack-run lua), tools/embark/embark.py load, and
the documents (RULES section 7, CONTRACTS follow wakes, bug files, FR-81, CHANGELOG)."""
import json
import re
import sys
import time
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths  # noqa: F401

from dfpilot import doctor, files, lint, wake
from dfpilot.events import est_tokens
from test_cli_wake import A, Clock, F  # noqa: F401

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "embark"))
import embark as drv  # noqa: E402


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


CLICK_MSG = ("click Continue by hand: save 'autosave 1', DFHack 53.16-r3; the automatic load failed: title screen: "
             "load.drive: \"autosave 1\" is not on the screen; screen: Select a game to continue | region2 | autosave 10 | Back")


# ---------------------------------------------------------------- wake
def test_needs_click_is_a_follower_wake_with_a_first_move_and_a_high_rank():
    assert "NEEDS_CLICK" in wake.SYNTH and "NEEDS_CLICK" in wake.PRIO and "NEEDS_CLICK" in wake.NEXT
    assert wake.PRIO.index("NEEDS_CLICK") < wake.PRIO.index("HB_STALE") < wake.PRIO.index("SIEGE_END")
    assert "tell Gordon at once" in wake.NEXT["NEEDS_CLICK"]
    g = wake.WakeGate()
    g.add(A(None, "NEEDS_CLICK", CLICK_MSG[:200]), 0)
    g.add(A(5, "YEAR_REVIEW", "year"), 1)
    line = wake.wake_line(g.flush(30), {"mode": "PEACE", "t": {"y": 3, "tick": 5}})
    assert line.index("NEEDS_CLICK") < line.index("YEAR_REVIEW")
    assert est_tokens(line) <= wake.WAKE_TOKENS and "autosave 1" in line and "53.16-r3" in line
    assert "next: tell Gordon at once" in line


def sup_doc(rt, c, key=None, msg=CLICK_MSG, said=None, last_wall=None, standing=True):
    doc = {"v": 2, "said": dict(said or {}), "last": {"wall": int(c.t if last_wall is None else last_wall),
                                                        "alerts": [{"key": key, "msg": msg}] if key else []}}
    if key and standing:
        doc[key] = {"save": "autosave 1", "ver": "53.16-r3", "why": "x", "screen": "y", "wall": int(c.t)}
    files.write_json_atomic(rt / "supervise.json", doc)


def test_follow_wakes_needs_click_by_the_supervise_cadence(save):
    rt, c = save.parent, Clock()
    sup_doc(rt, c, said={"backup": c.t - 9000})
    f, out = F(c)
    f.poll()
    c.t += 20
    f.poll()
    assert out == []
    said_t = c.t - 5
    sup_doc(rt, c, "needs_click", said={"needs_click": said_t})
    c.t += 20
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and out[0].startswith("WAKE ") and "NEEDS_CLICK" in out[0] and "SUPERVISE" not in out[0]
    assert "autosave 1" in out[0]
    for _ in range(40):                                        # the pass says it every minute, supervise.json moves only by its cadence
        c.t += 60
        sup_doc(rt, c, "needs_click", said={"needs_click": said_t})
        f.poll()
    assert len(out) == 1, "a standing alarm that supervise did not say again wakes nobody again"
    c.t += 400
    sup_doc(rt, c, "needs_click", said={"needs_click": c.t - 2})        # supervise said it again (SAY_EVERY_S)
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 2 and "NEEDS_CLICK" in out[1]


def test_other_supervisor_alerts_still_wake_as_supervise(save):
    rt, c = save.parent, Clock()
    sup_doc(rt, c, said={})
    f, out = F(c)
    f.poll()
    sup_doc(rt, c, "backup", msg="disk full", said={"backup": c.t - 5}, standing=False)
    c.t += 20
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "SUPERVISE" in out[0] and "backup: disk full" in out[0] and "NEEDS_CLICK" not in out[0]


def test_a_follow_that_starts_late_wakes_on_the_standing_alarm(save):
    rt, c = save.parent, Clock()
    sup_doc(rt, c, "needs_click", said={"needs_click": c.t - 1500})      # said before this follow existed
    f, out = F(c)
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "NEEDS_CLICK" in out[0] and "autosave 1" in out[0]


@pytest.mark.parametrize("case", ["resolved", "old_pass", "other_key"])
def test_a_late_follow_stays_quiet_when_nothing_stands(save, case):
    rt, c = save.parent, Clock()
    if case == "resolved":                                     # the fort is live again: supervise popped the key
        sup_doc(rt, c, "needs_click", said={"needs_click": c.t - 1500}, standing=False)
    elif case == "old_pass":                                   # supervise stopped running 20 minutes ago
        sup_doc(rt, c, "needs_click", said={"needs_click": c.t - 1500}, last_wall=c.t - 1200)
    else:
        sup_doc(rt, c, "backup", msg="disk full", said={"backup": c.t - 1500}, standing=False)
    f, out = F(c)
    f.poll()
    c.t += 11
    f.poll()
    assert out == []


# ---------------------------------------------------------------- doctor
def test_doctor_reports_a_fort_that_waits_for_a_click_and_the_dfhack_version():
    now = 1_800_000_000.0
    doc = {"v": 2, "dfhack": {"ver": "53.16-r3", "changed": {"from": "53.16-r2", "to": "53.16-r3", "ok": False}},
           "last_loaded": {"name": "autosave 1", "mt": 1.0, "ver": "53.16-r2"},
           "needs_click": {"save": "autosave 1", "ver": "53.16-r3", "why": "title screen: not on the screen",
                           "screen": "Select a game | region2", "wall": now - 900}}
    out, bad = doctor.supervise_lines(doc, now)
    assert out == ["supervise: DFHack 53.16-r3, the last successful load ran on 53.16-r2 (changed since: the title-screen "
                   "load is untested there)"]
    assert len(bad) == 1 and "'autosave 1'" in bad[0] and "15m" in bad[0] and "click Continue by hand" in bad[0]
    assert "Select a game | region2" in bad[0] and "DFHack 53.16-r3" in bad[0]
    assert doctor.supervise_lines({"v": 2}, now) == ([], [])
    assert doctor.supervise_lines(None, now) == ([], [])
    assert doctor.supervise_lines({"needs_click": "x", "dfhack": 5}, now) == ([], [])


def test_doctor_diagnose_reads_supervise_json(save):
    files.write_json_atomic(save.parent / "supervise.json", {
        "v": 2, "needs_click": {"save": "autosave 1", "ver": "53.16-r3", "why": "w", "screen": "", "wall": int(time.time()) - 60}})
    _lines, bad = doctor.diagnose(save)
    assert any("click Continue by hand" in b for b in bad)
    files.write_json_atomic(save.parent / "supervise.json", {"v": 2})
    _lines, bad = doctor.diagnose(save)
    assert not any("click Continue" in b for b in bad)


# ---------------------------------------------------------------- shell policy and the embark driver
def test_the_embark_helper_is_not_a_raw_dfhack_run_lua_call():
    for c in ("dfhack-run lua -f tools/embark/embark.lua load autosave",
              "dfhack-run lua -f E:\\repo\\tools\\embark\\embark.lua run spec.json"):
        ok, why = lint.cmd(c)
        assert not ok and "python tools/embark/embark.py" in why, c
    assert not lint.cmd("dfhack-run lua print(1)")[0]
    assert lint.cmd("dfhack-run lua print(1)")[1].startswith("inline lua")
    for c in ("python tools/embark/embark.py load 'autosave 1'", "python -m dfpilot supervise --check-version",
              "dfhack-run load-save 'autosave 1'"):
        assert lint.cmd(c)[0], c
    assert not lint.cmd("dfhack-run load-save")[0]


def test_embark_py_load_spec():
    s = drv.make_spec("load", save=" autosave   1 ", now=7)
    assert s == {"v": 2, "id": "load7", "mode": "load", "save": "autosave 1", "stock": True}
    s = drv.make_spec("load", save="autosave 1", entry="Ost  lysh", stock=False, now=7)
    assert s["entry"] == "Ost lysh" and s["stock"] is False
    for bad in ("", None, "a/b", "a\\b", ".."):
        with pytest.raises(ValueError):
            drv.make_spec("load", save=bad)


def test_embark_py_load_main_writes_the_spec_and_reports(tmp_path, monkeypatch, capsys):
    calls = []
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    assert drv.main(["load", "autosave 1", "--entry", "Ostlysh", "--no-stock", "--no-wait"]) == 0
    assert len(calls) == 1 and calls[0][0] == "run"
    spec = json.loads(Path(calls[0][1]).read_text(encoding="utf-8"))
    assert spec["mode"] == "load" and spec["save"] == "autosave 1" and spec["entry"] == "Ostlysh" and spec["stock"] is False
    with pytest.raises(SystemExit):
        drv.main(["load", "../x", "--no-wait"])


def test_embark_py_summarizes_a_load_run_with_the_clicks_and_the_rows():
    doc = {"id": "load5", "state": "failed", "step": "load.drive", "i": 2, "n": 2,
           "msg": 'load.drive: "autosave 1" is not on the screen (nothing clicked here)',
           "results": {"screen": "other", "rows": "Select a game | region2", "title": {"old_field": False, "selected": 0},
                       "clicks": [{"n": 1, "kind": "main", "text": "Continue playing", "tx": 9, "ty": 18, "px": 95, "py": 277}]},
           "warnings": ["load.stock: skipped"]}
    text = "\n".join(drv.summarize(doc))
    assert 'click 1: main "Continue playing" tile 9,18 pixel 95,277' in text
    assert "last screen (other): Select a game | region2" in text and '"old_field": false' in text
    assert "warning: load.stock: skipped" in text
    assert drv.summarize({"id": "s", "state": "done", "results": [], "i": 1, "n": 1})[0].startswith("s: done")
    assert drv.load_verdict(doc).startswith('LOAD FAILED: load.drive: "autosave 1" is not on the screen')
    ok = {"state": "done", "results": {"outcome": "loading", "clicks": [{}, {}]}}
    assert drv.load_verdict(ok) == "LOAD OK: left the title screen (loading) after 2 click(s)"
    assert "DFHack's own load-save" in drv.load_verdict({"state": "done", "results": {"outcome": "loading"}})
    assert drv.load_verdict({"state": "stopped", "msg": "stopped by command"}) == "LOAD STOPPED: stopped by command"
    assert drv.load_verdict(None).startswith("LOAD UNKNOWN")


def test_embark_py_load_prints_the_verdict(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: "started")
    done = {"id": "x", "state": "done", "step": "", "i": 3, "n": 2, "msg": "all steps done",
            "results": {"outcome": "loading", "clicks": [{"n": 1, "kind": "main", "text": "Continue playing",
                                                         "tx": 9, "ty": 18, "px": 95, "py": 277}]}}
    monkeypatch.setattr(drv, "wait", lambda *a, **k: done)
    assert drv.main(["load", "autosave 1"]) == 0
    out = capsys.readouterr().out
    assert out.rstrip().endswith("LOAD OK: left the title screen (loading) after 1 click(s)")
    monkeypatch.setattr(drv, "wait", lambda *a, **k: dict(done, state="failed", msg='load.drive: "autosave 1" is not on the screen'))
    assert drv.main(["load", "autosave 1"]) == 1
    assert 'LOAD FAILED: load.drive: "autosave 1" is not on the screen' in capsys.readouterr().out


# ---------------------------------------------------------------- documents
def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def test_rules_section_7_has_the_needs_click_row_and_stays_within_300_lines():
    rules = read("RULES.md")
    sec = rules.split("## 7.")[1].split("## 8.")[0]
    row = [ln for ln in sec.splitlines() if ln.startswith("|") and "NEEDS_CLICK" in ln.split("|")[1]]
    assert len(row) == 1 and "title screen" in row[0] and "Continue" in row[0]
    assert len(rules.splitlines()) <= 300


def test_contracts_name_the_follower_wake_and_the_supervise_keys():
    doc = read("docs/v2/CONTRACTS.md")
    line = [ln for ln in doc.splitlines() if ln.startswith("**Follow's own wakes**")][0]
    assert "NEEDS_CLICK" in line and "needs_click" in line
    row = [ln for ln in doc.splitlines() if ln.startswith("| `supervise` (WP10)")][0]
    assert "title_run" in row and "needs_click" in row and "dfhack_version" in row and "--check-version" in row
    runtime = doc.split("## 8. Runtime folder")[1].split("## 9.")[0]
    assert "supervise.json" in runtime and "`embark/`" in runtime


def test_bug_and_fr_documents_exist_and_are_complete():
    readme = read("bugs/README.md")
    for num in ("098", "099"):
        files_ = list((ROOT / "bugs").glob(f"BUG-{num}-*.md"))
        assert len(files_) == 1, num
        text = files_[0].read_text(encoding="utf-8")
        assert f"BUG-{num}" in readme and files_[0].name in readme
        for head in ("Status:", "## Actual", "## Cause", "## Fix", "## Not decided offline", "## Tests"):
            assert head in text, (num, head)
        assert re.search(r"[a-z_/]+\.(py|lua):\d+", text), "the cause cites file:line"
    assert "FR-81" in read("docs/feature-requests/README.md") and "FR-81" in read("CHANGELOG.md")
    top = next(s for s in read("CHANGELOG.md").split("\n## ")[1:] if "BUG-098" in s and "BUG-099" in s)
    for head in ("**Why:**", "**What changed", "**Live check:**"):
        assert head in top, head
    assert "BUG-098" in top and "BUG-099" in top
