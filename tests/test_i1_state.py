"""Integration audit I1 (state size, status ranking, token budgets): the combination of the merged packages.
- the status keeps the lockdown's cause (BUG-065) when the supply and pop lines are long (FR-74/76/77, BUG-059/062);
- a maximal fixture (a fort of 80, every optional field) stays within STATUS_TOKENS and BRIEF_TOKENS;
- the wake line puts PATIENT_DYING and MOOD_CRITICAL before YEAR_REVIEW and takes their hint.
The kernel side (K.view() is the complete document) is tests/lua/test_i1_state.lua."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, events, files, wake
from dfpilot.events import est_tokens

BY = {"id": 300, "race": "GREMLIN", "k": "inv", "pos": [110, 20, 91], "dc": 10, "de": 58, "hl": 1, "n": 1, "sz": 4000}
LOCK = {"defcon": 3, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:invader", "age": 5040, "lim": 12000,
        "qw": "near", "by": BY}


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


def busy_fort():
    """A reclaimed fort (FR-76) that lost a fifth of its peak (FR-74), with a dry hospital, forbidden stock, stress sources,
    coffins and idle hands (FR-77), under a lockdown held by a gremlin (BUG-065)."""
    return dict(
        mode="ALERT", alarm=LOCK, threat={"vis": 0, "armed": 0},
        pop={"cit": 50, "adults": 38, "soldiers": 8, "cap": 55, "gate_cap": 55},
        stock={"drink_d": 120, "food_d": 40, "meals": 10, "ore": 4, "bars": 3, "hungry": 3, "metal": "explore", "mshort": 1,
               "melt": 3, "dwhy": "no barrels free for the stills", "dforb": 3000, "fforb": 300,
               "mood_miss": ["Craftsdwarf", "Mason"]},
        care={"stressed_pct": 30, "naked": 1, "ghosts": 0, "corpses_old": 0, "tombs_free": 3, "moods": 0,
              "src": {"beds": 4, "drink": 3}, "died": {"starved": 1}, "tombs_locked": 3,
              "coffins": {"want": 5, "short": 3, "stock": 1, "order": 2, "proj": ""},
              "pop": {"kids": 6, "res": 2, "peak": 70, "dy": 14, "waves": 0, "mig": 0, "lastw": -1},
              "died_y": {"starved": 3, "killed": 9}},
        labor={"starving": 3, "idle": 40, "n": 38, "sold": 8, "held": 2, "why": {"rest": 3, "hurt": 1, "free": 5}},
        orders={"n": 20, "bad": 0, "stuck": 2, "stuck_ws": 2, "ws": "Craftsdwarf"},
        adopt={"ws": 20, "new": 5, "gone": 2, "rec": 1, "miss": ["Carpenters", "Mason", "Still"], "stock": 9, "wells": 2,
               "beds": 40, "doors": 50},
        water={"patients": 3, "thirst_max": 40000, "hosp_ok": 0, "refuge_ok": 1, "buckets_free": 3, "hosp": 2,
               "src": [[137, 77, 143]], "src_l": ["well 19098 in Kern+"]})


def test_the_status_keeps_the_lockdown_cause_under_a_long_supply_and_pop_line(save):
    put_state(save, **busy_fort())
    text = brief.status_text(save)
    assert est_tokens(text) <= brief.STATUS_TOKENS, text
    assert "cause inv 300 GREMLIN at 110,20,91" in text and "harmless" in text, text
    assert "pop 50 (38ad 8sol)" in text and "stock HUNGRY 3 drink 120d!" in text, text
    # the stock sentence is whole (not cut inside) and its causes stay
    assert "drink: no barrels free for the stills" in text and "3000 drink items forbidden" in text, text


def test_the_lockdown_line_goes_last_among_the_alarm_parts(save):
    st = busy_fort()
    st["alarm"] = dict(LOCK, unacked=2, doors=120, dwait=3, dout=3, rn=6, rleft=4, rto="Tiefe+", eta=400)
    st["clock"] = {"cap": 30, "orig": 100, "ts": -1, "held": 1, "why": "w" * 22}
    st["lever"] = {"lat_s": 4, "lat_t": 400, "pend": 2, "wait_s": 30}
    put_state(save, **st)
    text = brief.status_text(save)
    assert est_tokens(text) <= brief.STATUS_TOKENS
    assert "lockdown arrival:invader" in text and "cause inv 300 GREMLIN" in text, text
    # the full alarm line (the brief) still carries every part
    full = brief.line_alarm(brief.Ctx(save, full=False))
    for part in ("clock: held 30 t/s", "doors 120 forbidden", "recall: 4 of 6", "interrupts unacked", "eta ~400 t",
                 "lever_latency_s 4"):
        assert part in full, full


def maximal():
    st = busy_fort()
    st.update(
        mode="SIEGE", phase="P3", stale={"pop": 2400, "stock": 40320, "labor": 40320},
        alarm=dict(LOCK, defcon=1, unacked=2, eta=400, doors=120, dwait=3, dout=3, dref=1, far=2, rn=6, rleft=4, rnew=1,
                   rstuck=2, rto="Tiefe+", by=dict(BY, n=3, hl=0)),
        pop={"cit": 80, "adults": 60, "soldiers": 22, "cap": 100, "gate_cap": 80},
        ready={"lvl": 0, "worn": 40, "cv": 9, "drill_age": -1,
               "audit": {"ok": 0, "age": 3000, "min_traps": 0, "why": "x" * 70, "cov": "y" * 38},
               "fail": ["no_outer", "bridge:O1", "levers:O1", "no_kern", "no_refuge", "audit_old", "bypass", "office"],
               "open": 7, "ents": ["12,34,140 floor", "13,34,140 ramp", "14,35,141 stair"], "dhold": "z" * 20,
               "route": "z" * 58, "pd": 12, "pw": "w" * 58, "office": "o" * 190},
        clock={"cap": 30, "orig": 100, "ts": -1, "held": 1, "why": "w" * 22},
        lever={"lat_s": 4, "lat_t": 400, "pend": 2, "wait_s": 30},
        bridges={f"O{i}": "down" for i in range(1, 9)}, owners={"pause": "popup", "tempo": "inbox"},
        mil={"squads": 4, "soldiers": 22, "worn": 50, "cv": 10, "metal_pct": 30, "on_station": 15,
             "free": {k: 9 for k in ("weapon", "body", "head", "pants", "gloves", "shoes", "shield", "ammo")},
             "cap": {"sets": 10, "melee": 8, "want": 12, "xbow": 4}},
        trade={"caravan": 1, "ratio": 150, "done": 3},
        alert={"want": "w" * 22, "burrow": "b" * 22, "tiles": 2000, "inside": 70, "ok": 0, "why": "y" * 38,
               "ref": {"ex": 1, "sep": 0, "beds": 20, "need": 60, "tr": 0, "trw": "t" * 38}},
        wave={"ph": "intake", "n": 3, "why": "y" * 38, "so": "s" * 22, "deep": "destroyers,army,weak"},
        sched={"seal": {"proj": "c1a147c261", "n": 3, "paused": 2, "more": 2, "stuck": 1, "days": 9},
               "rb": {"pop": 2, "lo": 10, "paused": 4, "hi": 12},
               "q": {"n": 9, "by": [["c1a14869", "seal", 9], ["c1a1486a", "depot", 12]]},
               "run": {"d": 30, "i": 2, "n": 9, "task": "t" * 38, "sl": 900, "age": 30}, "pk": 3},
        proj=[[f"c1a1{i:02d}", f"s{i}.dig", 50, "b" * 38] for i in range(8)],
        snap={"q": 3, "old_s": 400, "done": 2, "drop": 0, "run": "c1a1a1", "p": "audit", "by": "follow", "pct": 40,
              "wait": "paced 3 min"})
    return st


def test_a_maximal_state_stays_within_the_status_and_brief_budgets_and_keeps_the_lockdown(save):
    put_state(save, **maximal())
    text = brief.status_text(save)
    assert est_tokens(text) <= brief.STATUS_TOKENS, est_tokens(text)
    assert "SIEGE UNREADY" in text.splitlines()[0] and "pop 80 (60ad 22sol)" in text and "stock HUNGRY 3" in text, text
    assert "cause inv 300 GREMLIN at 110,20,91" in text and "dangerous" in text, text
    big = brief.brief_text(save)
    assert est_tokens(big) <= brief.BRIEF_TOKENS


def test_fit_ranked_cuts_the_rank_2_lines_harder_before_one_goes_whole():
    lock = "lockdown " + "x " * 120
    unready = "UNREADY " + "y " * 200
    items = [(0, "HEAD"), (2, unready), (2, lock), (1, "pop " + "p " * 60), (1, "stock " + "s " * 60)]
    out = brief.fit_ranked(items, 250)
    assert "lockdown" in out and "UNREADY" in out and "pop p" in out and "stock s" in out
    assert est_tokens(out) <= 250


def burst(*evs):
    return {e["type"]: {"c": 1, "n0": e["n"], "e": e} for e in evs}


def A(n, typ, msg, d=None):
    return {"n": n, "tick": 5, "type": typ, "cls": "A", "msg": msg, "d": d or {}}


def test_wake_a_dying_patient_comes_before_the_housekeeping_types():
    state = {"t": {"y": 581, "tick": 1000}, "mode": "SIEGE"}
    pd = A(10, "PATIENT_DYING", "3 patients at thirst 61000 (2 carers, 6 wanted)",
           {"units": [1, 2, 3], "n": 3, "thirst": 61000, "carers": 2, "want": 6, "hosp": "ok"})
    mc = A(11, "MOOD_CRITICAL", "mood dwarf Urist thirst 52000", {"unit": 5, "why": "thirst"})
    ye = A(12, "YEAR_REVIEW", "year 581 review")
    pb = A(13, "PROJECT_BLOCKED", "project blocked")
    line = wake.wake_line(burst(ye, pb, mc, pd), state)
    assert est_tokens(line) <= wake.WAKE_TOKENS
    assert line.index("PATIENT_DYING") < line.index("MOOD_CRITICAL") < line.index("PROJECT_BLOCKED") < line.index("YEAR_REVIEW"), line
    assert "next: tell Gordon at once" in line and "dfllm plan propose" not in line, line
    # a lockdown or a siege still comes first
    br = A(14, "BREACH", "breach")
    assert wake.wake_line(burst(pd, br), state).index("BREACH") < wake.wake_line(burst(pd, br), state).index("PATIENT_DYING")
