"""BUG-132: the automatic (minimal, FR-86) plan raises one phase after a quiet year, and the pop ceiling follows Gordon's
D-01 = B answer (R0 cap 100) in plan propose/check, the kernel's no-plan default and the readiness R2 ceiling."""
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import FIX, FakeKern, append_events, ev, install_fake_bp, make_runtime, reset_paths

from dfpilot import files, plan, schema, wake

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "v2" / "runtime" / "region7"
YEAR = schema.TICKS["YEAR"]
TINFO = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
         for t in ("fortcore", "tombs", "temple", "bedrooms", "tavern", "hospital", "dining", "workshops")}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
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


def at_year(save, year, **kw):
    st = files.read_state(save)
    return put_state(save, t=dict(st["t"], y=year, abs=year * YEAR + st["t"]["tick"]), **kw)


def put_minimal(save, year, target="P3"):
    """An applied minimal plan (FR-86) of `year`: the fixture plan, tagged."""
    doc = json.loads((FIXTURE / "plan.json").read_text("utf-8"))
    doc.update(year=year, phase_target=target, notes=plan.MINIMAL_TAG + ": follow applied it after 2 years")
    files.write_json_atomic(save / "plan.json", doc)
    return doc


def phases():
    return json.loads((FIX / "phases.json").read_text("utf-8"))


def built(doc):
    return [b["tpl"] for se in doc["seasons"] for b in se["build"]]


# ================================================================ (b) the cap follows D-01
def test_the_plan_caps_follow_d01_b_and_mirror_the_kernel():
    lua = (ROOT / "lua" / "dfllm" / "readiness.lua").read_text("utf-8")
    caps = {int(k): int(v) for k, v in re.findall(r"\[(\d)\] = (\d+)", re.search(r"M\.CAPS = \{([^}]*)\}", lua).group(1))}
    assert plan.R_CAPS == caps                                          # one table, Python and Lua
    base = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    assert plan.R_CAPS[0] == base["baseline"]["popcap"]["max_pop"] == 100           # Gordon 2026-10-24: R0 cap 100
    assert [plan.level_cap(lvl, "B") for lvl in range(4)] == [100, 100, 100, 250]
    assert [plan.level_cap(lvl, "A") for lvl in range(4)] == [55, 55, 75, 75]       # option A keeps the old caps


def test_propose_at_r0_drafts_the_decided_ceiling():
    state = {"t": {"y": 3, "season": 0}, "phase": "P0", "ready": {"lvl": 0}, "pop": {"cit": 40}}
    for d01, option, ceiling in (("B", "B", 100), ("A", "A", 55)):        # the minimal plan said 55 with D-01 = B
        doc = plan.propose(state, None, None, decisions={"D-01": d01})
        assert doc["policy"]["option"] == option and doc["policy"]["pop_ceiling"] == ceiling, (d01, doc["policy"])
        errs, _ = plan.check(doc, state, decisions={"D-01": d01}, banned=[])
        assert not [e for e in errs if "pop_ceiling" in e], errs
        doc["policy"]["pop_ceiling"] = ceiling + 1
        errs, _ = plan.check(doc, state, decisions={"D-01": d01}, banned=[])
        assert any(f"R0 cap {ceiling}" in e for e in errs), errs


# ================================================================ (a) the minimal plan raises a phase
def test_a_quiet_year_raises_the_minimal_plan_one_phase(save):
    put_minimal(save, 5)
    state = at_year(save, 6)
    assert plan.raise_due(save, state, plan.applied_plan(save)) is True
    doc, errs, _ = plan.minimal_plan(save, state, phases(), tinfo=TINFO, decisions={}, tpls=list(TINFO))
    assert errs == [] and schema.validate("plan", doc) == []
    assert doc["phase_target"] == "P4"                                  # P3 -> P4, one phase
    assert "temple" in built(doc)                                       # the P4 builds propose drafts, not only the short list
    assert built(doc)[0] == "fortcore"                                  # stage 3 (the refuge) still first
    assert plan.is_minimal(doc) and "P3 -> P4" in doc["notes"]
    assert doc["policy"]["pop_ceiling"] == 100


def test_no_raise_before_a_year_after_a_siege_or_into_a_star_phase(save):
    put_minimal(save, 6)
    state = at_year(save, 6)
    assert plan.raise_due(save, state, plan.applied_plan(save)) is False          # the same year: not a year yet
    put_minimal(save, 5)
    append_events(save, [ev(90001, "SIEGE_START", "siege", {}, tick=6 * YEAR + 1000)])
    state = at_year(save, 6)
    assert plan.raise_due(save, state, plan.applied_plan(save)) is False          # a siege in the last year
    doc, errs, _ = plan.minimal_plan(save, state, phases(), tinfo=TINFO, decisions={}, tpls=list(TINFO))
    assert doc["phase_target"] == "P3" and "temple" not in built(doc)
    state = at_year(save, 7)
    assert plan.raise_due(save, state, plan.applied_plan(save)) is True           # a year after it
    state = at_year(save, 8, phase="P5")
    assert plan.raise_due(save, state, plan.applied_plan(save)) is True
    doc, errs, _ = plan.minimal_plan(save, state, phases(), tinfo=TINFO, decisions={}, tpls=list(TINFO))
    assert doc["phase_target"] == "P5"                                  # P6 is a star phase: never
    put_state(save, mode="SIEGE")
    assert plan.raise_due(save, files.read_state(save), plan.applied_plan(save)) is False
    (save / "plan.json").write_text(json.dumps(dict(json.loads((FIXTURE / "plan.json").read_text("utf-8")), year=5)))
    assert plan.raise_due(save, at_year(save, 8, mode="PEACE"), plan.applied_plan(save)) is False   # a player's plan


def test_a_raise_check_errors_on_applies_the_error_free_subset_and_names_the_errors(save, monkeypatch):
    install_fake_bp(monkeypatch)
    monkeypatch.setattr(plan, "load_phases", lambda path=None: phases())
    put_minimal(save, 5)
    at_year(save, 6)
    real = plan.check

    def fake_check(doc, st, **kw):
        errs, warn = real(doc, st, **kw)
        if "temple" in built(doc):
            errs = errs + ["stress: the temple site is under water (x)"]
        return errs, warn
    monkeypatch.setattr(plan, "check", fake_check)
    with FakeKern(save, lambda d: (True, "plan y6 loaded", {"year": 6})):
        errs, msg = plan.apply_minimal(save, by="follow", wait_s=5)
    assert errs == [] and "plan.reload" in msg
    assert "1 ERROR held back" in msg and "temple site is under water" in msg, msg
    written = json.loads((save / "plan.json").read_text("utf-8"))
    assert written["phase_target"] == "P4" and "temple" not in built(written) and "tombs" in built(written)
    assert plan.is_minimal(written)


def test_a_raise_check_refuses_keeps_the_phase_and_still_applies_the_minimal_plan(save, monkeypatch):
    install_fake_bp(monkeypatch)
    monkeypatch.setattr(plan, "load_phases", lambda path=None: phases())
    put_minimal(save, 5)
    at_year(save, 6)
    real = plan.check

    def fake_check(doc, st, **kw):
        errs, warn = real(doc, st, **kw)
        if doc["phase_target"] > "P3":
            errs = errs + ["perimeter: raising phase_target P3 -> P4 while the perimeter is open"]
        return errs, warn
    monkeypatch.setattr(plan, "check", fake_check)
    with FakeKern(save, lambda d: (True, "plan y6 loaded", {"year": 6})):
        errs, msg = plan.apply_minimal(save, by="follow", wait_s=5)
    assert errs == [] and "1 ERROR held back" in msg and "perimeter" in msg, msg
    written = json.loads((save / "plan.json").read_text("utf-8"))
    assert written["phase_target"] == "P3" and built(written) == ["fortcore", "tombs"]


# ---------------------------------------------------------------- follow raises it after one quiet year
class Clock:
    def __init__(self, t=2_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def test_follow_raises_the_minimal_plan_after_one_quiet_year(save, monkeypatch):
    calls = []
    monkeypatch.setattr(plan, "apply_minimal", lambda save_dir, by="follow", wait_s=5.0:
                        (calls.append(by), ([], "plan.json y4 + 2 bp; P3 -> P4"))[1])
    put_minimal(save, 3)
    at_year(save, 4)
    c, out = Clock(), []
    f = wake.Follower(out=out.append, clock=c)
    f.poll()
    assert calls == ["follow"] and f.plan_auto == {"tried_y": 4, "applied_y": 4}
    c.t += 11
    f.poll()
    assert any("PLAN_AUTO" in x and "quiet year" in x for x in out), out
    c.t += 301
    f.poll()
    assert calls == ["follow"], "once per game year"
    put_minimal(save, 4, target="P4")                                  # what the raise wrote
    append_events(save, [ev(90002, "BREACH", "breach", {}, tick=5 * YEAR + 1000)])
    at_year(save, 5)
    c.t += 301
    f.poll()
    assert calls == ["follow"], "a breach in the last year: no raise"
