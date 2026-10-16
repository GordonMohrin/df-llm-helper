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
"""
from __future__ import annotations

from pathlib import Path

from . import files, paths, schema, supervise

RECORD = "quicksave.json"
MIN_GAP_S = 600                # after a verified save
RETRY_S = 120                  # after a failed one
WAIT_S = 120                   # how long a call waits for the folder
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


def refusal(save_dir: Path, state: dict | None, now: float, min_gap: float, active: str | None) -> str | None:
    """Why `dfllm save` does not run now, or None."""
    if active is None:
        return "no fort loaded (no ACTIVE): DF saves nothing on the title screen"
    mode = (state or {}).get("mode")
    if mode in REFUSE_MODES:
        return f"mode {mode}: no save freeze in a fight or a drill (the arbiter holds the clock); after it ends"
    rec = read_record(save_dir)
    if rec and min_gap > 0:
        gap = min_gap if rec["ok"] else min(min_gap, RETRY_S)
        left = rec["wall"] + gap - now
        if left > 0:
            return (f"rate limit: the last {'verified' if rec['ok'] else 'failed'} quicksave was "
                    f"{int(now - rec['wall'])} s ago (next in {int(left) + 1} s; --min-gap 0 forces it)")
    return None


def quicksave(env: supervise.Env, save_dir: Path, by: str = "cli", timeout: float = WAIT_S, poll: float = 1.0,
              state: dict | None = None) -> dict:
    """Run DFHack `quicksave` and wait for the folder; returns the record (also written to <save>/quicksave.json)."""
    clk = env.clock
    t0 = clk()
    cache: dict = {}
    before = supervise.scan_saves(env.saves, cache, t0)
    loaded = supervise.loaded_save(env.runtime, Path(save_dir).name)
    ident = supervise.ident_of(before, loaded)
    last = before[0] if before else None
    ok_run, out = env.os.dfhack("quicksave", timeout=CALL_S)
    out = _clip(out, 120)
    deadline = clk() + (max(0.0, timeout) if ok_run else min(max(0.0, timeout), FAIL_WAIT_S))
    got, busy = None, False
    while True:
        now = clk()
        saves = supervise.scan_saves(env.saves, cache, now)
        busy = supervise.busy(env.saves)
        fresh = [e for e in saves if e["mt"] >= t0 - SLACK_S
                 and not (ident and e["marker"] and e["marker"][:2] != list(ident[:2]))]
        if fresh and not busy and now - fresh[0]["newest"] >= supervise.STABLE_S:
            got = fresh[0]
            break
        if now >= deadline:
            break
        env.sleep(poll)
    now = clk()
    prev = read_record(save_dir)
    paused = 1 if (state or {}).get("t", {}).get("paused") else 0
    rec = {"v": 2, "wall": int(t0), "by": by, "secs": int(max(0.0, now - t0)), "paused": paused,
           "last": (last or {}).get("name", "")[:120], "last_age": _age(t0, (last or {}).get("mt"))}
    if got:
        rec.update(ok=1, folder=got["name"][:120], fails=0,
                   why=_clip(f"{got['name']} written {max(0, int(got['mt'] - t0))} s after the call", 200))
    else:
        said = f"dfhack-run said '{out}'" if out else "dfhack-run printed nothing"
        if not ok_run:
            said = f"dfhack-run quicksave failed ({out or 'no output'})"
        what = ("DF was still writing save/current" if busy else
                f"no fortress save folder newer than the call after {int(now - t0)} s")
        lastw = (f"; the newest save is '{rec['last']}' from {rec['last_age'] // 60} min ago" if rec["last"]
                 else "; no fortress save at all")
        rec.update(ok=0, folder="", fails=((prev or {}).get("fails", 0) + 1) if prev and not prev["ok"] else 1,
                   why=_clip(f"{what} ({said}){' with the game paused' if paused else ''}{lastw}", 200))
    errs = schema.validate("quicksave", rec)
    if errs:                                       # a bug here must not hide the result
        rec = {"v": 2, "wall": int(t0), "ok": rec.get("ok", 0), "by": by, "why": _clip(rec.get("why", ""), 200)}
    files.write_json_atomic(Path(save_dir) / RECORD, rec)
    files.log_cli(save_dir, by, "quicksave", {"timeout": int(timeout)},
                  ("ok " if rec["ok"] else "QUICKSAVE_FAILED ") + rec["why"])
    return rec


def run(args, save_dir: Path, env: supervise.Env | None = None) -> int:
    env = env or supervise.default_env()
    state = files.read_state(save_dir)
    why = refusal(save_dir, state, env.clock(), args.min_gap, paths.active_save())
    if why:
        print(f"quicksave refused: {why}")
        files.log_cli(save_dir, args.by, "quicksave", {}, f"refused: {why}")
        return 3
    if args.dry_run:
        print(f"quicksave would run now (dfhack-run quicksave, then up to {int(args.timeout)} s for a new folder in "
              f"{env.saves})")
        return 0
    rec = quicksave(env, save_dir, by=args.by, timeout=args.timeout, state=state)
    if rec["ok"]:
        print(f"quicksave ok: {rec['why']}")
        return 0
    print(f"QUICKSAVE_FAILED: {rec['why']} (attempt {rec.get('fails', 1)}; follow wakes the LLM; save by hand: "
          "Esc > Save game, or dfllm save again in 2 min)")
    return 1


def add_parser(sub) -> None:
    p = sub.add_parser("save", help="DFHack quicksave, verified by the save folder's file times (Run 10)")
    p.add_argument("--timeout", type=float, default=WAIT_S, help=f"seconds to wait for the new folder ({WAIT_S})")
    p.add_argument("--min-gap", type=float, default=MIN_GAP_S,
                   help=f"seconds after a verified save ({MIN_GAP_S}; {RETRY_S} after a failed one; 0: no limit)")
    p.add_argument("--by", default="cli", choices=["llm", "cli", "gordon"])
    p.add_argument("--dry-run", action="store_true")
