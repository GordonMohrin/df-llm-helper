"""FR-91 (Run 14 note 99): load the newest complete save at the title screen without a player.

`dfllm supervise --load [SAVE]` picks the save by the rules of loadsave.py (newest COMPLETE save of a dfllm fort, never an
older one, never `_tmp`), tells which one it is (name, fort, game year/day, age) and loads it through the same chain as the
crash restart (supervise.load_chain: DFHack's own load-save, then the title-screen run of tools/embark/embark.lua; no mouse
of the player, the run injects its clicks into the game). `--saves` lists the save folders with the reason each is not loadable.
Nothing here kills or starts DF; DF must run at the title screen (a restart is supervise --once).
"""
from __future__ import annotations

import time
from pathlib import Path

from . import loadsave
from . import supervise as sv
from .events import fmt_age, fmt_tick

NOW_LOAD_MAX_S = 300           # a manual load waits this long for the load to start, and again for the fort's first beat
GAME_ROW_AGE_S = 1200          # a perf row older than this before the save says nothing about its game time


def game_tick(perf: Path, mt: float) -> int | None:
    """Abs game tick of a save: the tick of the last perf.csv row written at or before the save (the kernel logs one every
    30 s), at most GAME_ROW_AGE_S before it; None when the log holds no such row (a lower bound, within the row spacing)."""
    best = None
    for r in sv.perf_rows(perf):
        if r["wall"] <= mt + 5 and mt - r["wall"] <= GAME_ROW_AGE_S:
            best = r["tick"]
    return best


def describe(env: sv.Env, e: dict, now: float) -> str:
    """'autosave 2' (fort Testfort, game time ~y3 sum d12, saved 12m ago): the answer of note 99 (b)."""
    mk = e.get("marker")
    tick = game_tick(env.runtime / mk[0] / "perf.csv", e["mt"]) if mk else None
    game = f"game time ~{fmt_tick(tick)}" if tick is not None else "game time unknown"
    return f"'{e['name']}' (fort {mk[2] if mk else '?'}, {game}, saved {fmt_age(max(0.0, now - e['mt']))} ago)"


def choose(saves: list, want: str | None, last_mt: float = 0.0) -> tuple[dict | None, str, list]:
    """(save, why-not, notes): the save to load. Without `want` the newest complete save with a dfllm marker; with it that
    save, if it is complete, ours and the newest complete one of its fort (never an older one: no save scumming). notes
    name the newer saves that are not loaded and why."""
    ok = loadsave.complete(saves)
    if want:
        e = next((x for x in saves if x["name"] == want), None)
        if e is None:
            return None, f"no save folder '{want}' (have: {', '.join(x['name'] for x in saves[:6]) or 'none'})", []
        if e.get("bad"):
            return None, f"'{want}' is not complete: {e['bad']}", []
        if not e["marker"]:
            return None, f"'{want}' has no dfllm marker: not a fort of ours (the player's own forts stay untouched)", []
        newer = [x for x in ok if x["marker"] and x["marker"][:2] == e["marker"][:2] and x["mt"] > e["mt"]]
        if newer:
            return None, (f"'{want}' is older than '{newer[0]['name']}' of the same fort: never an older save "
                          "(no save scumming); name the newer one or omit the name"), []
        return e, "", []
    marked = [x for x in ok if x["marker"]]
    if not marked:
        return None, "no complete save with a dfllm marker" + (
            f" ({len(saves)} save folder(s); `--saves` says why each is not loadable)" if saves else " (no save folder)"), []
    e = marked[0]
    if e["mt"] < last_mt:
        return None, f"newest complete save '{e['name']}' is older than the save loaded last", []
    notes = [f"not loaded: '{x['name']}' ({x['bad']})" for x in saves if x.get("bad") and x["mt"] >= e["mt"]]
    notes += [f"ignored newer '{x['name']}' (no dfllm marker)" for x in ok if x["mt"] > e["mt"] and not x["marker"]]
    return e, "", notes


def saves_lines(env: sv.Env, st: dict, now: float) -> list[str]:
    """`supervise --saves`: every save folder, newest first, with what keeps it from being loaded."""
    saves = sv.scan_saves(env.saves, st.setdefault("scan", {}), now, partial=True)
    out = []
    for e in saves:
        mk = e.get("marker")
        stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(e["mt"]))
        out.append(f"{e['name']:<20} {stamp} {fmt_age(max(0.0, now - e['mt'])):>5} ago  fort {mk[2] if mk else '-':<12}"
                   + (f" NOT LOADABLE: {e['bad']}" if e.get("bad") else " complete" + ("" if mk else ", no dfllm marker")))
    return out or [f"no save folder in {env.saves}"]


def load_now(env: sv.Env, want: str | None = None, *, dry_run: bool = False) -> tuple[int, str]:
    """(exit code, text). Refuses, with the reason, when DF is not running, a dfllm fort is loaded already, a player holds
    the game (norestart.flag, live.lock) or no save may be loaded; never touches a running fort."""
    now = env.clock()
    st = sv.load_state(env)
    saves = sv.scan_saves(env.saves, st.setdefault("scan", {}), now, partial=True)
    s, why, notes = choose(saves, want, (st.get("last_loaded") or {}).get("mt", 0.0))
    if s is None:
        return 1, f"load: {why}"
    head = "load: " + describe(env, s, now) + ("; " + "; ".join(notes) if notes else "")
    proc, started = env.os.df_proc()
    name, amt = sv.read_active(env.runtime)
    refuse = ""
    if proc == "down":
        refuse = "DF is not running (a restart is `supervise --once`; --load only loads at the title screen)"
    elif proc != "up":
        refuse = "DF process state unknown (tasklist failed)"
    elif name and amt is not None and started and amt >= started - 5:
        age, _hb = sv.read_heartbeat(env.runtime / name / "heartbeat", now)
        refuse = (f"a dfllm fort is loaded already ('{name}', heartbeat "
                  f"{'missing' if age is None else fmt_age(age) + ' old'}): nothing to load")
    else:
        refuse = sv._hands_off(env) or ""
    if dry_run:
        return 0, head + (f" (dry run; would not load now: {refuse})" if refuse else " (dry run: nothing loaded)")
    if refuse:
        return 1, f"{head}; not loading: {refuse}"
    lock = sv._run_lock(env, now)
    if lock is None:
        return 1, f"{head}; not loading: another supervise run holds supervise.lock (a restart chain is running)"
    try:
        t0 = env.clock()
        rs = st["restart"] = {"why": "manual load", "save": s["name"], "save_mt": s["mt"], "kill": False, "t0": int(t0),
                              "phase": "start", "log": []}

        def flush() -> None:
            sv._write_json(env.runtime / "supervise.json", st, env.sleep)
        step, fail = sv.chain_log(env, st, rs, t0, flush)
        st.pop(sv.CLICK_KEY, None)
        try:
            sv.load_chain(env, st, s, step, fail, t0, t0, NOW_LOAD_MAX_S, NOW_LOAD_MAX_S)
        except Exception as e:  # noqa: BLE001 - say what broke, keep the record
            fail(f"{type(e).__name__}: {e}"[:200])
        done = rs["phase"] == "done"
        tail = rs["log"][-1] if rs["log"] else ""
        flush()
    finally:
        try:
            lock.unlink()
        except OSError:
            pass
    ver = (st.get("dfhack") or {}).get("ver")
    if done:
        return 0, f"{head}; loaded: {tail}" + (f" (DFHack {ver})" if ver else "")
    return 1, f"{head}; NOT loaded: {tail}"
