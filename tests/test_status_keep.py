"""BUG-071 (Run 13: status showed only the clock line after a year change or a hang) on the reader side: status keeps the
pop and stock lines when other lines are long (the 300-token fit dropped them from the end), and says how old a kept
value is. The kernel side (carry, stale, the 4 KB order) is tests/lua/test_kern_gaps.lua."""
import re
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, events, fairplay, files

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **extra):
    st = files.read_state(save)
    st.update(extra)
    # write both slots with a higher seq so the reader takes it
    st["seq"] = st["seq"] + 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


LONG_READY = {"lvl": 0, "worn": 0, "cv": 0, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0,
                                                                     "why": "x" * 70, "cov": "y" * 38},
              "fail": ["no_outer", "no_inner", "bridge:O1", "levers:O1", "no_kern", "no_refuge", "audit_old", "bypass"],
              "open": 7, "ents": ["12,34,140 floor", "13,34,140 ramp", "14,35,141 stair"], "route": "z" * 58}


def test_status_keeps_pop_and_stock_when_unready_and_alarm_lines_are_long(save):
    put_state(save, ready=LONG_READY,
              alarm={"defcon": 3, "unacked": 2, "last": 99, "ack": 90, "lock": 1, "why": "lone thief", "eta": 400,
                     "doors": 12, "dwait": 3, "dout": 2, "dref": 1, "far": 2, "rn": 6, "rleft": 4, "rnew": 1, "rstuck": 2,
                     "rto": "Tiefe+"},
              pop={"cit": 36, "adults": 30, "soldiers": 6, "cap": 55, "gate_cap": 55},
              stock={"drink_d": 190, "food_d": 70, "meals": 14})
    text = brief.status_text(save)
    assert "SIEGE UNREADY" in text, text
    assert "pop 36 (30ad 6sol)" in text, text
    assert "stock drink 190d food 70d" in text, text
    assert events.est_tokens(text) <= brief.STATUS_TOKENS + 2


def test_status_drops_the_least_important_lines_first(save):
    put_state(save, ready=LONG_READY, pop={"cit": 36, "adults": 30, "soldiers": 6, "cap": 55, "gate_cap": 55},
              stock={"drink_d": 190, "food_d": 70, "meals": 14},
              snap={"q": 3, "old_s": 400, "done": 2, "drop": 0, "run": "c1a1", "p": "audit", "by": "follow", "pct": 40})
    short = brief.fit_ranked([(0, "HEAD"), (1, "pop " + "p" * 400), (3, "low " + "l" * 800), (2, "mid " + "m" * 300)], 150)
    assert short.startswith("HEAD") and "pop p" in short and "low l" not in short


def test_a_value_from_the_kernel_carry_says_how_old_it_is(save):
    put_state(save, pop={"cit": 36, "adults": 30, "soldiers": 6, "cap": 55, "gate_cap": 55},
              stock={"drink_d": 190, "food_d": 70, "meals": 14}, labor={"starving": 0, "idle": 40},
              stale={"pop": 2400, "stock": 40320, "labor": 40320})
    text = brief.status_text(save)
    assert re.search(r"pop 36 \(30ad 6sol\) cap 55 gate 55 \(last known 2d ago\)", text), text
    assert re.search(r"stock drink 190d food 70d meals 14.*\(last known 33d ago\)", text), text
    assert "idle 40%" in text


def test_the_idle_clause_names_the_classes(save):
    put_state(save, labor={"starving": 0, "idle": 54, "n": 13, "sold": 6, "held": 2,
                           "why": {"rest": 2, "hurt": 1, "mood": 1, "free": 3}})
    text = brief.status_text(save)
    assert ("idle 54% = 7 of 13 adults (rest 2, hurt 1, mood 1, no job 3; 6 soldiers not counted; the kernel holds 2 "
            "projects: dfllm cmd inspect what=workload splits the rest)") in text, text
    # an older kernel's labor (no breakdown) reads as before
    put_state(save, labor={"starving": 0, "idle": 20})
    assert "idle 20% starving 0" in brief.status_text(save)


def test_perf_config_mirrors_kern_lua():
    src = (ROOT / "lua" / "dfllm" / "kern.lua").read_text(encoding="utf-8")
    m = re.search(r"M\.PERF = \{quiet_s = \{(\d+), (\d+), (\d+)\}, carry_days = \{(\d+), (\d+), (\d+)\}\}", src)
    q, c = tuple(map(int, m.groups()[:3])), tuple(map(int, m.groups()[3:]))
    assert (q[1], q[2]) == fairplay.PERF_LIM["quiet_s"] and (c[1], c[2]) == fairplay.PERF_LIM["carry_days"]
    import json
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["perf"] == {"quiet_s": q[0], "carry_days": c[0]}


def test_perf_errors(tmp_path):
    import json
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "perf": {"quiet_s": 9000, "carry_days": "x", "bogus": 1}}))
    errs = fairplay.perf_errors(p)
    assert any("perf.quiet_s" in e for e in errs) and any("perf.carry_days" in e for e in errs)
    assert any("perf.bogus: unknown key" in e for e in errs)
    assert fairplay.perf_errors() == [] and fairplay.perf_errors(tmp_path / "none.json") == []
