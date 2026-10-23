"""FR-70 and BUG-048 on the Python side (the kernel side is tests/lua/test_open_perimeter.lua,
tests/lua/test_perimeter_keeper.lua). Run 11 y483-y497: a door open for 14 years (follow --no-auto), O1/B1/B2 lost for
18; Run 13 y507-y525: the same over an open O1. Checked: the contract fields (ready.pd/pw, SIEGE_UNREADY pd/pw,
PERIMETER_BROKEN replaced, bridges `replaced`), the config keys and limits, the status/brief line that counts the days
and says "auto-seal off, N openings" for a `follow --no-auto`, the wake line with the same note on every wake, the plan
check that refuses a phase raise while the perimeter is open."""
import copy
import json
import re

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, files, plan, schema, wake
from dfpilot.events import est_tokens

ROOT = fairplay.REPO


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _state(save, **ready):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 1, "age": 9000, "min_traps": 35},
                        "fail": ["open_perimeter"], "open": 2, "ents": ["55,62,117 floor", "61,55,117 floor"],
                        "pd": 12, "pw": "2 ways in"}, **ready)
    st["ready"] = {k: v for k, v in st["ready"].items() if v is not None}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    return st


def _hb(save, auto):
    import time
    files.write_follow_hb(save, {"v": 2, "wall": int(time.time()), "last_n": 0, "auto": auto})


# ---------------------------------------------------------------- the contract
def test_contract_fields():
    ev = lambda t, d: {"n": 1, "tick": 5, "type": t, "cls": "A", "msg": "m", "d": d}
    assert schema.validate("event", ev("PERIMETER_BROKEN", {"n": 1, "requeued": 1, "why": "replaced",
                                                            "replaced": ["O1"]})) == []
    assert schema.validate("event", ev("PERIMETER_BROKEN", {"n": 1, "requeued": 1, "replaced": "O1"})) != []
    assert schema.validate("event", ev("SIEGE_UNREADY", {"fails": ["open_perimeter"], "open": 2, "pd": 4,
                                                         "pw": "2 ways in"})) == []
    assert schema.validate("event", ev("SIEGE_UNREADY", {"pd": "4"})) != []
    assert "replaced" in schema.BRIDGE_STATES
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "'destroyed', 'replaced'" in lua and "pd = NAT, pw = str(60)" in lua


def test_state_ready_pd_pw(save):
    st = _state(save)
    assert st["ready"]["pd"] == 12
    bad = copy.deepcopy(st)
    bad["ready"]["pw"] = "w" * 61
    assert schema.validate("state", bad) != []
    bad = copy.deepcopy(st)
    bad["ready"]["pd"] = -1
    assert schema.validate("state", bad) != []
    ok = copy.deepcopy(st)
    ok["bridges"]["O1"] = "replaced"
    assert schema.validate("state", ok) == []


def test_config_keys_and_limits(tmp_path):
    shipped = json.loads((ROOT / "config" / "reflex.json").read_text(encoding="utf-8"))["perimeter"]
    seal = (ROOT / "lua" / "dfllm" / "seal.lua").read_text(encoding="utf-8")
    ready = (ROOT / "lua" / "dfllm" / "readiness.lua").read_text(encoding="utf-8")
    assert shipped == {"stop_after": int(re.search(r"\bstop_after = (\d+),", seal).group(1)),
                       "vanish_after": int(re.search(r"\bvanish_after = (\d+),", seal).group(1)),
                       "escalate_days": int(re.search(r"escalate_days = (\d+),", ready).group(1)),
                       "escalate_every": int(re.search(r"escalate_every = (\d+),", ready).group(1)),
                       "hold_pop": int(re.search(r"hold_pop = (\d+)}", ready).group(1))} \
        == {"stop_after": 2, "vanish_after": 3, "escalate_days": 2, "escalate_every": 5, "hold_pop": 30}
    lim = re.search(r"M\.PERIM_LIM = \{(.*?)\}\n", ready, re.S).group(1)
    for key, (lo, hi) in fairplay.PERIMETER_LIM.items():
        if key in ("stop_after", "vanish_after"):
            continue
        assert re.search(rf"{key} = \{{{lo}, {hi}\}}", lim), key
    assert "v >= 0 and v <= 20" in seal
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps({"v": 2, "perimeter": {"vanish_after": 21, "escalate_days": 31, "escalate_every": 0,
                                                   "hold_pop": 251}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for needle in ("perimeter.vanish_after: int 0..20", "perimeter.escalate_days: int 0..30",
                   "perimeter.escalate_every: int 1..30", "perimeter.hold_pop: int 0..250"):
        assert any(needle in e for e in errs), (needle, errs)
    p.write_text(json.dumps({"v": 2, "perimeter": shipped}), encoding="utf-8")
    assert fairplay.reflex_errors(p) == []


# ---------------------------------------------------------------- status and brief
def test_status_counts_the_days(save):
    _state(save)
    out = brief.status_text(save)
    line = out.splitlines()[1]
    assert line.startswith("SIEGE UNREADY (R0): open_perimeter | PERIMETER OPEN 12 days: 2 ways in | 2 ways in without "
                           "door or bridge"), line
    assert "close the open ways in" in line and "open perimeter: seal first" in line
    assert est_tokens(out) <= brief.STATUS_TOKENS
    _state(save, pd=1, pw="bridges lost: O1", open=0, ents=None)
    assert "PERIMETER OPEN 1 day: bridges lost: O1" in brief.status_text(save)
    _state(save, pd=None, pw=None, fail=["audit"])
    assert "PERIMETER OPEN" not in brief.status_text(save)


def test_status_says_auto_seal_off(save):
    """DECISIONS 2: follow --no-auto seals nothing (Run 13); status says "auto-seal off, N openings"."""
    _state(save)
    _hb(save, 0)
    line = brief.status_text(save).splitlines()[1]
    assert "AUTO-SEAL OFF, 2 openings" in line and "PERIMETER OPEN 12 days" in line, line
    _hb(save, 1)
    assert "AUTO-SEAL" not in brief.status_text(save).upper()
    import os
    import time
    _hb(save, 0)
    old = time.time() - 3600
    os.utime(save / files.FOLLOW_HB, (old, old))                                    # a stale beat says nothing
    assert "AUTO-SEAL" not in brief.status_text(save).upper()
    assert files.follow_auto(save) is None
    _hb(save, 0)
    _state(save, pd=None, pw=None, fail=["audit"], open=1, ents=["1,2,3 floor"])
    assert "auto-seal off, 1 opening" in brief.status_text(save)                       # without the perimeter signal too
    _state(save, pd=None, pw=None, fail=["audit"], open=0, ents=None)
    assert "auto-seal off" not in brief.status_text(save)
    assert files.auto_seal_off(save, 3) == "auto-seal off, 3 openings"
    assert files.auto_seal_off(save, 0) is None


def test_follow_heartbeat_carries_auto(save):
    (save / files.FOLLOW_HB).unlink()
    for auto, want in ((True, 1), (False, 0)):
        f = wake.Follower(save=save.name, out=lambda line: None, clock=lambda: 1000.0, auto=auto)
        f.poll()
        assert files.read_json(save / files.FOLLOW_HB)["auto"] == want
        (save / files.FOLLOW_HB).unlink()


# ---------------------------------------------------------------- wake
def test_wake_line_says_auto_seal_off_every_time(save):
    st = _state(save)
    e = {"n": 9, "tick": 5, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready (R0: open_perimeter)",
         "d": {"fails": ["open_perimeter"], "open": 2, "pd": 12, "pw": "2 ways in"}}
    burst = {"SIEGE_UNREADY": {"c": 1, "n0": 9, "e": e}}
    on = wake.wake_line(burst, st)
    off = wake.wake_line(burst, st, auto=False)
    assert "AUTO-SEAL OFF" not in on
    assert "AUTO-SEAL OFF, 2 openings (follow --no-auto)" in off and "seal by hand: dfllm cmd bp.place tpl=seal" in off
    assert est_tokens(off) <= wake.WAKE_TOKENS
    sealed = copy.deepcopy(st)
    sealed["ready"]["open"] = 0
    assert "AUTO-SEAL OFF" not in wake.wake_line(burst, sealed, auto=False)
    # the cadence keeps saying it: a second wake of the escalation repeats it
    assert "AUTO-SEAL OFF, 2 openings" in wake.wake_line(burst, st, auto=False)


def test_wake_hints_for_the_keeper():
    assert "quiet PEACE" in wake.NEXT["BRIDGE_DESTROYED"] and "wall + door" in wake.NEXT["BRIDGE_DESTROYED"]
    assert "bridge_rebuild" not in wake.NEXT["BRIDGE_DESTROYED"]
    assert "PERIMETER_BROKEN" in wake.NEXT and "nothing tactical" in wake.NEXT["PERIMETER_BROKEN"]


# ---------------------------------------------------------------- plan
def test_plan_check_refuses_a_phase_raise_while_the_perimeter_is_open(save):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    st = _state(save)
    st["phase"] = "P2"
    doc = copy.deepcopy(prev)                                         # phase_target P4
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev)
    mine = [e for e in errs if e.startswith("perimeter")]
    assert mine == ["perimeter: raising phase_target P2 -> P4 while the perimeter is open for 12 days (2 ways in; "
                    "readiness R0 open_perimeter): seal first (dfllm cmd bp.place tpl=seal site=S1 at=last; a lost "
                    "bridge: dfllm cmd inspect what=defense)"]
    st["phase"] = "P4"                                                # keeps the phase: a warning that counts the days
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev)
    assert not [e for e in errs if e.startswith("perimeter")]
    assert any(w.startswith("perimeter: open for 12 days") for w in warn), warn
    closed = _state(save, fail=["audit"], pd=None, pw=None)
    closed["phase"] = "P2"
    errs, warn = plan.check(doc, closed, decisions={}, banned=plan.BANNED, prev=prev)
    assert not [e for e in errs + warn if e.startswith("perimeter")]


# ---------------------------------------------------------------- BUG-049 on the Python side
def test_status_names_an_untrusted_refuge(save):
    """BUG-049 (Run 13 y525): state alert.ref.tr 0 / trw -> the status line says the refuge is not trusted and why."""
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["alert"] = {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1,
                   "ref": {"ex": 1, "sep": 1, "beds": 13, "need": 13, "tr": 0, "trw": "no hatch at 6,6,6"}}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "alert Kern+ 100t 5 in | refuge NOT TRUSTED: no hatch at 6,6,6" in brief.status_text(save)
    st["alert"]["ref"].update(tr=1)
    del st["alert"]["ref"]["trw"]
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "NOT TRUSTED" not in brief.status_text(save)
    bad = copy.deepcopy(st)
    bad["alert"]["ref"]["trw"] = "w" * 41
    assert schema.validate("state", bad) != []


def test_refuge_fail_carries_the_position():
    ev = {"n": 1, "tick": 5, "type": "REFUGE_FAIL", "cls": "A", "msg": "m",
          "d": {"burrow": "Tiefe+", "fallback": "Kern+", "why": "w", "hostile": 2, "at": [7, 6, 5]}}
    assert schema.validate("event", ev) == []
    assert schema.validate("event", dict(ev, d=dict(ev["d"], at=[7, 6]))) != []
    assert schema.validate("event", dict(ev, d=dict(ev["d"], hostile="2"))) != []
