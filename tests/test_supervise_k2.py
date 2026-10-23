"""K2 (BUG-098, BUG-099, FR-81): crash recovery after DFHack 53.16-r3 broke load-save.

Run 14 note 71: `dfhack-run load-save region2` died with "Cannot write field viewscreen_titlest.sel_menu_line: not found" (the
field is `selected` now), writing it moves nothing, so every automatic restart ended at the title screen and supervise
only wrote "no dfllm fort loaded". Here: the stock load-save first, the title-screen run (tools/embark/embark.lua, mode
load) when it fails, a loud and cadenced `needs_click` alarm when nothing loads, and the DFHack version watch.
Fake OS and fake DFHack of tests/test_supervise.py; the Lua side is tests/lua/test_loadsave*.lua."""
import json
import re

import pytest

from dfpilot import supervise as sv
from test_supervise import (T0, W, advance, crash_world, degraded_world, hb, live, make_save, put,  # noqa: F401
                            run, state)

R3 = "53.16-r3"


def chain(W, **kw):
    """Crash at the start of the world of crash_world; two passes (DF down twice), the second runs the chain."""
    crash_world(W, **kw)
    run(W)
    advance(W, 60)
    return run(W)


def crash_again(W):
    """The fort that the chain loaded runs for a while, then DF dies again: two passes with DF down, the second restarts."""
    live(W, name="autosave 1", since=W.os.started + 1)
    advance(W, 60)
    assert run(W)["live"]
    W.os.up = False
    advance(W, 600)
    run(W)
    advance(W, 60)
    return run(W)


def log_text(W):
    return (W.env.runtime / "supervise.log").read_text(encoding="utf-8")


# ---------------------------------------------------------------- the stock load-save first
def test_stock_load_save_is_still_the_first_try(W):
    r = chain(W)
    assert r["restart"]["phase"] == "done"
    assert W.os.dfhack_verbs() == {"version", "load-save"}              # no title run when the stock script works
    assert W.os.specs == [] and "needs_click" not in state(W)
    st = state(W)
    assert st["dfhack"]["ver"] == "53.16-r2" and st["last_loaded"]["ver"] == "53.16-r2"


def test_field_error_falls_back_to_the_title_run(W):
    """BUG-098: the stock script fails with the renamed-field error, the chain loads the save by clicks."""
    W.os.stock_broken, W.os.version = True, R3
    r = chain(W)
    assert r["restart"]["phase"] == "done", r["restart"]["log"]
    assert W.os.dfhack_verbs() == {"version", "load-save", "lua"}
    (spec,) = W.os.specs
    assert spec["mode"] == "load" and spec["save"] == "autosave 1" and spec["stock"] is False and spec["v"] == 2
    lua_cmd = [c for c in W.os.calls if isinstance(c, tuple) and c[1] == "lua"][0]
    assert lua_cmd[2] == "-f" and lua_cmd[3].endswith("tools/embark/embark.lua") and lua_cmd[4] == "run"
    st = state(W)
    assert st["last_loaded"] == {"name": "autosave 1", "mt": st["last_loaded"]["mt"], "ver": R3}
    log = log_text(W)
    assert "title run" in log and "@95,97" in log and "@355,187" in log        # the pixels clicked are in the log
    assert "Loading game" in log                                                 # and the rows seen
    assert any("title run" in x and "clicks 2" in x for x in r["restart"]["log"])
    assert st["restart"]["title"][0]["clicks"][0] == 'main "Continue playing" @95,97'


@pytest.mark.parametrize("err", ["Cannot write field viewscreen_titlest.sel_menu_line: not found.",
                                 "some other failure of the script", "attempt to index a nil value (field 'x')"])
def test_any_failure_of_the_stock_script_uses_the_title_run(W, err):
    W.os.stock_error = err
    r = chain(W)
    assert r["restart"]["phase"] == "done" and len(W.os.specs) == 1


def test_cant_find_save_is_not_a_reason_to_click(W):
    """DFHack does not know the folder: no clicks (no other save is chosen), the failure names the version."""
    W.os.stock_broken, W.os.load_out, W.os.version = True, "Can't find save: autosave 1", R3
    r = chain(W)
    assert r["restart"]["phase"] == "failed" and W.os.specs == [] and W.os.lua_calls == []
    assert "find save" in state(W)["failed"]["msg"] and "DFHack 53.16-r3" in state(W)["failed"]["msg"]
    assert "needs_click" not in state(W)                                  # restart_failed says it (no click path)
    advance(W, 60)
    assert any(a["key"] == "restart_failed" for a in run(W)["alerts"])


def test_unreachable_dfhack_is_waited_for_not_clicked(W):
    """While dfhack-run cannot connect, nothing starts; the first title run comes after DFHack answered."""
    W.os.stock_broken, W.os.dfhack_ready, W.os.title_ready = True, 100, 110      # DFHack starts late
    chain(W)
    first = W.os.lua_calls[0][0] - W.os.started
    assert first >= 110, first                                           # not before the title screen is up
    early = [c for c in W.os.calls if isinstance(c, tuple) and c[0] == "dfhack"][:6]
    assert all(c[1] in ("version", "load-save") for c in early), early


def test_no_title_screen_yet_is_waited_for_then_clicked_anyway(W):
    """"Can't find title or load game screen" for TITLE_GRACE_S after DFHack answered: the screen may be the list
    (stock load-save only knows the main menu): the run decides, it clicks nothing on a screen it does not know."""
    W.os.title_ready = 10 ** 9                                           # the stock script never finds a title screen
    chain(W)
    t_ready = W.os.started + W.os.dfhack_ready
    assert W.os.lua_calls, "the grace ended: the title run was tried"
    assert W.os.lua_calls[0][0] - t_ready >= sv.TITLE_GRACE_S - 6, W.os.lua_calls[0][0] - t_ready


# ---------------------------------------------------------------- BUG-099: the loud failure
def failing(W, mode="fail", version=R3):
    W.os.stock_broken, W.os.version, W.os.title_modes = True, version, [mode]
    return chain(W)


def test_chain_that_cannot_load_raises_needs_click_with_save_version_and_screen(W):
    r = failing(W)
    assert r["restart"]["phase"] == "failed"
    msg = state(W)["failed"]["msg"]
    assert "DFHack 53.16-r3" in msg and "Cannot write field" in msg and "not on the screen" in msg, msg
    nc = state(W)["needs_click"]
    assert nc["save"] == "autosave 1" and nc["ver"] == R3 and "autosave 10" in nc["screen"] and nc["runs"] >= 3
    (alert,) = [a for a in r["alerts"] if a["key"] == "needs_click"]      # in the SAME pass, not one minute later
    assert "autosave 1" in alert["msg"] and R3 in alert["msg"] and "region2" in alert["msg"], alert["msg"]
    assert alert["msg"].startswith("click Continue by hand")
    assert len(alert["msg"]) <= 330
    assert r["needs_click"]["save"] == "autosave 1"
    assert re.search(r"ALERT needs_click: click Continue by hand", log_text(W))
    assert "NEEDS" not in sv.summary(r) and "ALERT needs_click: click Continue" in sv.summary(r)


def test_title_runs_are_bounded_and_back_off(W):
    failing(W)
    n = len(W.os.specs)
    assert 4 <= n <= 8, n                                                # 20 s, 40 s, 80 s ... not one per loop
    starts = [t for t, a in W.os.lua_calls if a[0] == "run"]
    gaps = [b - a for a, b in zip(starts, starts[1:])]
    assert all(g >= sv.TITLE_GAP_S for g in gaps) and gaps == sorted(gaps), gaps


def test_the_alarm_repeats_by_the_cadence_not_by_the_loop(W):
    failing(W)
    seen = []
    for _ in range(100):                                                 # 100 passes, one a minute
        advance(W, 60)
        r = run(W)
        assert any(a["key"] == "needs_click" for a in r["alerts"])       # the summary always shows it ...
        said = state(W)["said"]["needs_click"]
        if not seen or said != seen[-1]:
            seen.append(said)
    assert 2 <= len(seen) <= 5, seen                                     # ... but it is SAID at most every SAY_EVERY_S
    assert all(b - a >= sv.SAY_EVERY_S for a, b in zip(seen, seen[1:])), seen
    lines = [x for x in log_text(W).splitlines() if "ALERT needs_click" in x]
    assert len(lines) == len(seen)


def test_one_failure_is_one_alarm_not_two(W):
    """needs_click carries the reason and the screen; the older restart_failed alert would say the same a minute later."""
    failing(W)
    for _ in range(5):
        advance(W, 60)
        assert not any(a["key"] == "restart_failed" for a in run(W)["alerts"])
    st = state(W)
    assert "failed" in st and "restart_failed" not in st["said"] and "needs_click" in st["said"]


def test_a_human_who_clicks_Continue_meanwhile_ends_the_chain_without_alarm(W):
    W.os.stock_broken, W.os.title_modes = True, ["fail"]
    crash_world(W)
    run(W)
    advance(W, 60)
    t_click = W.clock() + 200                                              # the player does not wait for the chain

    def human(t):
        if t >= t_click:
            put(W.env.runtime / "ACTIVE", "autosave 1", t)
            hb(W.env, "autosave 1", t)
            W.clock.hooks.remove(human)
    W.clock.hooks.append(human)
    r = run(W)
    assert r["restart"]["phase"] == "done", r["restart"]["log"]
    assert any("human load" in x for x in r["restart"]["log"])
    st = state(W)
    assert "needs_click" not in st and "failed" not in st and len(W.os.specs) < sv.LOAD_MAX_S // 60
    assert not any(a["key"] == "needs_click" for a in r["alerts"])


def test_the_alarm_clears_when_a_fort_is_live(W):
    r = failing(W)
    assert "needs_click" in state(W)
    advance(W, 120)
    put(W.env.runtime / "ACTIVE", "autosave 1", W.clock())                # the human clicked Continue, the kernel booted
    hb(W.env, "autosave 1", W.clock())
    r = run(W)
    assert r["live"] and not any(a["key"] in ("needs_click", "restart_failed") for a in r["alerts"])
    st = state(W)
    assert "needs_click" not in st and "failed" not in st


def test_the_alarm_does_not_stop_later_attempts(W):
    """The alarm is information, not a latch: after the human's click the next crash restarts as before."""
    failing(W)
    advance(W, 120)
    put(W.env.runtime / "ACTIVE", "autosave 1", W.clock())
    hb(W.env, "autosave 1", W.clock())
    run(W)                                                                # live, alarm cleared
    W.os.title_modes = ["ok"]
    W.os.up = False
    advance(W, 600)
    run(W)
    advance(W, 60)
    r = run(W)
    assert r["restart"]["phase"] == "done", r["restart"]["log"]
    st = state(W)
    assert len(st["restarts"]) == 2 and "needs_click" not in st
    assert not (W.env.runtime / sv.NORESTART).exists()


@pytest.mark.parametrize("mode", ["ok", "fail"])
def test_a_new_attempt_replaces_the_standing_alarm(W, mode):
    old = {"save": "autosave 1", "ver": "53.16-r1", "why": "old", "screen": "", "wall": int(W.clock()) - 5000, "runs": 1}
    put(W.env.runtime / "supervise.json", json.dumps({"v": 2, "needs_click": old}))
    W.os.stock_broken, W.os.version, W.os.title_modes = True, R3, [mode]
    chain(W)
    nc = state(W).get("needs_click")
    if mode == "ok":
        assert nc is None
    else:
        assert nc["wall"] > old["wall"] and nc["ver"] == R3 and nc["why"] != "old"


@pytest.mark.parametrize("mode,reason", [("hang", "did not end within 150 s and was stopped"),
                                         ("start_fail", "the title run did not start: error: cannot open file")])
def test_title_run_failures_name_their_reason(W, mode, reason):
    r = failing(W, mode)
    assert r["restart"]["phase"] == "failed"
    nc = state(W)["needs_click"]
    assert reason in nc["why"] and R3 in state(W)["failed"]["msg"]
    if mode == "hang":                                                    # a hung run is stopped, never left clicking
        stops = [a for _t, a in W.os.lua_calls if a[0] == "stop"]
        assert len(stops) >= len(W.os.specs) and not W.os.run_active


def test_a_title_run_that_clicked_through_but_no_fort_came_up(W):
    """The run says done (it left the title screen) but the kernel never boots: the map wait fails with the alarm."""
    W.os.stock_broken, W.os.version, W.os.title_modes = True, R3, ["ok_noboot"]
    r = chain(W)
    assert r["restart"]["phase"] == "failed"
    msg = state(W)["failed"]["msg"]
    assert "fort not live 15 min after the load" in msg and "DFHack 53.16-r3" in msg and "clicked through" in msg, msg
    assert state(W)["needs_click"]["save"] == "autosave 1"


def test_second_load_after_180_s_uses_the_title_run_too(W):
    W.os.stock_broken, W.os.title_modes = True, ["ok_noboot", "ok"]
    r = chain(W)
    assert r["restart"]["phase"] == "done", r["restart"]["log"]
    assert len(W.os.specs) == 2
    assert any("2nd load (title)" in x for x in r["restart"]["log"])


@pytest.mark.parametrize("how", ["flag", "lock"])
def test_a_player_who_takes_over_stops_the_clicks(W, how):
    """norestart.flag / a held live.lock turn kills and starts off; the click runs are starts: none after the flag."""
    W.os.stock_broken, W.os.title_modes, W.os.version = True, ["fail"], R3
    crash_world(W)
    run(W)
    advance(W, 60)
    t_flag = W.clock() + 60

    def player(t):
        if t >= t_flag:
            if how == "flag":
                put(W.env.runtime / sv.NORESTART, "")
            else:
                put(W.env.runtime / "live.lock", json.dumps({"holder": "player", "purpose": "menu", "expires": int(t) + 7200}))
            W.clock.hooks.remove(player)
    W.clock.hooks.append(player)
    r = run(W)
    runs_at_flag = [t for t, a in W.os.lua_calls if a[0] == "run" and t < t_flag + 30]
    assert len(W.os.specs) == len(runs_at_flag) >= 1, (len(W.os.specs), runs_at_flag)
    assert r["restart"]["phase"] == "failed"
    why = state(W)["needs_click"]["why"]
    assert ("norestart.flag present" if how == "flag" else "live.lock held by player") in why, why


def test_missing_embark_helper_is_a_reason_not_a_crash(W):
    (W.env.repo / "tools" / "embark" / "embark.lua").unlink()
    W.os.stock_broken = True
    r = chain(W)
    assert r["restart"]["phase"] == "failed" and "embark.lua" in state(W)["needs_click"]["why"]
    assert W.os.lua_calls == [] or all(a[0] == "screen" for _t, a in W.os.lua_calls)


def test_dfhack_that_never_answers_says_so(W):
    W.os.dfhack_ready = 10 ** 9
    r = chain(W)
    assert r["restart"]["phase"] == "failed"
    nc = state(W)["needs_click"]
    assert "did not answer" in nc["why"] and nc["ver"] is None and nc["screen"] == ""
    assert "DFHack ?" in state(W)["failed"]["msg"]


# ---------------------------------------------------------------- FR-81: the version watch
def test_version_is_recorded_and_unchanged_version_is_quiet(W):
    r = chain(W)
    assert r["restart"]["phase"] == "done"
    assert not any(a["key"] == "dfhack_version" for a in r["alerts"])
    assert r["dfhack"] == {"ver": "53.16-r2", "loaded": "53.16-r2"} and "DFHack 53.16-r2" in sv.summary(r)
    r = crash_again(W)
    assert r["restart"]["phase"] == "done" and not any(a["key"] == "dfhack_version" for a in r["alerts"])


def test_a_new_dfhack_version_is_warned_about_once(W):
    chain(W)
    assert state(W)["last_loaded"]["ver"] == "53.16-r2"
    W.os.version = R3                                                     # the Steam update, then a crash
    r = crash_again(W)
    assert r["restart"]["phase"] == "done"
    (a,) = [x for x in r["alerts"] if x["key"] == "dfhack_version"]
    assert "53.16-r2 -> 53.16-r3" in a["msg"] and "Steam" in a["msg"], a["msg"]
    assert state(W)["last_loaded"]["ver"] == R3
    advance(W, 60)
    live(W, name="autosave 1", since=W.os.started + 1)
    r = run(W)
    assert not any(x["key"] == "dfhack_version" for x in r["alerts"]), "said once per pair of versions"
    assert "changed" not in state(W)["dfhack"]


def test_a_new_version_that_cannot_load_keeps_the_warning_in_the_alarm(W):
    chain(W)
    W.os.stock_broken, W.os.version, W.os.title_modes = True, R3, ["fail"]
    r = crash_again(W)
    assert r["restart"]["phase"] == "failed"
    keys = [a["key"] for a in r["alerts"]]
    assert "dfhack_version" in keys and "needs_click" in keys
    (a,) = [x for x in r["alerts"] if x["key"] == "dfhack_version"]
    assert "untested there" in a["msg"]
    assert state(W)["last_loaded"]["ver"] == "53.16-r2", "a failed load does not move the baseline"
    advance(W, 60)
    r = run(W)
    assert not any(x["key"] == "dfhack_version" for x in r["alerts"])


def test_check_version_on_demand(W, capsys):
    assert sv.main(["--check-version"], env=W.env) == 0
    assert "DFHack 53.16-r2 (no successful load recorded yet)" in capsys.readouterr().out
    assert [c for c in W.os.calls] == [("dfhack", "version")]
    assert state(W)["dfhack"]["ver"] == "53.16-r2"
    st = state(W)
    st["last_loaded"] = {"name": "autosave 1", "mt": 1.0, "ver": "53.16-r1"}
    put(W.env.runtime / "supervise.json", json.dumps(st))
    assert sv.main(["--check-version"], env=W.env) == 0
    out = capsys.readouterr().out
    assert "53.16-r1 -> 53.16-r2" in out and "Steam" in out
    W.os.version = "no version here"
    assert sv.main(["--check-version"], env=W.env) == 1


def test_check_version_does_not_race_a_running_pass(W, capsys):
    lock = W.env.runtime / "supervise.lock"
    put(lock, f"1 {int(W.clock())}\n", W.clock())                       # a pass or a restart chain is running
    assert sv.main(["--check-version"], env=W.env) == 1
    assert "another run holds supervise.lock" in capsys.readouterr().out
    assert W.os.calls == [] and lock.exists()
    lock.unlink()
    assert sv.main(["--check-version"], env=W.env) == 0 and not lock.exists()


def test_parse_version():
    for text, want in (("53.16-r3", "53.16-r3"), ("DFHack version 53.16-r3 (release)", "53.16-r3"),
                       ("53.16-r3\r\n", "53.16-r3"), ("0.47.05-r8", "0.47.05-r8"), ("53.16", "53.16"),
                       ("error: could not connect", None), ("", None), (None, None)):
        assert sv.parse_version(text) == want, text


def test_load_kind_classes():
    assert sv.load_kind(True, "loading") == "ok"
    assert sv.load_kind(False, "Can't find save: autosave 1") == "nosave"
    assert sv.load_kind(False, "error: could not connect") == "unreachable"
    assert sv.load_kind(False, "Could not connect to DFHack: connection refused") == "unreachable"
    assert sv.load_kind(False, "TimeoutExpired: Command timed out") == "unreachable"
    assert sv.load_kind(False, "missing C:/DF/hack/dfhack-run.exe") == "unreachable"
    assert sv.load_kind(False, "Can't find title or load game screen") == "notitle"
    assert sv.load_kind(False, "...load-save.lua:17: Cannot write field viewscreen_titlest.sel_menu_line: not found.") == "broken"
    assert sv.load_kind(False, "") == "broken"


def test_reset_clears_the_alarm(W, capsys):
    failing(W)
    assert "needs_click" in state(W)
    assert sv.main(["--reset"], env=W.env) == 0
    assert "needs_click" not in state(W)
