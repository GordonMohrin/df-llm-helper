"""WP2 status (<= 300 tokens), brief (<= 1.5k), events and doctor on the fixture runtime."""
import json
import os
import time

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import brief, doctor, files, schema
from dfpilot.cli import main
from dfpilot.events import clip, est_tokens, fmt_tick, fmt_ticks


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
                 "bridges B1 down B2 down O1 down", "BLOCKED:no_material", "slow:runner", "last A #8804",
                 "clock: free (cap 500, timestream 500)", "lever_latency_s 11 (297 t)"):
        assert frag in out, frag
    assert out.startswith("DEFCON 5 | region7"), out.splitlines()[0]     # FR-53: line 1 starts with DEFCON


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


def test_status_alert_burrow(save):
    """FR-33/37: status prints the alert burrow, its size and the citizens inside; a refusal says why."""
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["alert"] = {"want": "Kern+", "burrow": "Kern+", "tiles": 812, "inside": 30, "ok": 1, "why": ""}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "alert Kern+ 812t 30 in" in brief.status_text(save)
    st["alert"] = {"want": "Kern+", "burrow": "Innen+", "tiles": 5800, "inside": 31, "ok": 0,
                   "why": "Kern+: 4 tiles<33, drink 0<33"}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "alert Innen+ 5800t 31 in (Kern+ refused: Kern+: 4 tiles<33, drink 0<33)" in out
    st["alert"] = {"want": "Tiefe+", "burrow": "", "tiles": 0, "inside": 0, "ok": 0}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "alert no confinement (whole fort) (Tiefe+ refused)" in brief.status_text(save)
    st["alert"]["extra"] = 1
    assert schema.validate("state", st) != []


def test_status_intake_wave_and_sortie(save):
    """Gordon 2026-10-16: the intake phase, the waves so far, the last refusal and a sortie stand in the status."""
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mode"] = "SIEGE"
    st["wave"] = {"ph": "fight", "n": 3, "so": "A recall"}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "intake fight (waves 3), sortie A recall" in brief.status_text(save)
    st["wave"] = {"ph": "idle", "n": 0, "why": "worn 40% < 80%"}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "intake idle (waves 0): worn 40% < 80%" in brief.status_text(save)
    st["wave"]["ph"] = "x" * 9
    assert schema.validate("state", st) != []


def test_status_destroyed_bridges_and_deep_defense(save):
    """BUG-030: a destroyed bridge stands out in the bridges line; the deep defense in the intake line."""
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mode"] = "SIEGE"
    st["bridges"] = {"O1": "destroyed", "B1": "up", "B2": "down"}
    st["wave"] = {"ph": "idle", "n": 0, "why": "deep defense (destroyers): the squads", "deep": "destroyers,army"}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "bridges B1 up B2 down O1 DESTROYED" in out
    assert "DEEP destroyers,army: civilians in the refuge, squads in the core" in out
    st["bridges"]["O1"] = "gone"
    assert schema.validate("state", st) != []


def test_status_worst_case_budget(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["seq"] = 999
    st["wave"] = {"ph": "w" * 8, "n": 99, "why": "y" * 40, "so": "s" * 24, "deep": "d" * 24}
    st["bridges"] = {"O1": "destroyed", "B1": "destroyed", "B2": "destroyed"}
    st["ready"]["fail"] = ["x" * 24] * 8
    st["proj"] = [["p" * 40, "s" * 24, 99, "b" * 40]] * 8
    st["k"].update(slow=["economy", "runner", "care", "snapshot"], disabled=["trade", "baseline"])
    st["alert"] = {"want": "w" * 24, "burrow": "b" * 24, "tiles": 99999, "inside": 250, "ok": 0, "why": "y" * 40}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS


def _r0_state(save, **ready):
    """FR-65: the fixture state at R0 (Run 9/10: fails for the whole session, no audit, no drill)."""
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0},
                        "fail": ["audit", "no_inner", "no_outer"], "open": 2,
                        "ents": ["55,62,117 stair_updown", "61,55,117 floor"], "dhold": "no bridges"}, **ready)
    st["ready"] = {k: v for k, v in st["ready"].items() if v is not None}     # None: leave the optional key out
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


def test_status_r0_is_loud_never_plain_peace(save):
    """FR-65: R0 marks the mode UNREADY, the 2nd line lists blockers, open ways in, traps and the next step; the
    drill and audit say how to run them (`drill never`, `audit never` for the whole Run 10 fort)."""
    _r0_state(save)
    out = brief.status_text(save)
    lines = out.splitlines()
    assert "PEACE(29d) UNREADY P3" in lines[0] and lines[0].startswith("DEFCON 5 | region7")
    assert lines[1] == ("SIEGE UNREADY (R0): audit,no_inner,no_outer | 2 ways in without door or bridge: "
                        "55,62,117 stair_updown, 61,55,117 floor | traps ? (no audit) | next: dfllm audit; close the "
                        "open ways in (dfllm cmd bp.place tpl=seal site=S1 at=last); build the missing fortcore "
                        "pieces (plan)")
    assert "R0 UNREADY worn 0% cv 3 drill never (auto: no bridges; run dfllm cmd drill) audit never (run dfllm audit)" \
        in out
    assert "fail:audit" not in out                             # the blockers stand once, in the UNREADY line
    assert est_tokens(out) <= brief.STATUS_TOKENS
    assert "SIEGE UNREADY (R0)" in brief.brief_text(save)


def test_status_r0_variants_and_worst_case(save):
    _r0_state(save, open=-1, ents=None, dhold=None, fail=["audit_fail", "bypass", "refuge_sep", "civ_sep"],
              audit={"ok": 0, "age": 9000, "min_traps": 4})
    out = brief.status_text(save)
    assert ("SIEGE UNREADY (R0): audit_fail,bypass,refuge_sep,civ_sep | ways in: not checked yet | traps 4 "
            "(counted as if the bypass were walled)") in out          # Run 9/10: traps 0 beside an armed hall
    assert "next:" not in out.splitlines()[1]
    _r0_state(save, open=-1, ents=None, dhold=None, fail=["bypass"], audit={"ok": 0, "age": 9000, "min_traps": 0})
    assert "| traps 0 (a bypass skips the hall)" in brief.status_text(save)
    _r0_state(save, open=-1, ents=None, dhold=None, fail=["audit_fail", "bypass", "refuge_sep", "civ_sep"],
              audit={"ok": 0, "age": 9000, "min_traps": 4})
    assert "drill never (run dfllm cmd drill) audit FAIL 7d traps 4" in out
    _r0_state(save, open=0, ents=None)
    assert "ways in: all with a door or bridge" in brief.status_text(save)
    _r0_state(save, open=9, fail=["x" * 24] * 8, ents=["y" * 24] * 3, dhold="z" * 24)
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["proj"] = [["p" * 40, "s" * 24, 99, "b" * 40]] * 8
    st["k"].update(slow=["economy", "runner", "care", "snapshot"], disabled=["trade", "baseline"])
    st["alert"] = {"want": "w" * 24, "burrow": "b" * 24, "tiles": 99999, "inside": 250, "ok": 0, "why": "y" * 40}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert est_tokens(out) <= brief.STATUS_TOKENS and "SIEGE UNREADY (R0)" in out.splitlines()[1]
    for bad in ({"open": -2}, {"ents": ["e"] * 4}, {"dhold": "h" * 25}):
        st2 = json.loads(files.dumps(st))
        st2["ready"].update(bad)
        assert schema.validate("state", st2) != [], bad


def test_status_names_the_stop_guard(save):
    """FR-68: `dfllm stop` in a siege leaves the guard (FPS cap held, popups dismissed); status says so on line 2."""
    now = int(time.time())
    g = {"v": 2, "on": 1, "mode": "SIEGE", "cap": 30, "ts_off": 1, "why": "popup", "since": now - 180, "wall": now - 2,
         "n": 4, "kinds": {"death": 3, "migrants": 1}, "last": "Urist has been found dead, dehydrated."}
    files.write_json_atomic(save / "guard.json", g)
    out = brief.status_text(save)
    line = out.splitlines()[1]
    assert line.startswith("GUARD: kernel stopped in SIEGE 3m ago; dfllm-guard holds FPS cap 30, timestream off, "
                           "dismissed 4 popups (death 3, migrants 1; last: Urist has been found dead, dehydrated.)")
    assert "dfhack-run dfllm boot resumes the kernel" in line and "dfllm restore releases the clock" in line
    assert est_tokens(out) <= brief.STATUS_TOKENS and "GUARD: kernel stopped" in brief.brief_text(save)
    files.write_json_atomic(save / "guard.json", dict(g, wall=now - 3 * 3600))
    assert "GUARD last seen 3h ago (DF closed or crashed?): the FPS cap may still be 30" in brief.status_text(save)
    files.write_json_atomic(save / "guard.json", dict(g, on=0, why="boot"))
    assert "GUARD" not in brief.status_text(save)
    files.write_json_atomic(save / "guard.json", dict(g, on=True))
    assert "GUARD" not in brief.status_text(save) and files.read_guard(save) == (None, None)


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
    assert est_tokens(text) <= brief.BRIEF_TOKENS and text.startswith("# brief DEFCON 5 | region7")
    small = brief.brief_text(save, budget=200)
    assert est_tokens(small) <= 200 and small.startswith("# brief DEFCON 5 | region7")


def test_brief_no_plan(save):
    (save / "plan.json").unlink()
    assert "plan: none applied (dfllm plan propose)" in brief.brief_text(save)


# ---------------------------------------------------------------- events
def test_events_cli(save, capsys):
    assert run(save, "events", "--cls", "A") == 0
    lines = capsys.readouterr().out.strip().splitlines()
    assert [ln.split()[0] for ln in lines] == ["#8659", "#8735", "#8736", "#8773", "#8795", "#8804"]
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


# ---------------------------------------------------------------- FR-51/53/55/58: clock, lockdown, interrupts
def test_status_shows_the_clock_clamp_defcon_lever_latency_and_eta(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mode"] = "SIEGE"
    st["clock"] = {"cap": 30, "orig": 500, "ts": -1, "held": 1, "why": "siege"}
    st["owners"]["tempo"] = "clock"
    st["alarm"] = {"defcon": 2, "unacked": 1, "last": 8830, "ack": 8820, "lock": 1, "why": "arrival:siege", "eta": 420,
                   "doors": 1, "dwait": 1, "dout": 2}
    st["lever"] = {"lat_s": -1, "lat_t": -1, "pend": 2, "wait_s": 45}
    st["t"]["tps"] = 30
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    line1 = out.splitlines()[0]
    assert line1.startswith("DEFCON 2 | region7") and "SIEGE" in line1
    for frag in ("clock: held 30 t/s, reason siege", "lockdown arrival:siege",
                 "doors 1 forbidden, 1 waiting for 2 citizens outside",
                 "1 interrupts unacked (last #8830, acked #8820): dfllm ack", "eta ~420 t (~14 s)",
                 "lever_latency_s -, 2 pulls pending 45 s"):
        assert frag in out, frag
    assert est_tokens(out) <= brief.STATUS_TOKENS


def test_status_clock_lowered_by_the_mode_alone(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mode"] = "ALERT"
    st["clock"] = {"cap": 100, "orig": 500, "ts": -1, "held": 0, "why": "alert"}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "clock: held 100 t/s, reason alert" in brief.status_text(save)


def test_status_without_the_reflex_module_says_defcon_unknown(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    for k in ("alarm", "clock", "lever"):
        del st[k]
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert out.startswith("DEFCON ? | region7") and "clock:" not in out


def test_state_rejects_bad_alarm_clock_lever():
    st = json.loads((make_runtime.__globals__["RUNTIME"] / "region7" / "state.b.json").read_text("utf-8"))
    for key, bad, needle in (("alarm", {"defcon": 0, "unacked": 0, "last": 0, "ack": 0, "lock": 0, "why": ""}, "0 < 1"),
                             ("clock", {"cap": 30, "orig": 500, "ts": -2, "held": 0, "why": ""}, "-2 < -1"),
                             ("lever", {"lat_s": -1, "lat_t": -1, "pend": -1, "wait_s": 0}, "-1 < 0"),
                             ("owners", {"pause": None, "tempo": "turbo"}, "not in")):
        d = dict(st, **{key: bad})
        errs = schema.validate("state", d)
        assert any(needle in e for e in errs), (key, errs)
        pruned, _ = schema.prune_state(d)
        assert pruned is not None and key not in pruned


# ---------------------------------------------------------------- FR-29, FR-39, FR-01, FR-46
def test_follow_off_in_status_and_doctor(save, capsys):
    """FR-29: a follow that does not beat is said loudly in status and is a doctor problem while DF runs."""
    assert files.follow_off(save) is None
    old = time.time() - 3 * 3600
    os.utime(save / files.FOLLOW_HB, (old, old))
    assert run(save, "status") == 0
    out = capsys.readouterr().out
    assert "follow: OFF (last heartbeat 3h ago)" in out
    assert any("follow: OFF" in b for b in doctor.diagnose(save)[1])
    assert "follow: OFF (last heartbeat 3h ago)" in brief.brief_text(save)
    (save / files.FOLLOW_HB).unlink()
    assert "follow: OFF (no heartbeat yet" in brief.status_text(save)


def test_follow_off_not_a_problem_without_df(save):
    (save / files.FOLLOW_HB).unlink()
    (save.parent / "ACTIVE").unlink()
    lines, bad = doctor.diagnose(save)
    assert not any("follow" in b for b in bad)
    assert any("follow: OFF" in x and "DF not running" in x for x in lines)


def test_follow_writes_its_heartbeat(save):
    from dfpilot import wake
    (save / files.FOLLOW_HB).unlink()
    t = [1000.0]
    f = wake.Follower(save=save.name, out=lambda line: None, clock=lambda: t[0])
    f.poll()
    doc, age = files.read_follow_hb(save)
    assert doc["v"] == 2 and doc["wall"] == 1000 and age is not None and age < 5
    mt = (save / files.FOLLOW_HB).stat().st_mtime
    t[0] += 3
    f.poll()
    assert (save / files.FOLLOW_HB).stat().st_mtime == mt, "beats every 10 s, not every poll"
    t[0] += 10
    f.poll()
    assert files.read_json(save / files.FOLLOW_HB)["wall"] == 1013


def test_status_orders_and_free_metal(save):
    """FR-01/FR-39 orders line, FR-46 free metal by category; doctor flags orders without item_subtype."""
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["orders"] = {"n": 42, "bad": 1, "stuck": 3}
    st["mil"]["free"] = {"weapon": 4, "body": 2, "shield": 0}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "orders 42 stuck 3 UNSAFE 1" in out
    assert "free metal body 2 weapon 4" in out
    assert any("item_subtype" in b for b in doctor.diagnose(save)[1])
    st["orders"]["bad"] = 0
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert not any("item_subtype" in b for b in doctor.diagnose(save)[1])


def test_status_r0_refuge_dry_names_the_drink(save):
    """Run 11 (siege 8: Tiefe+ had no drink): the R0 blocker refuge_dry names its fix in the UNREADY line."""
    _r0_state(save, open=0, ents=None, fail=["refuge_dry"], audit={"ok": 1, "age": 9000, "min_traps": 35})
    line = brief.status_text(save).splitlines()[1]
    assert line.startswith("SIEGE UNREADY (R0): refuge_dry") and \
        "next: the refuge has no drink: a well/cistern there or a drink stockpile in it (plan)" in line, line


def test_status_r0_names_the_audit_route_and_the_seal(save):
    """Run 10: `bypass` stood in the R0 line for months without saying where or what to build. The state's
    ready.route (readiness: the last audit's first route finding) and the seal that walls it stand in line 2."""
    _r0_state(save, open=0, ents=None, fail=["audit_fail", "bypass", "refuge_sep"],
              audit={"ok": 0, "age": 9000, "min_traps": 35}, route="bypass: wall 100,127,122 floor -> 139,128,117")
    line = brief.status_text(save).splitlines()[1]
    assert ("traps 35 (counted as if the bypass were walled) | audit route: bypass: wall 100,127,122 floor -> "
            "139,128,117 | next: wall it: dfllm cmd bp.place tpl=seal site=S1 at=audit (or a plan build seal "
            "p.at=audit)") in line, line
    _r0_state(save, open=0, ents=None, fail=["bypass"], audit={"ok": 0, "age": 9000, "min_traps": 0},
              route="bypass: edge->Z3/Z4 avoids the trap hall (reaches 1,2,3)")
    line = brief.status_text(save).splitlines()[1]
    assert "audit route: bypass: edge->Z3/Z4" in line and "next: no wall tile on that route: dfllm cmd inspect " \
        "what=entrances" in line
    _r0_state(save, open=9, fail=["x" * 24] * 8, ents=["y" * 24] * 3, dhold="z" * 24,
              route="bypass: wall 1000,1000,100 ramp (+more) -> 1000,1000,100x")
    out = brief.status_text(save)
    assert est_tokens(out) <= brief.STATUS_TOKENS
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"]["route"] = "r" * 61
    assert schema.validate("state", st) != []
