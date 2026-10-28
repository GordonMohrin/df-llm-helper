"""M7 (FR-91, BUG-120, Run 14 note 99): loading the newest COMPLETE save at the title screen without a player.

Rules a-c: `supervise --load` / the crash chain never load a half-written `autosave 3_tmp`; the answer names the save, its fort,
the game year/day and the age. d: status and brief at the title screen say "DF at title screen: no fort loaded" and print none of
the old fort's numbers. e: `dfllm doctor` shows `load_save: broken (DFHack <version>)`. Fake OS of tests/test_supervise.py."""
import json
import os
import time

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, doctor, loadsave, paths
from dfpilot import loadnow
from dfpilot import supervise as sv
from test_supervise import T0, W, advance, make_save, put, run, state, write_perf  # noqa: F401

R3 = "53.16-r3"


def perf_near(W, name, mt, tick):
    """perf.csv rows every 30 s around the wall time `mt` (the kernel's log): the save was written at `tick`."""
    rows = [(int(mt) - 60 + 30 * i, tick - 60 * 7 + 30 * 7 * i // 2, "PEACE", 450, 5, 0) for i in range(5)]
    rows = [(w, tick - (int(mt) - w) * 7, m, tps, g, g3) for (w, _t, m, tps, g, g3) in rows]
    write_perf(W, name, 450, rows=rows)


def title_world(W, *, tmp=True):
    """DF runs at the title screen (no ACTIVE): the fort's last autosave and a cut-off autosave 3_tmp after it."""
    t = W.clock()
    make_save(W.env.saves, "region3", t - 90000, marker=None, size=40000)            # the player's own fort
    make_save(W.env.saves, "autosave 2", t - 700)
    if tmp:
        make_save(W.env.saves, "autosave 3_tmp", t - 400)                              # DF died writing it
    perf_near(W, "region4", t - 700, 3 * sv.YEAR + 2 * 100800 + 11 * 1200 + 5)        # y3 aut d12


# ---------------------------------------------------------------- (a), (c): the newest COMPLETE save
def test_tmp_save_is_never_loaded_by_the_crash_chain(W):
    t = W.clock()
    put(W.env.runtime / "ACTIVE", "region4", t - 3000)
    make_save(W.env.saves, "autosave 2", t - 700)
    make_save(W.env.saves, "autosave 3_tmp", t - 400)
    W.os.up = False
    run(W)
    advance(W, 60)
    r = run(W)
    assert r["restart"]["phase"] == "done", r["restart"]["log"]
    assert ("dfhack", "load-save", "autosave 2") in W.os.calls
    assert ("dfhack", "load-save", "autosave 3_tmp") not in W.os.calls
    assert state(W)["last_loaded"]["name"] == "autosave 2"


def test_pick_save_skips_a_dead_tmp_but_waits_for_a_live_one(tmp_path):
    t = T0
    make_save(tmp_path, "autosave 2", t - 1000)
    make_save(tmp_path, "autosave 3_tmp", t - 500)
    saves = sv.scan_saves(tmp_path, {}, t)
    assert [(e["name"], e["tmp"], bool(e["bad"])) for e in saves] == [("autosave 3_tmp", True, True), ("autosave 2", False, False)]
    assert "died while writing" in saves[0]["bad"]
    s, why = sv.pick_save(saves, t, active="region4", since=t - 3000)
    assert s["name"] == "autosave 2" and why == "ok"
    # DF is writing the _tmp folder right now (its files are seconds old): the choice waits, it does not fall back
    make_save(tmp_path, "autosave 3_tmp", t - 20)
    saves = sv.scan_saves(tmp_path, {}, t)
    assert saves[0]["writing"] and "DF is writing it" in saves[0]["bad"]
    s, why = sv.pick_save(saves, t, active="region4", since=t - 3000)
    assert s is None and "autosave 3_tmp is still being written" in why
    # nothing complete at all: only the dead _tmp folder is left
    (tmp_path / "autosave 2" / "world.sav").unlink()
    only = sv.scan_saves(tmp_path, {}, t + 900)
    s, why = sv.pick_save(only, t + 900, active="region4", since=None)
    assert s is None and "no complete fortress save (autosave 3_tmp: name ends in _tmp" in why


def test_backup_never_copies_a_half_written_save(W):
    t = W.clock()
    make_save(W.env.saves, "autosave 2", t - 700)
    make_save(W.env.saves, "autosave 3_tmp", t - 400)
    put(W.env.runtime / "ACTIVE", "region4", t - 3000)
    from test_supervise import hb
    hb(W.env, "region4", t - 2)
    run(W)
    names = [p.name for p in W.env.backups.rglob("world.sav")]
    assert names and all("_tmp" not in str(p) for p in W.env.backups.rglob("*")), names


def test_missing_world_sav_and_missing_companion_file_are_incomplete(tmp_path):
    t = T0
    for n, ts in (("autosave 1", 3000), ("autosave 2", 2000), ("autosave 3", 1000)):
        d = make_save(tmp_path, n, t - ts)
        put(d / "world.dat", b"d", t - ts)
    (tmp_path / "autosave 4").mkdir()
    put(tmp_path / "autosave 4" / "unit-1.dat", b"u", t - 500)                           # no world.sav at all
    make_save(tmp_path, "autosave 5", t - 300)                                            # world.sav, but no world.dat
    assert [e["name"] for e in sv.scan_saves(tmp_path, {}, t)] == ["autosave 5", "autosave 3", "autosave 2", "autosave 1"]
    full = {e["name"]: e for e in sv.scan_saves(tmp_path, {}, t, partial=True)}
    assert full["autosave 4"]["bad"] == "no world.sav"
    assert full["autosave 5"]["bad"] == "lacks world.dat, which the 3 other saves have"
    assert not full["autosave 3"]["bad"]
    s, _why = sv.pick_save(sv.scan_saves(tmp_path, {}, t), t + 10, active="region4", since=t - 5000)
    assert s["name"] == "autosave 3"
    # with fewer than two siblings the companion rule stays silent (nothing proves what a save must hold)
    assert not loadsave.mark([{"name": "a", "ws": True, "wss": 1, "names": ["world.sav"], "newest": 0},
                              {"name": "b", "ws": True, "wss": 1, "names": ["world.sav", "world.dat"], "newest": 0}], t)[0]["bad"]


def test_saves_listing_names_the_reason(W, capsys):
    title_world(W)
    put(W.env.saves / "autosave 4" / "unit-1.dat", b"u")
    assert sv.main(["--saves"], env=W.env) == 0
    out = capsys.readouterr().out
    assert "autosave 2" in out and "complete" in out
    assert "autosave 3_tmp" in out and "NOT LOADABLE: name ends in _tmp: DF died while writing it" in out
    assert "autosave 4" in out and "NOT LOADABLE: no world.sav" in out
    assert "no dfllm marker" in out                                                       # region3 is the player's


# ---------------------------------------------------------------- (a), (b): supervise --load
def test_load_now_loads_the_newest_complete_save_and_says_which(W):
    title_world(W)
    W.os.stock_broken, W.os.version = True, R3
    code, text = loadnow.load_now(W.env)
    assert code == 0, text
    assert text.startswith("load: 'autosave 2' (fort Testfort, game time ~y3 aut d12, saved 11m ago)"), text
    assert "not loaded: 'autosave 3_tmp' (name ends in _tmp: DF died while writing it)" in text
    assert "ignored newer" not in text and "loaded:" in text and f"DFHack {R3}" in text
    (spec,) = W.os.specs                                                                  # the click path loaded it
    assert spec["mode"] == "load" and spec["save"] == "autosave 2"
    st = state(W)
    assert st["last_loaded"]["name"] == "autosave 2" and st["last_loaded"]["ver"] == R3
    assert st["load_save"]["state"] == "broken" and st["load_save"]["ver"] == R3
    assert "sel_menu_line" in st["load_save"]["why"]
    assert st["restart"]["why"] == "manual load" and st["restart"]["phase"] == "done"
    assert not (W.env.runtime / "supervise.lock").exists()
    assert len(st.get("restarts", [])) == 0, "a manual load is no restart of the 6-hour limit"


def test_load_now_with_the_stock_script_working_records_it(W):
    title_world(W, tmp=False)
    code, text = loadnow.load_now(W.env)
    assert code == 0 and W.os.specs == []
    assert state(W)["load_save"]["state"] == "ok" and ("dfhack", "load-save", "autosave 2") in W.os.calls
    assert "game time ~y3 aut d12" in text


def test_load_now_game_time_unknown_without_a_perf_row(W):
    t = W.clock()
    make_save(W.env.saves, "autosave 2", t - 700)
    code, text = loadnow.load_now(W.env, dry_run=True)
    assert code == 0 and "game time unknown" in text and "dry run" in text and W.os.calls == []


@pytest.mark.parametrize("case", ["live", "down", "flag", "lock"])
def test_load_now_refuses_and_touches_nothing(W, case):
    title_world(W)
    from test_supervise import hb
    if case == "live":
        put(W.env.runtime / "ACTIVE", "region4", W.clock() - 300)
        hb(W.env, "region4", W.clock() - 2)
    elif case == "down":
        W.os.up = False
    elif case == "flag":
        put(W.env.runtime / sv.NORESTART, "")
    else:
        put(W.env.runtime / "live.lock", json.dumps({"holder": "WP5", "purpose": "drill", "expires": int(W.clock()) + 900}))
    code, text = loadnow.load_now(W.env)
    assert code == 1 and "not loading:" in text, text
    assert W.os.calls == [] and not (W.env.runtime / "supervise.json").exists()
    needle = {"live": "a dfllm fort is loaded already ('region4'", "down": "DF is not running",
              "flag": "norestart.flag present", "lock": "live.lock held by WP5"}[case]
    assert needle in text, text
    code, text = loadnow.load_now(W.env, dry_run=True)                                    # a dry run still tells the save
    assert code == 0 and "would not load now" in text and needle in text


def test_load_now_by_name_never_an_older_or_incomplete_or_foreign_save(W):
    title_world(W)
    make_save(W.env.saves, "autosave 1", W.clock() - 5000)                                # older save of the same fort
    for want, needle in (("autosave 1", "older than 'autosave 2' of the same fort"),
                         ("autosave 3_tmp", "not complete: name ends in _tmp"),
                         ("region3", "no dfllm marker"), ("autosave 9", "no save folder 'autosave 9'")):
        code, text = loadnow.load_now(W.env, want)
        assert code == 1 and needle in text, (want, text)
    assert W.os.calls == []
    code, text = loadnow.load_now(W.env, "autosave 2")
    assert code == 0 and "'autosave 2'" in text


def test_load_now_failure_raises_needs_click_and_names_the_version(W):
    title_world(W)
    W.os.stock_broken, W.os.version, W.os.title_modes = True, R3, ["fail"]
    code, text = loadnow.load_now(W.env)
    assert code == 1 and "NOT loaded" in text and "DFHack 53.16-r3" in text, text
    st = state(W)
    assert st["needs_click"]["save"] == "autosave 2" and st["needs_click"]["ver"] == R3
    assert st["restart"]["phase"] == "failed" and not (W.env.runtime / "supervise.lock").exists()
    assert (W.clock() - W.os.started) < 7200 + 2 * loadnow.NOW_LOAD_MAX_S + 60, "bounded: not the 15 minutes of the restart chain"


def test_cli_load_and_dry_run(W, capsys):
    title_world(W)
    assert sv.main(["--load", "--dry-run"], env=W.env) == 0
    out = capsys.readouterr().out
    assert out.startswith("load: 'autosave 2'") and W.os.calls == []
    assert sv.main(["--load", "autosave 3_tmp"], env=W.env) == 1
    assert "not complete" in capsys.readouterr().out


# ---------------------------------------------------------------- (d): status at the title screen
@pytest.fixture
def rt(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def supervise_doc(rt, **last):
    doc = {"v": 2, "runs": 5, "last": {"v": 2, "wall": int(time.time()) - 30, "df": "up", "active": None, "live": False,
                                        "why": "no dfllm fort loaded (title screen or an unmarked save)", **last}}
    (rt.parent / "supervise.json").write_text(json.dumps(doc), encoding="utf-8")
    return doc


def old_heartbeat(rt, age=900):
    t = time.time() - age
    os.utime(rt / "heartbeat", (t, t))


def test_status_at_the_title_screen_prints_the_fixed_line_and_no_numbers(rt):
    before = brief.status_text(rt)
    assert "DEFCON" in before and "pop" in before.lower()                                   # the cached numbers of the fixture
    supervise_doc(rt)
    old_heartbeat(rt)
    text = brief.status_text(rt)
    assert text.splitlines()[0] == "DF at title screen: no fort loaded", text
    assert "DEFCON" not in text and "pop" not in text.lower() and "drink" not in text.lower()
    assert "NOT live" in text and "15m old" in text and "dfllm supervise --load" in text
    b = brief.brief_text(rt)
    assert b.splitlines()[0] == "# brief DF at title screen: no fort loaded" and "DEFCON" not in b and "## plan" not in b
    assert brief.est_tokens(text) <= 120


def test_status_title_line_carries_the_needs_click_alarm_and_df_down(rt):
    doc = supervise_doc(rt)
    doc["needs_click"] = {"save": "autosave 2", "ver": R3, "why": "title screen: nothing clicked", "wall": 1}
    (rt.parent / "supervise.json").write_text(json.dumps(doc), encoding="utf-8")
    old_heartbeat(rt)
    text = brief.status_text(rt)
    assert f"needs_click: save 'autosave 2', DFHack {R3}: title screen: nothing clicked" in text
    supervise_doc(rt, df="down", why="DF not running; 'region4' was not unloaded (crash?)")
    assert brief.status_text(rt).splitlines()[0] == "DF is not running: no fort loaded"


def test_status_keeps_its_numbers_when_a_fort_may_be_live(rt):
    """The title line needs a fresh pass of supervise that saw DF up with no fort and no fresh heartbeat of this fort."""
    old_heartbeat(rt)
    supervise_doc(rt)
    assert brief.status_text(rt).startswith("DF at title screen"), "the line itself"
    for last, why in ((dict(wall=int(time.time()) - 600), "the task stopped: say nothing new"),
                      (dict(active="region7"), "supervise saw a fort"), (dict(live=True), "supervise saw it live")):
        supervise_doc(rt, **last)
        assert brief.status_text(rt).startswith("DEFCON"), why
    supervise_doc(rt)
    old_heartbeat(rt, 5)                                                                    # the fort's own files win
    assert brief.status_text(rt).startswith("DEFCON")
    (rt.parent / "supervise.json").unlink()
    old_heartbeat(rt)
    assert brief.status_text(rt).startswith("DEFCON"), "no supervise.json: as before"


# ---------------------------------------------------------------- (e): doctor
def test_doctor_shows_the_load_save_state(rt):
    supervise_doc(rt)
    doc = json.loads((rt.parent / "supervise.json").read_text(encoding="utf-8"))
    doc["load_save"] = {"state": "broken", "ver": R3, "wall": 1, "why": "Cannot write field viewscreen_titlest.sel_menu_line: not found."}
    out, bad = doctor.supervise_lines(doc, time.time())
    assert out[0].startswith(f"load_save: broken (DFHack {R3}): Cannot write field viewscreen_titlest.sel_menu_line")
    assert "title-screen clicks" in out[0] and bad == []
    doc["load_save"] = {"state": "ok", "ver": "53.16-r2", "wall": 1, "why": ""}
    assert doctor.supervise_lines(doc, time.time())[0] == ["load_save: ok (DFHack 53.16-r2)"]
    assert doctor.supervise_lines({"v": 2}, time.time()) == ([], [])


def test_reset_forgets_the_load_save_record(W):
    put(W.env.runtime / "supervise.json", json.dumps({"v": 2, "load_save": {"state": "broken", "ver": R3}, "restarts": [1]}))
    assert sv.main(["--reset"], env=W.env) == 0
    assert "load_save" not in state(W)


# ---------------------------------------------------------------- the loader's dump reaches supervise.log once per chain
DUMP = {"why": "the title menu has no Continue or Load entry", "focus": "title/Default", "kind": "title", "size": "171x66",
        "title": {"old_field": False, "selected": 0}, "rows": ["3   Fortress Mode", "5   Settings"],
        "cells": ["3,3 Fortress Mode", "3,5 Settings"]}


def test_title_dump_is_logged_once_per_chain_and_kept_for_doctor(W):
    title_world(W)
    W.os.stock_broken, W.os.version, W.os.title_modes = True, R3, ["fail"]
    plain = W.os.status_doc

    def with_dump(rid, state, msg, results):
        plain(rid, state, msg, dict(results, dump=DUMP))
    W.os.status_doc = with_dump
    code, _text = loadnow.load_now(W.env)
    assert code == 1 and len(W.os.specs) >= 3, "several runs in the chain"
    log = (W.env.runtime / "supervise.log").read_text(encoding="utf-8")
    assert log.count("title screen dump for 'autosave 2'") == 1, "once per chain, not once per run"
    line = next(x for x in log.splitlines() if "title screen dump" in x)
    assert "focus=title/Default" in line and "Fortress Mode" in line and "kind=title" in line and '"old_field": false' in line
    td = state(W)["title_dump"]
    assert td["focus"] == "title/Default" and td["rows"] == ["3 Fortress Mode", "5 Settings"] and td["save"] == "autosave 2"
    out, _bad = doctor.supervise_lines(state(W), W.clock())
    assert any(x.startswith("title screen dump (autosave 2): the title menu has no Continue or Load entry; viewscreens "
                            "title/Default, 2 rows kept") for x in out), out
