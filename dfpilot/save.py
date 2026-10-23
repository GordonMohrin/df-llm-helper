"""`dfllm save`: DFHack's `quicksave` from outside, verified by the DF save folder's file times.

Live Run 10 (y421): after a graphics crash `dfhack-run quicksave` wrote nothing (no error, no file, empty output) and the
restart loaded a state 30 game days older. So a quicksave counts only when a fortress save folder under
`<saves>/` (DF's `save/`, as supervise finds it) holds a `world.sav` written after the call, DF is done writing
(`save/current` empty, no file younger than supervise.STABLE_S) and, when the fort's dfllm marker is known, the folder
carries the same marker. The call waits up to `--timeout` s (1 s polls, files only).

Every attempt is recorded in `<save>/quicksave.json` (kind `quicksave`: wall, ok, by, why, folder, secs, last, last_age,
fails, paused) and as a cli.log line; a failure prints `QUICKSAVE_FAILED: ...` and exits 1, and `dfllm follow` wakes
the LLM with a QUICKSAVE_FAILED line (class A, RULES §7). Refused (exit 3): in SIEGE, BREACH or DRILL, within
`--min-gap` s (600) after a verified save or RETRY_S (120) after a failed one (`--min-gap 0` lifts both), or with no
fort loaded (no ACTIVE). Never a Lua quicksave (RULES §10: they froze the game); `dfllm save` is the only way the
project runs `quicksave` (tools/run_watch.py calls it once a game year).

BUG-069 (Run 13 y506: QUICKSAVE_FAILED after 122 s while quicksaves take 54-110 s in a big world and the newest save was an
autosave 12 min old): the wait follows the real duration. The base wait is `wait_s` (180); while DF is writing (files below
`save/current`, which DF fills during a save and empties after the move) it goes on up to `max_wait_s` (600). A save still being
written at the limit is `state running` (exit 4, QUICKSAVE_RUNNING, no wake), not a failure; the next call (or follow) settles
it: a folder that landed later turns the record into ok with `late` (the live answer to "failed or only slow?"), a save that
stopped without a folder becomes `failed` (kind `vanished`). `state failed` has a kind: `call` (dfhack-run failed) or `silent`
(DF started no save: save/current stayed empty). No second quicksave starts while DF writes or while a verified autosave of
this fort is younger than `autosave_fresh_s` (300): that autosave is the save (exit 0, "not needed"; `--min-gap 0` forces).
The limits are `--timeout`/`--max-wait` or config/baseline.json "save" (validated by lint --config).
"""
from __future__ import annotations

from pathlib import Path

from . import files, paths, schema, supervise

RECORD = "quicksave.json"
MIN_GAP_S = 600                # after a verified save
RETRY_S = 120                  # after a failed one
WAIT_S = 180                   # how long a call waits for the folder when DF shows no sign of writing (BUG-069: was 120)
MAX_WAIT_S = 600               # the longest it waits while DF is demonstrably writing save/current
WRITE_FRESH_S = 60             # a file below save/current younger than this = DF is writing
AUTOSAVE_FRESH_S = 300         # a verified autosave younger than this is the save: no second quicksave
RUNNING_GRACE_S = 120          # a `running` record whose writing stopped this long ago and landed nothing = failed
LATE_MAX_S = 600               # a folder that landed up to this long after the end of the wait still belongs to the call
EXIT_RUNNING = 4               # `dfllm save`: still being written, no verdict yet
CALL_S = 90                    # dfhack-run quicksave itself
FAIL_WAIT_S = 10               # waiting on after dfhack-run itself failed (DF gone, DFHack not answering)
SLACK_S = 2                    # file times vs the wall clock (a save written in the call's second counts)
REFUSE_MODES = ("SIEGE", "BREACH", "DRILL")


def read_record(save_dir: Path) -> dict | None:
    doc = files.read_json(Path(save_dir) / RECORD, retry=False)
    return doc if isinstance(doc, dict) and not schema.validate("quicksave", doc) else None


def _age(now: float, t: float | None) -> int:
    return int(max(0.0, now - t)) if t else -1


def _clip(text: str, n: int) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text.encode("utf-8")) <= n else text.encode("utf-8")[:n - 3].decode("utf-8", "ignore") + "..."


def limits() -> dict:
    """BUG-069: wait_s, max_wait_s, autosave_fresh_s from config/baseline.json "save" (a missing file or a bad value =
    the built-in default; `lint --config` reports the bad ones)."""
    out = {"wait_s": WAIT_S, "max_wait_s": MAX_WAIT_S, "autosave_fresh_s": AUTOSAVE_FRESH_S}
    doc = files.read_json(paths.config_dir() / "baseline.json", retry=False)
    sec = doc.get("save") if isinstance(doc, dict) else None
    if isinstance(sec, dict):
        from .fairplay import SAVE_LIM
        for k, (lo, hi) in SAVE_LIM.items():
            v = sec.get(k)
            if isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi:
                out[k] = v
    out["max_wait_s"] = max(out["max_wait_s"], out["wait_s"])
    return out


def is_writing(saves: Path, now: float) -> tuple[int, int]:
    """(files, age of the newest in s) of an active write below save/current, else (0, -1)."""
    n, newest = supervise.writing(saves)
    if n and now - newest <= WRITE_FRESH_S:
        return n, int(max(0.0, now - newest))
    return 0, -1


def _fresh_autosave(env: supervise.Env, save_dir: Path, now: float, fresh_s: float) -> dict | None:
    """A verified autosave of this fort younger than fresh_s (a complete folder, same marker)."""
    cache: dict = {}
    saves = supervise.scan_saves(env.saves, cache, now)
    ident = supervise.ident_of(saves, supervise.loaded_save(env.runtime, Path(save_dir).name))
    for e in saves:
        if (e["name"].startswith("autosave") and 0 <= now - e["mt"] < fresh_s and now - e["newest"] >= supervise.STABLE_S
                and not (ident and e["marker"] and e["marker"][:2] != list(ident[:2])) and (ident or e["marker"])):
            return e
    return None


def refusal(save_dir: Path, state: dict | None, now: float, min_gap: float, active: str | None,
            env: supervise.Env | None = None) -> str | None:
    """Why `dfllm save` does not run now, or None. With env (the save folder is known): DF writes a save right now
    (BUG-069: an autosave or an earlier quicksave; never a second one on top)."""
    if active is None:
        return "no fort loaded (no ACTIVE): DF saves nothing on the title screen"
    mode = (state or {}).get("mode")
    if mode in REFUSE_MODES:
        return f"mode {mode}: no save freeze in a fight or a drill (the arbiter holds the clock); after it ends"
    if env is not None:
        n, age = is_writing(env.saves, now)
        if n:
            return (f"DF is writing a save (save/current: {n} file(s), newest {age} s ago): an autosave or a quicksave is in "
                    "progress, no second one on top; try again in a minute")
    rec = read_record(save_dir)
    if rec and min_gap > 0:
        gap = min_gap if rec["ok"] else min(min_gap, RETRY_S)
        left = rec["wall"] + gap - now
        if left > 0:
            kind = "verified" if rec["ok"] else "running" if rec.get("state") == "running" else "failed"
            return (f"rate limit: the last {kind} quicksave was "
                    f"{int(now - rec['wall'])} s ago (next in {int(left) + 1} s; --min-gap 0 forces it)")
    return None


def settle(env: supervise.Env, save_dir: Path, now: float | None = None) -> dict | None:
    """BUG-069: look at the last record again. A failed or running attempt (within a day) whose save folder landed after
    all becomes ok with `late` (seconds after the end of the wait: the live answer to "failed or only slow?"); a `running`
    one that DF stopped writing RUNNING_GRACE_S ago without a folder becomes failed (kind `vanished`). Returns the record
    (rewritten when it changed), None without one."""
    rec = read_record(save_dir)
    now = env.clock() if now is None else now
    if rec is None or rec["ok"] or now - rec["wall"] > 86400:
        return rec
    cache: dict = {}
    saves = supervise.scan_saves(env.saves, cache, now)
    ident = supervise.ident_of(saves, supervise.loaded_save(env.runtime, Path(save_dir).name))
    n, _age = is_writing(env.saves, now)
    secs = rec.get("secs", 0)
    # only a folder close to the call is its save: an autosave an hour later says nothing about it
    fresh = [e for e in saves if rec["wall"] - SLACK_S <= e["mt"] <= rec["wall"] + secs + LATE_MAX_S
             and not (ident and e["marker"] and e["marker"][:2] != list(ident[:2]))]
    if fresh and not n and not supervise.busy(env.saves) and now - fresh[0]["newest"] >= supervise.STABLE_S:
        got = fresh[0]
        after = max(0, int(got["mt"] - rec["wall"]))
        new = dict(rec, ok=1, state="ok", kind="late", folder=got["name"][:120], fails=0, late=max(0, after - secs),
                   why=_clip(f"{got['name']} written {after} s after the call (late: the wait had ended at {secs} s)", 200))
    elif rec.get("state") == "running" and not n and now - (rec["wall"] + secs) > RUNNING_GRACE_S:
        new = dict(rec, ok=0, state="failed", kind="vanished", fails=rec.get("fails", 0) + 1,
                   why=_clip(f"DF stopped writing save/current {int(now - rec['wall'] - secs)} s after the wait ended and no "
                             f"fortress save folder landed (the save was lost or never finished); the call was {int(now - rec['wall'])} "
                             "s ago", 200))
    else:
        return rec
    if schema.validate("quicksave", new):
        return rec
    files.write_json_atomic(Path(save_dir) / RECORD, new)
    files.log_cli(save_dir, new["by"], "quicksave", {"settle": 1}, ("ok " if new["ok"] else "QUICKSAVE_FAILED ") + new["why"])
    return new


def quicksave(env: supervise.Env, save_dir: Path, by: str = "cli", timeout: float = WAIT_S, poll: float = 1.0,
              state: dict | None = None, max_wait: float | None = None) -> dict:
    """Run DFHack `quicksave` and wait for the folder; returns the record (also written to <save>/quicksave.json).
    The wait ends at `timeout` s unless DF is writing save/current then; it goes on up to `max_wait` (default
    MAX_WAIT_S, at least `timeout`) while it is (BUG-069)."""
    clk = env.clock
    t0 = clk()
    cache: dict = {}
    before = supervise.scan_saves(env.saves, cache, t0)
    loaded = supervise.loaded_save(env.runtime, Path(save_dir).name)
    ident = supervise.ident_of(before, loaded)
    last = before[0] if before else None
    ok_run, out = env.os.dfhack("quicksave", timeout=CALL_S)
    out = _clip(out, 120)
    base = max(0.0, timeout) if ok_run else min(max(0.0, timeout), FAIL_WAIT_S)
    hard = max(base, float(MAX_WAIT_S if max_wait is None else max_wait)) if ok_run else base
    deadline, hard_at = clk() + base, t0 + hard
    got, busy, wn, wage = None, False, 0, -1
    while True:
        now = clk()
        saves = supervise.scan_saves(env.saves, cache, now)
        busy = supervise.busy(env.saves)
        wn, wage = is_writing(env.saves, now)
        fresh = [e for e in saves if e["mt"] >= t0 - SLACK_S
                 and not (ident and e["marker"] and e["marker"][:2] != list(ident[:2]))]
        if fresh and not busy and not wn and now - fresh[0]["newest"] >= supervise.STABLE_S:
            got = fresh[0]
            break
        if now >= hard_at or (now >= deadline and not wn and not fresh):   # a fresh folder: let it settle
            break
        env.sleep(poll)
    now = clk()
    prev = read_record(save_dir)
    paused = 1 if (state or {}).get("t", {}).get("paused") else 0
    secs = int(max(0.0, now - t0))
    rec = {"v": 2, "wall": int(t0), "by": by, "secs": secs, "paused": paused, "limit": int(hard),
           "last": (last or {}).get("name", "")[:120], "last_age": _age(t0, (last or {}).get("mt"))}
    if got:
        rec.update(ok=1, state="ok", kind="quicksave", folder=got["name"][:120], fails=0,
                   why=_clip(f"{got['name']} written {max(0, int(got['mt'] - t0))} s after the call", 200))
    else:
        said = f"dfhack-run said '{out}'" if out else "dfhack-run printed nothing"
        lastw = (f"; the newest save is '{rec['last']}' from {rec['last_age'] // 60} min ago" if rec["last"]
                 else "; no fortress save at all")
        pz = " with the game paused" if paused else ""
        fails = ((prev or {}).get("fails", 0) + 1) if prev and not prev["ok"] else 1
        if not ok_run:
            rec.update(ok=0, state="failed", kind="call", folder="", fails=fails,
                       why=_clip(f"dfhack-run quicksave failed ({out or 'no output'}){pz}{lastw}", 200))
        elif wn or busy:
            rec.update(ok=0, state="running", kind="writing", folder="", fails=(prev or {}).get("fails", 0) if prev and not prev["ok"] else 0,
                       why=_clip(f"still being written after {secs} s: DF writes save/current ({max(wn, 1)} file(s), newest "
                                 f"{max(wage, 0)} s ago); not a failure yet, `dfllm save` settles it and starts no second one "
                                 f"({said}){pz}{lastw}", 200))
        else:
            rec.update(ok=0, state="failed", kind="silent", folder="", fails=fails,
                       why=_clip(f"no fortress save folder newer than the call after {secs} s ({said}; DF started no save: "
                                 f"save/current stayed empty){pz}{lastw}", 200))
    errs = schema.validate("quicksave", rec)
    if errs:                                       # a bug here must not hide the result
        rec = {"v": 2, "wall": int(t0), "ok": rec.get("ok", 0), "by": by, "why": _clip(rec.get("why", ""), 200)}
    files.write_json_atomic(Path(save_dir) / RECORD, rec)
    files.log_cli(save_dir, by, "quicksave", {"timeout": int(timeout)},
                  ("ok " if rec["ok"] else "QUICKSAVE_RUNNING " if rec.get("state") == "running" else "QUICKSAVE_FAILED ")
                  + rec["why"])
    return rec


def run(args, save_dir: Path, env: supervise.Env | None = None) -> int:
    env = env or supervise.default_env()
    lim = limits()
    state = files.read_state(save_dir)
    before = read_record(save_dir)
    rec = settle(env, save_dir)                      # BUG-069: an earlier attempt that landed late / vanished
    if before and not before["ok"] and rec and rec["ok"]:
        print(f"quicksave ok: the earlier attempt landed after the wait: {rec['why']} (no second quicksave)")
        return 0
    why = refusal(save_dir, state, env.clock(), args.min_gap, paths.active_save(), env)
    if not why and args.min_gap > 0 and not getattr(args, "dry_run", False):
        auto = _fresh_autosave(env, save_dir, env.clock(), lim["autosave_fresh_s"])
        if auto:                                     # the yearly autosave just saved the fort: that is the save
            age = int(max(0.0, env.clock() - auto["mt"]))
            msg = _clip(f"not needed: '{auto['name']}' saved the fort {age} s ago (an autosave; --min-gap 0 forces a quicksave)", 200)
            files.write_json_atomic(Path(save_dir) / RECORD, {
                "v": 2, "wall": int(env.clock()), "ok": 1, "state": "ok", "kind": "autosave", "by": args.by,
                "why": msg, "folder": auto["name"][:120], "fails": 0})
            files.log_cli(save_dir, args.by, "quicksave", {}, "ok " + msg)
            print(f"quicksave {msg}")
            return 0
    if why:
        print(f"quicksave refused: {why}")
        files.log_cli(save_dir, args.by, "quicksave", {}, f"refused: {why}")
        return 3
    timeout = args.timeout if args.timeout is not None else lim["wait_s"]
    max_wait = getattr(args, "max_wait", None)
    max_wait = lim["max_wait_s"] if max_wait is None else max_wait
    if args.dry_run:
        print(f"quicksave would run now (dfhack-run quicksave, then up to {int(timeout)} s for a new folder in "
              f"{env.saves}, up to {int(max(timeout, max_wait))} s while DF writes)")
        return 0
    rec = quicksave(env, save_dir, by=args.by, timeout=timeout, state=state, max_wait=max_wait)
    if rec["ok"]:
        print(f"quicksave ok: {rec['why']}")
        return 0
    if rec.get("state") == "running":
        print(f"QUICKSAVE_RUNNING: {rec['why']} (exit {EXIT_RUNNING}; no failure wake; look again with dfllm save in a minute)")
        return EXIT_RUNNING
    print(f"QUICKSAVE_FAILED: {rec['why']} (attempt {rec.get('fails', 1)}; follow wakes the LLM; save by hand: "
          "Esc > Save game, or dfllm save again in 2 min)")
    return 1


def add_parser(sub) -> None:
    p = sub.add_parser("save", help="DFHack quicksave, verified by the save folder's file times (Run 10)")
    p.add_argument("--timeout", type=float, default=None,
                   help=f"seconds to wait for the new folder ({WAIT_S}; config baseline.json save.wait_s)")
    p.add_argument("--max-wait", type=float, default=None, dest="max_wait",
                   help=f"seconds to wait in all while DF is writing save/current ({MAX_WAIT_S}; save.max_wait_s)")
    p.add_argument("--min-gap", type=float, default=MIN_GAP_S,
                   help=f"seconds after a verified save ({MIN_GAP_S}; {RETRY_S} after a failed one; 0: no limit)")
    p.add_argument("--by", default="cli", choices=["llm", "cli", "gordon"])
    p.add_argument("--dry-run", action="store_true")
