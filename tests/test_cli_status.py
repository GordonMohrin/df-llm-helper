"""WP2 status (<= 300 tokens), brief (<= 1.5k), events and doctor on the fixture runtime."""
import json
import os
import time

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from df_llm_helper import brief, doctor, files, schema
from df_llm_helper.cli import main
from df_llm_helper.events import clip, est_tokens, fmt_tick, fmt_ticks


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def run(save, *argv):
    return main(["--runtime", str(save.parent), *argv])


# ---------------------------------------------------------------- helpers
def test_time_and_tokens():
    assert fmt_tick(3 * 403200 + 123456) == "y3 sum d19" and fmt_tick(0) == "y0 spr d1" and fmt_tick(None) == "?"
    assert fmt_tick(403199) == "y0 win d84"
    assert (fmt_ticks(450), fmt_ticks(40000), fmt_ticks(806400), fmt_ticks(-1)) == ("450t", "33d", "2.0y", "never")
    assert est_tokens("") == 0 and est_tokens("one two three") >= 3
    s = clip("x" * 1000, 50)
    assert est_tokens(s) <= 50 and s.endswith("~")


# ---------------------------------------------------------------- status
def test_status_fixture(save, capsys):
    assert run(save, "status") == 0
    out = capsys.readouterr().out
    assert est_tokens(out) <= brief.STATUS_TOKENS
    for frag in ("region7 y3 sum d19 PEACE(29d) P3 462t/s run", "R1 fail:traps<30", "drink 150d!", "water ok",
                 "bridges B1 down B2 down O1 down", "BLOCKED:no_material", "slow:runner", "last A #8804"):
        assert frag in out, frag


def test_status_no_state(save, capsys):
    for slot in "ab":
        (save / f"state.{slot}.json").write_text("{", encoding="utf-8")
    assert run(save, "status") == 0
    out = capsys.readouterr().out
    assert "no valid state" in out and "parse" in out and "PEACE" in out      # mode from the heartbeat


def test_status_holds_and_caravan(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["owners"] = {"pause": "gordon", "tempo": "inbox"}
    st["trade"]["caravan"] = 1
    st["t"]["paused"] = True
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "paused pause:gordon tempo:inbox" in out and "CARAVAN on map" in out


def test_status_worst_case_budget(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["seq"] = 999
    st["ready"]["fail"] = ["x" * 24] * 8
    st["proj"] = [["p" * 40, "s" * 24, 99, "b" * 40]] * 8
    st["k"].update(slow=["economy", "runner", "care", "snapshot"], disabled=["trade", "baseline"])
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS


# ---------------------------------------------------------------- brief
def test_brief_fixture(save, capsys):
    assert run(save, "brief") == 0
    out = capsys.readouterr().out
    assert est_tokens(out) <= brief.BRIEF_TOKENS
    for frag in ("## plan", "plan y3 target P4", "s1*: bedrooms@S1", "OPEN D-07", "## class A, newest first",
                 "SIEGE_END 41 hostiles", "cmd c19a40011aa2 lever failed", "STOCK_LOW x2", "MOOD_NEED x1"):
        assert frag in out, frag
    assert out.index("#8804") < out.index("#8773")                         # newest A first


def test_brief_answered_decision_hidden(save, tmp_path):
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / "decisions.yaml").write_text("D-07: unchanged  # Gordon 10.10.\n", encoding="utf-8")
    assert "OPEN D-07" not in brief.brief_text(save)


def test_brief_open_decision_with_shipped_config(save, tmp_path):
    """config/decisions.yaml lists all 13 ids with 'default' comments: unanswered ones stay open."""
    from cli_v2_helpers import ROOT
    cfg = tmp_path / "config"
    cfg.mkdir(exist_ok=True)
    shipped = (ROOT / "config" / "decisions.yaml").read_text("utf-8")
    assert "D-07:" in shipped
    (cfg / "decisions.yaml").write_text(shipped, encoding="utf-8")
    assert "OPEN D-07: set visitor_cap 30 (speed)?" in brief.brief_text(save)
    (cfg / "decisions.yaml").write_text(shipped.replace("D-07: unchanged  # default", "D-07: visitor30  # Gordon"),
                                        encoding="utf-8")
    assert "OPEN D-07" not in brief.brief_text(save)


def test_brief_sections_survive_a_flood_of_c_events(save, capsys):
    t0 = 3 * 403200 + 123500
    evs = [ev(8813, "DECISION_NEEDED", "D-10?", {"id": "D-10", "q": "allow emigration?"}, tick=t0),
           ev(8814, "SIEGE_END", "9 hostiles, 9 killed", {"hostiles": 9}, tick=t0 + 10),
           ev(8815, "CMD", "audit failed", {"id": "c42", "verb": "audit", "ok": 0}, tick=t0 + 20),
           ev(8816, "MOOD_NEED", "needs cloth", {"unit": 7, "need": "cloth"}, tick=t0 + 30)]
    evs += [ev(8817 + i, "SIEGE_STATUS", f"{i} vis", {"vis": i}, tick=t0 + 40 + i) for i in range(2000)]
    append_events(save, evs)
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["t"].update(tick=st["t"]["tick"] + 3000, abs=st["t"]["abs"] + 3000)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    text = brief.brief_text(save)
    assert est_tokens(text) <= brief.BRIEF_TOKENS
    for frag in ("OPEN D-10: allow emigration?", "OPEN D-07", "#8814", "SIEGE_END 9 hostiles", "#8804",
                 "cmd c42 audit failed", "cmd c19a40011aa2 lever failed", "MOOD_NEED x2", "STOCK_LOW x2"):
        assert frag in text, frag
    assert run(save, "status") == 0
    out = capsys.readouterr().out
    assert "PEACE(31d)" in out and "last A #8814 SIEGE_END" in out


def test_brief_budget_with_huge_history(save):
    types_ = [t for t, (c, _, _) in schema.EVENTS.items() if c in "AB"]
    evs = []
    for i in range(1500):
        t = types_[i % len(types_)]
        d = {"id": "D-07", "q": "q", "key": "drink_d", "proj": "p", "module": "m", "tpl": "tombs", "cap": 55,
             "on": 1, "fn": "f", "why": "w", "bridge": "B1"}
        evs.append(ev(8813 + i, t, f"event {i} " + "ü" * 120, d, tick=3 * 403200 + 123000 + i))
    append_events(save, evs)
    text = brief.brief_text(save)
    assert est_tokens(text) <= brief.BRIEF_TOKENS and text.startswith("# brief region7")
    small = brief.brief_text(save, budget=200)
    assert est_tokens(small) <= 200 and small.startswith("# brief region7")


def test_brief_no_plan(save):
    (save / "plan.json").unlink()
    assert "plan: none applied (dfllm plan propose)" in brief.brief_text(save)


# ---------------------------------------------------------------- events
def test_events_cli(save, capsys):
    assert run(save, "events", "--cls", "A") == 0
    lines = capsys.readouterr().out.strip().splitlines()
    assert [ln.split()[0] for ln in lines] == ["#8659", "#8773", "#8795", "#8804"]
    assert run(save, "events", "--since", "8800", "--type", "CMD,ACT_FAIL", "--json") == 0
    docs = [json.loads(x) for x in capsys.readouterr().out.strip().splitlines()]
    assert [d["type"] for d in docs] == ["ACT_FAIL"] and all(schema.validate("event", d) == [] for d in docs)
    assert run(save, "events", "--since", "9999") == 0
    assert "no events" in capsys.readouterr().out
    assert run(save, "events", "--limit", "3") == 0
    assert [ln.split()[0] for ln in capsys.readouterr().out.strip().splitlines()] == ["#8810", "#8811", "#8812"]


# ---------------------------------------------------------------- doctor
def test_doctor_fixture_flags_gap(save, capsys):
    assert run(save, "doctor") == 1
    out = capsys.readouterr().out
    for frag in ("ACTIVE=yes", "state seq 812 slot b", "PEACE 464", "modules ms/s: runner 4.3", "gaps > 3 s: 1",
                 "KERNEL_SLOW", "1 problem(s)"):
        assert frag in out, frag


def test_doctor_ok_and_problems(save):
    lines = (save / "perf.csv").read_text("utf-8").splitlines()
    good = [lines[0]] + [ln.replace(",3600,1,", ",420,0,").replace(",310,", ",460,") for ln in lines[1:]]
    (save / "perf.csv").write_text("\n".join(good) + "\n", encoding="utf-8")
    assert doctor.diagnose(save)[1] == []
    old = time.time() - 600
    os.utime(save / "heartbeat", (old, old))
    (save / "inbox").mkdir()
    files.write_json_atomic(save / "inbox" / "0000000000001-c1.json", {"id": "c1"})
    os.utime(save / "inbox" / "0000000000001-c1.json", (old, old))
    slow = [lines[0]] + [ln.replace(",PEACE,4", ",PEACE,2") for ln in good[1:]]
    (save / "perf.csv").write_text("\n".join(slow) + "\n", encoding="utf-8")
    bad = " ".join(doctor.diagnose(save)[1])
    assert "heartbeat 10m old" in bad and "inbox file" in bad and "PEACE median" in bad


def test_main_without_save(tmp_path, capsys):
    try:
        assert main(["--runtime", str(tmp_path / "none"), "status"]) == 2
        assert "no save" in capsys.readouterr().out
    finally:
        reset_paths()
