"""WP10 supervise: fake clock, fake OS (no tasklist/taskkill/Steam/dfhack-run), tmp dirs only."""
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from df_llm_helper import supervise as sv

T0 = 1_791_600_000.0
YEAR = sv.YEAR
MARK_A = ("region4", 1000, "Testfort")
MARK_B = ("region9", 5000, "Otherfort")


class Clock:
    def __init__(self, t=T0):
        self.t, self.hooks = t, []

    def __call__(self):
        return self.t

    def sleep(self, dt):
        self.t += dt
        for h in list(self.hooks):
            h(self.t)


def put(p, data=b"x", t=None):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
    if t is not None:
        os.utime(p, (t, t))


def make_save(saves, name, t, marker=MARK_A, size=20000):
    d = Path(saves) / name
    put(d / "unit-1.dat", b"u" * 1000, t - 10)
    items = [{"k": "autochop/config", "i": [1, 2]}]
    if marker:
        m = {"v": 2, "adopted": marker[1], "save": marker[0], "fort": marker[2], "acceptance": 0, "baseline": 1,
             "boots": 3}
        items.append({"k": "dfllm", "s": json.dumps(m)})
    put(d / "dfhack-entity-110.dat", json.dumps(items, indent="\t"), t - 5)
    put(d / "world.sav", b"w" * size, t)
    return d


def hb(env, name, t, mode="PEACE", paused=False, tick=3 * YEAR + 1000):
    doc = {"v": 2, "wall": int(t), "frame": 100, "tick": tick, "paused": paused, "mode": mode, "seq": 1}
    put(env.runtime / name / "heartbeat", json.dumps(doc), t)


class FakeOS:
    def __init__(self, env, clock):
        self.env, self.clock = env, clock
        self.up, self.started = True, clock() - 7200
        self.calls = []
        self.window_delay, self.dfhack_ready, self.title_ready, self.boot_delay = 5, 30, 40, 20
        self.load_out = "loading"
        self.hwnds = [(0, 4242)]               # (seconds after start, hwnd)

    def df_proc(self):
        return ("up", self.started) if self.up else ("down", None)

    def kill_df(self):
        self.calls.append("kill")
        self.up = False
        return True, "SUCCESS"

    def start_df(self):
        self.calls.append("start")
        self.up, self.started = True, self.clock()
        return True, sv.STEAM_URL

    def df_window(self):
        el = self.clock() - self.started
        if not self.up or el < self.window_delay:
            return None
        return [h for t, h in self.hwnds if el >= t][-1]

    def move_window(self, h, desktop):
        self.calls.append(("move", h, desktop))
        return True, "MOVED hr=0"

    def dfhack(self, *args, timeout=60):
        self.calls.append(("dfhack",) + args)
        el = self.clock() - self.started
        if el < self.dfhack_ready:
            return False, "error: could not connect"
        if el < self.title_ready:
            return False, "Can't find title or load game screen"
        if self.load_out.startswith("Can't find save"):
            return False, self.load_out
        boot_at, name = self.clock() + self.boot_delay, args[1]

        def boot(t):
            if t >= boot_at and self.up:
                put(self.env.runtime / "ACTIVE", name, t)
                hb(self.env, name, t)
                self.clock.hooks.remove(boot)
        self.clock.hooks.append(boot)
        return True, self.load_out

    def dfhack_verbs(self):
        return {c[1] for c in self.calls if isinstance(c, tuple) and c[0] == "dfhack"}


@pytest.fixture
def W(tmp_path):
    clock = Clock()
    env = sv.Env(df=tmp_path / "df", runtime=tmp_path / "df" / "dfllm-runtime", saves=tmp_path / "saves",
                 backups=tmp_path / "bk", repo=tmp_path / "repo", os=object(), clock=clock, sleep=clock.sleep)
    env.os = FakeOS(env, clock)
    env.saves.mkdir(parents=True)
    return SimpleNamespace(env=env, clock=clock, os=env.os, tmp=tmp_path)


def live(W, name="region4", since=None, **kw):
    t = W.clock()
    put(W.env.runtime / "ACTIVE", name, since if since is not None else t - 3000)
    hb(W.env, name, t - 2, **kw)


def run(W, **kw):
    return sv.once(env=W.env, **kw)


def advance(W, s):
    W.clock.sleep(s)


def state(W):
    return json.loads((W.env.runtime / "supervise.json").read_text(encoding="utf-8"))


def write_perf(W, name, end_tps, base_tps=450, n=60, mode="PEACE", rows=None, end_tick=None):
    """Rows every 30 s, the last one 10 s ago; end_tick = tick of the last row (consistent with the heartbeat)."""
    now = W.clock()
    if rows is None:
        rows, tick = [], 3 * YEAR
        for i in range(n):
            wall = int(now - 10 - 30 * (n - 1 - i))
            tps = end_tps if i >= n - 20 else base_tps
            tick += tps * 30
            rows.append((wall, tick, mode, tps, 400, 0))
        if end_tick is not None:
            rows = [(w, k - rows[-1][1] + end_tick, m, tps, gap, g3) for (w, k, m, tps, gap, g3) in rows]
    lines = ["wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods"]
    lines += [f"{w},{k},{m},{tps},50,180,9000,10,{gap},{g3},sense=4;siege=1" for (w, k, m, tps, gap, g3) in rows]
    put(W.env.runtime / name / "perf.csv", "\n".join(lines) + "\n")
    return rows


def ev(num, typ, cls, tick, /, **d):
    return {"n": num, "tick": tick, "type": typ, "cls": cls, "msg": typ.lower(), "d": d}


def boot(num, tick=0):
    return ev(num, "BOOT", "C", tick, save="region4", v=2, boots=1)


def pev(num, tick, why, **d):
    return ev(num, "PERF_DEGRADED", "A", tick, why=why, **d)


def write_events(W, name, evs):
    put(W.env.runtime / name / "events.jsonl", "".join(json.dumps(e) + "\n" for e in evs))


# ---------------------------------------------------------------- liveness
def test_live_ok_makes_no_calls(W):
    live(W)
    r = run(W)
    assert r["live"] and r["why"] == "ok" and r["mode"] == "PEACE" and r["alerts"] == []
    assert W.os.calls == []
    assert state(W)["last"]["live"] is True
    assert not (W.env.runtime / "supervise.lock").exists()


def test_stale_heartbeat_is_reported_never_killed(W):
    live(W)
    hb(W.env, "region4", W.clock() - 130)
    r = run(W)
    assert not r["live"] and "130 s old" in r["why"]
    assert [a["key"] for a in r["alerts"]] == ["stale"]
    assert W.os.calls == []


def test_no_fort_loaded_is_silent(W):
    r = run(W)
    assert r["df"] == "up" and r["active"] is None and "no dfllm fort" in r["why"] and r["alerts"] == []


def test_clean_exit_never_restarts(W):
    W.os.up = False
    for _ in range(3):
        r = run(W)
        advance(W, 60)
    assert "clean exit" in r["why"] and W.os.calls == []


# ---------------------------------------------------------------- crash restart
def crash_world(W, newest="autosave 1"):
    live(W, since=W.clock() - 3000)
    make_save(W.env.saves, "region3", W.clock() - 90000, marker=None, size=40000)      # Gordon's own fort
    make_save(W.env.saves, newest, W.clock() - 600)
    W.os.up = False


def test_crash_restart_chain(W):
    crash_world(W)
    r1 = run(W)
    assert "1/2" in r1["actions"][0] and W.os.calls == []
    advance(W, 60)
    r2 = run(W)
    assert r2["restart"]["phase"] == "done", r2["restart"]["log"]
    assert "kill" not in W.os.calls and W.os.calls[0] == "start"
    assert ("move", 4242, 1) in W.os.calls
    assert ("dfhack", "load-save", "autosave 1") in W.os.calls
    assert W.os.dfhack_verbs() == {"load-save"}                 # never pause/unpause/lua
    st = state(W)
    assert st["last_loaded"]["name"] == "autosave 1" and len(st["restarts"]) == 1 and "failed" not in st
    assert not (W.env.runtime / "inbox").exists()
    advance(W, 60)
    r3 = run(W)
    assert r3["live"] and r3["active"] == "autosave 1"


def test_crash_blocked_by_flag_and_live_lock(W):
    crash_world(W)
    put(W.env.runtime / sv.NORESTART, "")
    run(W)
    advance(W, 60)
    r = run(W)
    assert W.os.calls == [] and "norestart.flag" in r["alerts"][-1]["msg"]
    (W.env.runtime / sv.NORESTART).unlink()
    lock = {"holder": "WP5", "purpose": "drill L3", "expires": int(W.clock()) + 900}
    put(W.env.runtime / "live.lock", json.dumps(lock))
    r = run(W)
    assert W.os.calls == [] and "WP5" in r["alerts"][-1]["msg"]
    put(W.env.runtime / "live.lock", json.dumps(dict(lock, expires=int(W.clock()) - 1)))
    r = run(W)
    assert r["restart"]["phase"] == "done"


@pytest.mark.parametrize("case", ["unmarked", "other_fort", "broken", "too_old", "presession"])
def test_crash_never_loads_a_doubtful_or_older_save(W, case):
    t = W.clock()
    live(W, since=t - 3000)
    make_save(W.env.saves, "region4", t - 20000)                      # the ACTIVE folder, fort A
    make_save(W.env.saves, "autosave 3", t - 2000)                    # older valid save of fort A
    if case == "unmarked":
        make_save(W.env.saves, "region3", t - 100, marker=None)
    elif case == "other_fort":
        make_save(W.env.saves, "autosave 1", t - 100, marker=MARK_B)
    elif case == "broken":
        make_save(W.env.saves, "autosave 1", t - 100, size=500)
    elif case == "too_old":
        for d in ("region4", "autosave 3"):
            for f in (W.env.saves / d).iterdir():
                os.utime(f, (t - 8 * 3600, t - 8 * 3600))
        put(W.env.runtime / "ACTIVE", "autosave 9", t - 9 * 3600)
    elif case == "presession":
        put(W.env.runtime / "ACTIVE", "autosave 9", t - 1000)       # booted after the newest save
    W.os.up = False
    run(W)
    advance(W, 60)
    r = run(W)
    assert W.os.calls == [], case
    assert r["alerts"] and r["alerts"][-1]["key"] == "crash_nosave", r["alerts"]


def test_pick_save_rules(tmp_path):
    t = T0
    make_save(tmp_path, "autosave 3", t - 2000)
    make_save(tmp_path, "autosave 1", t - 1)
    saves = sv.scan_saves(tmp_path, {}, t)
    assert [e["name"] for e in saves] == ["autosave 1", "autosave 3"]
    s, why = sv.pick_save(saves, t, active="region4", since=t - 3000)
    assert s is None and "still being written" in why
    s, why = sv.pick_save(saves, t + 10, active="region4", since=t - 3000)
    assert s["name"] == "autosave 1" and why == "ok"
    assert sv.pick_save(saves, t + 10, active="region4", since=t - 3000, is_busy=True)[0] is None
    assert sv.pick_save(saves, t + 10, active="region4", since=t - 3000, last_mt=t + 5)[0] is None
    assert sv.pick_save(saves, t + 10, active="autosave 1", since=None)[0]["name"] == "autosave 1"
    assert sv.pick_save([], t, active=None, since=None) == (None, "no fortress save")


def test_crash_restarts_limited_per_6h(W):
    crash_world(W)
    st = {"v": 2, "restarts": [int(W.clock()) - 3600, int(W.clock()) - 600], "down": 5}
    put(W.env.runtime / "supervise.json", json.dumps(st))
    r = run(W)
    assert W.os.calls == [] and "2 restarts in 6 h" in r["alerts"][-1]["msg"]


def test_stale_active_from_an_earlier_session_never_restarts(W):
    put(W.env.runtime / "ACTIVE", "region4", W.clock() - 5000)      # crash leftover
    W.os.started = W.clock() - 1000                                 # Gordon started DF later (unmarked fort)
    make_save(W.env.saves, "autosave 1", W.clock() - 6000)
    r = run(W)
    assert r.get("active_stale") and r["active"] is None and r["alerts"] == []
    W.os.up = False
    for _ in range(3):
        advance(W, 60)
        r = run(W)
    assert W.os.calls == [] and "clean exit" in r["why"]


def test_load_save_cant_find_save_fails_fast(W):
    crash_world(W)
    W.os.load_out = "Can't find save: autosave 1"
    run(W)
    advance(W, 60)
    t = W.clock()
    r = run(W)
    assert r["restart"]["phase"] == "failed" and W.clock() - t < 300
    advance(W, 60)
    r = run(W)                                                       # DF at the title screen, ACTIVE stale
    assert r["active"] is None and any(a["key"] == "restart_failed" for a in r["alerts"])


@pytest.mark.parametrize("delay,phase", [(200, "done"), (10 ** 6, "failed")])
def test_slow_or_failed_steam_start(W, delay, phase):
    crash_world(W)

    def slow_start():
        W.os.calls.append("start")
        at = W.clock() + delay

        def up(t):
            if t >= at:
                W.os.up, W.os.started = True, t
                W.clock.hooks.remove(up)
        W.clock.hooks.append(up)
        return True, sv.STEAM_URL
    W.os.start_df = slow_start
    run(W)
    advance(W, 60)
    r = run(W)
    assert r["restart"]["phase"] == phase, r["restart"]["log"]
    if phase == "failed":
        assert "not running 300 s after" in r["restart"]["log"][-1]
    else:
        assert ("move", 4242, 1) in W.os.calls                       # moved although DF came up late


def test_window_replaced_is_moved_again(W):
    crash_world(W)
    W.os.hwnds = [(0, 111), (12, 222)]
    run(W)
    advance(W, 60)
    r = run(W)
    moves = [c for c in W.os.calls if isinstance(c, tuple) and c[0] == "move"]
    assert moves == [("move", 111, 1), ("move", 222, 1)] and r["restart"]["phase"] == "done"


def test_interrupted_restart_is_marked_failed(W):
    live(W)
    put(W.env.runtime / "supervise.json", json.dumps({"v": 2, "restart": {"phase": "load", "log": []}}))
    run(W)
    st = state(W)
    assert st["restart"]["phase"] == "failed" and "failed" not in st     # fort is live again -> cleared


# ---------------------------------------------------------------- DEGRADED rule
def rows_for(n=60, base=450, end=450, mode="PEACE", now=T0, paused_at=()):
    rows, tick = [], 3 * YEAR
    for i in range(n):
        tps = 0 if i in paused_at else (end if i >= n - 20 else base)
        tick += tps * 30
        rows.append({"wall": int(now - 10 - 30 * (n - 1 - i)), "tick": tick, "mode": mode, "tps": tps, "gap": 400,
                     "gaps3": 0})
    return rows


def test_degraded_rule():
    d = sv.degraded(rows_for(end=200), T0, [], [])
    assert d["on"] and d["base"] == 450 and d["tps"] == 200 and d["pct"] == 44
    assert not sv.degraded(rows_for(end=400), T0, [], [])["on"]
    assert not sv.degraded(rows_for(end=200, paused_at=range(40, 60)), T0, [], [])["on"]   # paused rows ignored
    assert sv.degraded(rows_for(n=10, end=100), T0, [], [])["why"] == "baseline not ready"
    assert sv.degraded(rows_for(n=25, end=100), T0, [], [])["why"] == "window not ready"   # overlaps baseline
    mixed = rows_for(end=200)
    mixed[-5]["mode"] = "ALERT"
    assert not sv.degraded(mixed, T0, [], [])["on"]
    stale = rows_for(end=200)
    assert sv.degraded(stale, T0 + 600, [], [])["why"] == "no recent perf rows"


def test_degraded_session_starts_after_load():
    old = rows_for(n=60, end=450, now=T0 - 4000)                    # earlier session, then a reload
    new = rows_for(n=60, end=450)
    for r in new:
        r["tick"] -= 10 ** 6                                         # loaded save is behind
    assert sv.last_session(old + new)[0] == new[0]


def test_degraded_autosave_freeze():
    rows = rows_for(end=450)
    rows[30]["gap"] = 25000
    assert not sv.degraded(rows, T0, [], [])["on"]                  # long gap without a save
    d = sv.degraded(rows, T0, [rows[30]["wall"] - 3], [])
    assert d["on"] and "freeze 25 s" in d["why"]


def test_kernel_events_are_hints_only():
    rows = rows_for(end=450)                                         # healthy session (review probe)
    assert not sv.degraded(rows, T0, [], [pev(9, rows[0]["tick"] + 5, "freeze")])["on"]   # 29 min old
    assert not sv.degraded(rows, T0, [], [pev(9, rows[-1]["tick"], "tps", tps=200, base=450, pct=44)])["on"]
    assert not sv.degraded(rows, T0, [], [ev(9, "PERF_DEGRADED", "A", rows[-1]["tick"])])["on"]   # no d.why


def test_kernel_tps_event_before_recovery():
    rows = rows_for(end=450)
    for r in rows[26:46]:
        r["tps"] = 200                                               # perf.lua fires at row 45, recovers at 80 %
    e = pev(9, rows[45]["tick"], "tps", tps=200, base=450, pct=44)
    d = sv.degraded(rows, T0, [], [boot(5), e])
    assert not d["on"] and d["pct"] == 83                            # the rows of the window decide


def test_kernel_tps_event_supplies_the_baseline_rows_decide():
    rows = rows_for(n=25, end=200)                                   # own baseline still overlaps the window
    assert sv.degraded(rows, T0, [], [])["why"] == "window not ready"
    hint = pev(9, rows[-1]["tick"], "tps", tps=200, base=450, pct=44)
    d = sv.degraded(rows, T0, [], [boot(5), hint])
    assert d["on"] and d["base"] == 450 and "kernel baseline" in d["why"]
    healthy = rows_for(n=25, end=450)
    assert not sv.degraded(healthy, T0, [], [boot(5), dict(hint, tick=healthy[-1]["tick"])])["on"]


def test_kernel_event_from_an_earlier_timeline_is_ignored():
    rows = rows_for(n=25, end=200)
    dead = pev(9, rows[-1]["tick"] + 10 ** 5, "tps", base=450)      # the abandoned timeline ran further ahead
    assert not sv.degraded(rows, T0, [], [dead, boot(20, rows[0]["tick"])])["on"]
    this = pev(21, rows[-1]["tick"], "tps", base=450)
    assert sv.degraded(rows, T0, [], [dead, boot(20, rows[0]["tick"]), this])["on"]


def test_kernel_freeze_event_needs_a_save():
    rows = rows_for(end=450)
    hint = [boot(5), pev(9, rows[-1]["tick"] + 100, "freeze")]       # its perf row is not written yet
    assert not sv.degraded(rows, T0, [], hint)["on"]                 # sleep/resume, window drag, long apply
    assert not sv.degraded(rows, T0, [T0 - 300], hint)["on"]         # a save, but not at the freeze
    d = sv.degraded(rows, T0, [T0 - 5], hint)
    assert d["on"] and "kernel" in d["why"]


def test_save_tick():
    assert sv.save_tick(3 * YEAR - 6000, 3 * YEAR + 900, YEAR) == 3 * YEAR      # yearly autosave boundary
    assert sv.save_tick(3 * YEAR + 100, 3 * YEAR + 900, YEAR) == 3 * YEAR + 100  # seen after the boundary
    assert sv.save_tick(3 * YEAR - 6000, 3 * YEAR - 10, YEAR) == 3 * YEAR - 6000  # heartbeat not past it yet


def test_seconds_to_autosave():
    assert sv.seconds_to_autosave(3 * YEAR + YEAR - 9000, 2, 450) == pytest.approx(18)
    assert sv.seconds_to_autosave(3 * YEAR, 0, 450) == pytest.approx(YEAR / 450)
    assert sv.seconds_to_autosave(5, 0, None) is None


# ---------------------------------------------------------------- DEGRADED restart
def degraded_world(W, fresh=True, mode="PEACE", paused=False, tick=3 * YEAR + 1000):
    t = W.clock()
    live(W, since=t - 4000, mode=mode, paused=paused, tick=tick)
    write_perf(W, "region4", end_tps=200, end_tick=tick - 8 * 200)   # last row 8 s before the heartbeat
    make_save(W.env.saves, "region3", t - 90000, marker=None, size=40000)
    if fresh:
        make_save(W.env.saves, "autosave 1", t - 10)


def test_degraded_restart_right_after_autosave(W):
    degraded_world(W)
    r = run(W)
    assert r["degraded"]["on"] and r["restart"]["phase"] == "done", r["restart"]
    calls = W.os.calls
    assert calls[0] == "kill" and calls.index("kill") < calls.index("start")
    assert ("move", 4242, 1) in calls and ("dfhack", "load-save", "autosave 1") in calls
    assert W.os.dfhack_verbs() == {"load-save"}
    bks = sv.list_backups(W.env.backups)
    assert [b["src"] for b in bks] == ["autosave 1"]               # copy of exactly what was loaded


@pytest.mark.parametrize("kw,why", [({"mode": "SIEGE"}, "mode SIEGE"), ({"paused": True}, "paused")])
def test_degraded_restart_only_in_peace_unpaused(W, kw, why):
    degraded_world(W, **kw)
    r = run(W)
    assert r["degraded"]["on"] and r["restart"] is None and W.os.calls == []
    assert why in r["actions"][0]


def test_degraded_deferred_by_inbox_tempo_and_gap(W, monkeypatch):
    degraded_world(W)
    monkeypatch.setattr(sv, "_tempo_owner", lambda _d: "inbox")
    r = run(W)
    assert W.os.calls == [] and "tempo" in r["actions"][0]
    monkeypatch.setattr(sv, "_tempo_owner", lambda _d: "mode")
    st = state(W)
    st["restarts"] = [int(W.clock()) - 3000]
    put(W.env.runtime / "supervise.json", json.dumps(st))
    r = run(W)
    assert W.os.calls == [] and "last restart 50 min ago" in r["actions"][0]


def test_degraded_waits_for_far_autosave(W):
    degraded_world(W, fresh=False)
    r = run(W)
    assert W.os.calls == [] and "waits for the next autosave" in r["actions"][0]


def test_degraded_waits_inside_run_for_imminent_autosave(W):
    tick = 4 * YEAR - 200 * 20                                       # 20 s at 200 ticks/s before the new year
    degraded_world(W, fresh=False, tick=tick)
    t0 = W.clock()

    def autosave(t):
        if t >= t0 + 25:
            make_save(W.env.saves, "autosave 2", t)
            W.clock.hooks.remove(autosave)
    W.clock.hooks.append(autosave)
    r = run(W)
    assert any("waiting ~18 s" in a for a in r["actions"]), r["actions"]
    assert r["restart"]["phase"] == "done" and r["restart"]["save"] == "autosave 2"
    assert ("dfhack", "load-save", "autosave 2") in W.os.calls


def test_degraded_wait_aborts_when_mode_leaves_peace(W):
    degraded_world(W, fresh=False, tick=4 * YEAR - 200 * 20)
    t0 = W.clock()

    def siege(t):
        if t >= t0 + 5:
            hb(W.env, "region4", t, mode="SIEGE")
            W.clock.hooks.remove(siege)
    W.clock.hooks.append(siege)
    r = run(W)
    assert W.os.calls == [] and r["restart"] is None and "deferred: mode SIEGE" in r["actions"][-1]


def test_degraded_save_older_than_15_s_is_not_fresh(W):
    degraded_world(W, fresh=False)
    make_save(W.env.saves, "autosave 1", W.clock() - 20)
    r = run(W)
    assert W.os.calls == [] and "waits for the next autosave" in r["actions"][0]


# ---------------------------------------------------------------- DEGRADED restart: no silent rollback
CMD = {"id": "c1", "verb": "plan.reload", "ok": 1}


@pytest.mark.parametrize("late,blocks", [
    (ev(101, "CMD", "C", 3 * YEAR + 500, **CMD), True),               # plan.reload applied after the save
    (ev(101, "MIGRANTS", "B", 3 * YEAR + 500, n=4), True),
    (ev(101, "DEATHS_3PLUS", "A", 3 * YEAR, n=3), True),               # at the save tick counts as after
    (ev(101, "CMD", "C", 3 * YEAR - 500, **CMD), False),              # before the yearly autosave
    (ev(50, "CMD", "C", 3 * YEAR + 500, **CMD), False),               # abandoned timeline (n < BOOT)
    (ev(101, "YEAR_REVIEW", "A", 3 * YEAR + 3, year=2), False),       # emitted by the boundary itself
    (pev(101, 3 * YEAR + 9, "freeze"), False),
    (ev(101, "PROJECT_STAGE", "C", 3 * YEAR + 500, proj="p1", stage="s1", pct=10), False),
])
def test_degraded_restart_never_rolls_back_what_followed_the_save(W, late, blocks):
    degraded_world(W)                                                 # autosave 1 at -10 s, heartbeat 3Y+1000
    write_events(W, "region4", [late, boot(100, 2 * YEAR)] if late["n"] < 100 else [boot(100, 2 * YEAR), late])
    r = run(W)
    if not blocks:
        assert r["restart"]["phase"] == "done", r["restart"]["log"]
        return
    assert W.os.calls == [] and r["restart"]["phase"] == "aborted" and late["type"] in r["restart"]["log"][-1]
    assert state(W).get("restarts", []) == [] and sv.list_backups(W.env.backups) == []   # nothing counted or copied
    advance(W, 60)
    hb(W.env, "region4", W.clock() - 2, tick=3 * YEAR + 13000)
    r = run(W)                                                        # the save is stale now: next autosave
    assert W.os.calls == [] and "waits for the next autosave" in r["actions"][0]


def test_degraded_restart_waits_for_pending_inbox_and_caravan(W, monkeypatch):
    degraded_world(W)
    put(W.env.runtime / "region4" / "inbox" / ".0000000000001-c8.json.tmp", "{}")     # ignored like kern does
    put(W.env.runtime / "region4" / "inbox" / "0000000000002-c9.json", "{}")
    r = run(W)
    assert W.os.calls == [] and "1 inbox command(s) pending" in r["restart"]["log"][-1]
    (W.env.runtime / "region4" / "inbox" / "0000000000002-c9.json").unlink()
    monkeypatch.setattr(sv, "_state_doc", lambda _d: {"trade": {"caravan": 1, "ratio": 0, "done": 0}})
    r = run(W)
    assert W.os.calls == [] and "caravan on the map" in r["restart"]["log"][-1]
    monkeypatch.setattr(sv, "_state_doc", lambda _d: {"trade": {"caravan": 0, "ratio": 0, "done": 1}})
    assert run(W)["restart"]["phase"] == "done"


@pytest.mark.parametrize("cmd_tick,phase", [(None, "done"), (4 * YEAR - 3000, "done"), (4 * YEAR + 100, "aborted")])
def test_degraded_wait_path_uses_the_autosave_boundary(W, cmd_tick, phase):
    degraded_world(W, fresh=False, tick=4 * YEAR - 200 * 20)
    evs = [boot(100, 3 * YEAR), ev(101, "YEAR_REVIEW", "A", 4 * YEAR + 2, year=3)]
    if cmd_tick:
        evs.append(ev(102, "CMD", "C", cmd_tick, **CMD))
    t0 = W.clock()

    def autosave(t):
        if t >= t0 + 25:
            make_save(W.env.saves, "autosave 2", t)
            hb(W.env, "region4", t, tick=4 * YEAR + 300)              # the kernel runs on after the save
            write_events(W, "region4", evs)
            W.clock.hooks.remove(autosave)
    W.clock.hooks.append(autosave)
    r = run(W)
    assert r["restart"]["phase"] == phase, r["restart"]["log"]
    assert ("kill" in W.os.calls) == (phase == "done")


def test_degraded_backup_runs_after_the_kill(W, monkeypatch):
    degraded_world(W)
    seen, real = [], sv.backup

    def spy(env, s, now):
        seen.append(list(W.os.calls))
        return real(env, s, now)
    monkeypatch.setattr(sv, "backup", spy)
    r = run(W)
    assert r["restart"]["phase"] == "done" and seen == [["kill"]]
    assert r["backup"]["ok"] and r["backup"]["name"].startswith("Testfort-autosave_1-")


# ---------------------------------------------------------------- DEGRADED restart: blockers re-checked
def test_live_lock_taken_during_the_wait_stops_the_restart(W):
    degraded_world(W, fresh=False, tick=4 * YEAR - 200 * 20)
    t0 = W.clock()
    lock = {"holder": "WP5", "purpose": "drill L3", "expires": int(t0) + 900}

    def world(t):
        if t >= t0 + 5 and not (W.env.runtime / "live.lock").exists():
            put(W.env.runtime / "live.lock", json.dumps(lock))
        if t >= t0 + 25:
            make_save(W.env.saves, "autosave 2", t)
            W.clock.hooks.remove(world)
    W.clock.hooks.append(world)
    r = run(W)
    assert W.os.calls == [] and r["restart"] is None
    assert "restart deferred: live.lock held by WP5 (drill L3)" in r["actions"][-1]


def test_norestart_flag_rechecked_right_before_the_kill(W):
    degraded_world(W, fresh=False, tick=4 * YEAR - 200 * 20)
    t0 = W.clock()

    def world(t):
        if t >= t0 + 25 and not (W.env.saves / "autosave 2").exists():
            make_save(W.env.saves, "autosave 2", t)
        if t >= t0 + 28:                                              # the poll that finds the save stable
            put(W.env.runtime / sv.NORESTART, "")
            W.clock.hooks.remove(world)
    W.clock.hooks.append(world)
    r = run(W)
    assert W.os.calls == [] and r["restart"]["phase"] == "aborted"
    assert "norestart.flag present" in r["restart"]["log"][-1] and state(W).get("restarts", []) == []


# ---------------------------------------------------------------- state writes are best effort
@pytest.mark.parametrize("fails", [3, 10 ** 6])
def test_state_write_failure_after_the_kill_does_not_stop_the_start(W, monkeypatch, fails):
    degraded_world(W)
    real, n = os.replace, [0]

    def locked(src, dst):                                             # Defender or a reader holds supervise.json
        if Path(dst).name == "supervise.json" and "kill" in W.os.calls and n[0] < fails:
            n[0] += 1
            raise PermissionError(13, "Access is denied", str(dst))
        return real(src, dst)
    monkeypatch.setattr(sv.os, "replace", locked)
    r = run(W)                                                        # must not raise
    assert "start" in W.os.calls and r["restart"]["phase"] == "done", r["restart"]["log"]
    assert ("dfhack", "load-save", "autosave 1") in W.os.calls
    log = (W.env.runtime / "supervise.log").read_text(encoding="utf-8")
    assert "supervise.json write failed" in log
    if fails == 3:                                                    # one flush lost, the next ones land
        st = state(W)
        assert st["last_loaded"]["name"] == "autosave 1" and len(st["restarts"]) == 1
    else:
        assert "ERROR supervise.json not written" in log


def test_dry_run_has_no_side_effects(W):
    degraded_world(W)
    before = sorted(str(p) for p in W.tmp.rglob("*"))
    r = run(W, dry_run=True)
    assert any("would restart DF onto 'autosave 1'" in a for a in r["actions"])
    assert r["backup"] == {"ok": True, "would": "back up autosave 1"}
    assert W.os.calls == [] and sorted(str(p) for p in W.tmp.rglob("*")) == before


# ---------------------------------------------------------------- backups
def test_backup_copies_each_new_save_once(W):
    live(W)
    put(W.env.backups / "foreign" / "x.txt", "keep")
    put(W.env.backups / "v1" / "sicherung-meta.json", json.dumps({"tool": "claude-sicherung"}))
    src = make_save(W.env.saves, "autosave 1", W.clock() - 100)
    r = run(W)
    assert r["backup"]["ok"] and r["backup"]["name"].startswith("Testfort-autosave_1-")
    dst = W.env.backups / r["backup"]["name"]
    assert sorted(p.name for p in dst.iterdir()) == sorted([p.name for p in src.iterdir()] + [sv.BACKUP_META])
    assert (dst / "world.sav").read_bytes() == (src / "world.sav").read_bytes()
    meta = json.loads((dst / sv.BACKUP_META).read_text(encoding="utf-8"))
    assert meta["tool"] == sv.BACKUP_TOOL and meta["src"] == "autosave 1" and meta["fort"][:2] == ["region4", 1000]
    advance(W, 60)
    hb(W.env, "region4", W.clock() - 2)
    assert "already backed up" in run(W)["backup"]["skip"]
    assert (W.env.backups / "foreign" / "x.txt").exists() and (W.env.backups / "v1").exists()


def test_backup_skips_unmarked_and_busy_saves(W):
    live(W)
    make_save(W.env.saves, "region3", W.clock() - 100, marker=None)
    assert run(W)["backup"] is None
    make_save(W.env.saves, "autosave 1", W.clock() - 50)
    put(W.env.saves / "current" / "world.sav", b"partial")
    r = run(W)
    assert "being written" in r["backup"]["skip"] and not W.env.backups.exists()


def test_backup_rotation():
    day = 86400
    bs = [{"name": f"b{i}", "created": T0 - i * day / 2, "size": 10} for i in range(8)]
    keep, drop = sv.plan_rotation(bs)
    assert keep[:3] == ["b0", "b1", "b2"] and set(keep) | set(drop) == {b["name"] for b in bs}
    days = {sv.datetime.fromtimestamp(b["created"]).date() for b in bs if b["name"] in keep[3:]}
    assert len(days) == len(keep[3:])                               # one per older day
    keep, drop = sv.plan_rotation(bs, cap=25)
    assert keep == ["b0", "b1"]
    assert sv.plan_rotation(bs[:1], cap=1)[0] == ["b0"]            # the newest always stays


def test_backup_rotation_deletes_only_own_folders(W):
    for i in range(5):
        put(W.env.backups / f"old{i}" / sv.BACKUP_META,
            json.dumps({"tool": sv.BACKUP_TOOL, "created": T0 - 3600 * (i + 1), "size": 10, "src": f"s{i}"}))
    put(W.env.backups / "foreign" / "a.txt", "x")
    s = sv.scan_saves(make_save(W.env.saves, "autosave 1", W.clock() - 100).parent, {}, W.clock())[0]
    r = sv.backup(W.env, s, W.clock())
    assert r["ok"] and len(r["dropped"]) >= 1
    left = {p.name for p in W.env.backups.iterdir()}
    assert "foreign" in left and r["name"] in left and not (set(r["dropped"]) & left)


# ---------------------------------------------------------------- helpers, CLI
def test_marker_of(tmp_path):
    d = make_save(tmp_path, "a", T0)
    assert sv.marker_of(d) == ["region4", 1000, "Testfort"]
    assert sv.marker_of(make_save(tmp_path, "b", T0, marker=None)) is None
    put(tmp_path / "c" / "dfhack-entity-1.dat", '[{"k":"dfllm","s":"{broken')
    assert sv.marker_of(tmp_path / "c") is None


def test_tail_lines_drops_torn_line(tmp_path):
    p = tmp_path / "e.jsonl"
    p.write_bytes(b'{"n":1}\n{"n":2}\n{"n":')
    assert sv.tail_lines(p) == ['{"n":1}', '{"n":2}']
    p.write_bytes(b"x" * 100 + b"\nline2\n")
    assert sv.tail_lines(p, max_bytes=10) == ["line2"]


def test_run_lock(W):
    live(W)
    put(W.env.runtime / "supervise.lock", "1 2", W.clock() - 10)
    assert "another supervise run" in run(W)["why"]
    os.utime(W.env.runtime / "supervise.lock", (W.clock() - 4000, W.clock() - 4000))
    assert run(W)["live"]


def test_main_once_json_and_reset(W, capsys):
    live(W)
    assert sv.main(["--once", "--json"], env=W.env) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["live"] is True
    put(W.env.runtime / "supervise.json", json.dumps({"v": 2, "restarts": [1], "failed": {"msg": "x"}}))
    assert sv.main(["--reset"], env=W.env) == 0
    st = state(W)
    assert "restarts" not in st and "failed" not in st
    assert sv.main(["--once"], env=W.env) == 0 and "supervise: DF up" in capsys.readouterr().out


@pytest.mark.skipif(sys.platform != "win32", reason="ctypes Win32 bindings")
def test_win32_bindings_smoke():
    import time
    assert abs(sv.proc_start(os.getpid()) - time.time()) < 3600
    h = sv.WinOS(Path("."), Path(".")).df_window()                   # DF is not running in tests
    assert h is None or isinstance(h, int)
