"""`dfllm doctor`: speed and health from perf.csv, state, heartbeat and events (DESIGN §10, §14). 0 DF calls."""
from __future__ import annotations

import csv
import json
import os
import re
import statistics
import time
from pathlib import Path

from . import files, paths
from .events import fmt_age

WINDOW_S = 600
TPS_MIN = {"PEACE": 450, "SIEGE": 100, "DRILL": 100}     # §14 (PEACE at pop <= 55)
KERN_MS_S, HB_MAX_S, INBOX_STUCK_S = 25, 120, 10
EVENTS_WARN_B = 5 << 20
# kernel budget for the fort size, mirrors lua/dfllm/util/sched.lua (S.LOAD.units, S.BUDGET; FR-62): 25 ms/s on the
# reference fort (150 units), +6 per 150 units above it (critical modules scan every unit), at most 40
LOAD_UNITS, BUDGET_PER_UNIT, BUDGET_MAX = 150, 6, 40
# perf.csv mods keys that are not cost owners: DFHack's counter for the whole frame callback (a cross-check); BUG-033:
# 'caller>callee' keys are the part of the caller's own entry spent in another module's code (its K.calls)
NOT_OWNERS = ("repeat",)
# BUG-033: a snapshot request waiting this long (state snap.old_s) is a starving export queue
SNAP_STARVE_S = 300
# BUG-070: perf.csv carries the frame gaps > 3 s by cause as `gap:<cause>` (ms) and `gapn:<cause>` (count); the cause is a
# module name (ours), `save` (a DF save explains it: DESIGN §10 target <= 15 s) or `external` (nothing explains it)
SAVE_FREEZE_BAD_MS = 60000


def budget_for(units: int) -> int:
    """Kernel ms per real second that fits a fort with this many visible units (sched.budget)."""
    fu = max(1.0, (units or 0) / LOAD_UNITS)
    return min(BUDGET_MAX, int(KERN_MS_S + BUDGET_PER_UNIT * (fu - 1) + 0.5))


def read_perf(save_dir: Path, window_s: int = WINDOW_S) -> list[dict]:
    """perf.csv rows (ints; mods as {name: ms}) within window_s of the newest row."""
    rows = []
    try:
        with open(Path(save_dir) / "perf.csv", encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                try:
                    row = {k: int(r[k]) for k in ("wall", "tick", "tps", "pop", "units", "items", "ms_s",
                                                   "gap_max_ms", "gaps3")}
                except (KeyError, TypeError, ValueError):
                    continue
                row["mode"] = r.get("mode") or "?"
                mods = {}
                for part in (r.get("mods") or "").split(";"):
                    k, _, v = part.partition("=")
                    if k and v.lstrip("-").isdigit():
                        mods[k] = int(v)
                row["mods"] = mods
                rows.append(row)
    except OSError:
        return []
    if not rows:
        return []
    newest = max(r["wall"] for r in rows)
    return [r for r in rows if newest - r["wall"] <= window_s]


def perf_summary(rows: list[dict]) -> dict:
    if not rows:
        return {}
    span = max(30, rows[-1]["wall"] - rows[0]["wall"] + 30)
    by_mode: dict[str, list[int]] = {}
    for r in rows:
        by_mode.setdefault(r["mode"], []).append(r["tps"])
    mods: dict[str, int] = {}
    cross: dict[str, int] = {}
    via: dict[str, int] = {}
    gap_ms: dict[str, int] = {}
    gap_n: dict[str, int] = {}
    for r in rows:
        for k, v in r["mods"].items():
            if k.startswith("gap:"):
                gap_ms[k[4:]] = gap_ms.get(k[4:], 0) + v
            elif k.startswith("gapn:"):
                gap_n[k[5:]] = gap_n.get(k[5:], 0) + v
            else:
                d = via if ">" in k else cross if k in NOT_OWNERS else mods
                d[k] = d.get(k, 0) + v
    gaps3 = sum(r["gaps3"] for r in rows)
    return {"rows": len(rows), "span_s": span, "last": rows[-1],
            "tps": {m: (int(statistics.median(v)), min(v), max(v)) for m, v in by_mode.items()},
            "ms_s_avg": round(sum(r["ms_s"] for r in rows) / len(rows)), "ms_s_max": max(r["ms_s"] for r in rows),
            "gap_max": max(r["gap_max_ms"] for r in rows), "gaps3": gaps3,
            # BUG-070: (cause, count, ms) most ms first, and the gaps an older kernel logged without a cause
            "gap_by": sorted(((c, gap_n.get(c, 0), ms) for c, ms in gap_ms.items()), key=lambda x: -x[2]),
            "gap_unattributed": max(0, gaps3 - sum(gap_n.values())),
            "mods": sorted(((k, v / span) for k, v in mods.items()), key=lambda x: -x[1]),
            "via": sorted(((k, v / span) for k, v in via.items()), key=lambda x: -x[1]),
            "repeat": cross["repeat"] / span if "repeat" in cross else None,
            "budget": budget_for(rows[-1]["units"])}


def _mins(secs: int) -> str:
    return f"{secs // 60} min" if secs >= 60 else f"{secs} s"


def top_cost(s: dict) -> str | None:
    """BUG-033: the top cost owner of the perf window in one line, with the module its K.calls spent the most in
    (a K.call is booked to the caller): 'top cost: runner 35.0 ms/s (snapshot 20.0 of it, in its calls)'."""
    if not s or not s.get("mods"):
        return None
    name, ms = s["mods"][0]
    edges = [(k.split(">", 1)[1], v) for k, v in s.get("via") or [] if k.split(">", 1)[0] == name]
    out = f"top cost: {name} {ms:.1f} ms/s"
    if edges and edges[0][1] >= 0.1:
        out += f" ({edges[0][0]} {edges[0][1]:.1f} of it, in its calls)"
    return out


def gap_lines(s: dict) -> list[str]:
    """BUG-070: 'frame gaps > 3 s by cause: save 9 (210 s), runner 2 (8 s), external 2 (7 s)' (nothing without gaps)."""
    parts = [f"{c} {n} ({ms // 1000} s)" for c, n, ms in s.get("gap_by", [])]
    if s.get("gap_unattributed"):
        parts.append(f"no cause logged {s['gap_unattributed']}")
    return [f"frame gaps > 3 s by cause: {', '.join(parts)}"] if parts else []


def gap_problems(s: dict) -> list[str]:
    """BUG-070: what is the kernel's to fix. Gaps ours (a module) or unknown (external, or an older kernel's rows without
    a cause) are a problem; DF's own save freeze only past SAVE_FREEZE_BAD_MS (the target is 15 s, DESIGN §10)."""
    by = s.get("gap_by", [])
    ours = [(c, n, ms) for c, n, ms in by if c not in ("save", "external")]
    ext = sum(n for c, n, _ in by if c == "external") + s.get("gap_unattributed", 0)
    out = []
    if ours or ext:
        n_ours = sum(n for _, n, _ in ours)
        who = ", ".join(f"{c} {n}" for c, n, _ in ours)
        out.append(f"{n_ours + ext} frame gap(s) > 3 s in {s['span_s'] // 60} min that are not DF's save: {n_ours} ours"
                   + (f" ({who})" if who else "") + f", {ext} unknown (dfllm cmd inspect what=perf lists the last gaps; "
                   "kern.log 'frame gap' lines name the blame)")
    save = next(((n, ms) for c, n, ms in by if c == "save"), None)
    worst = s.get("gap_max", 0)
    if save and worst >= SAVE_FREEZE_BAD_MS and not ours and not ext:     # then the worst gap is a save's
        out.append(f"DF save freeze {worst // 1000} s (> 15 s target): DF's own write of a big world; the kernel waits "
                   "out the window (perf.quiet_s) and adds nothing")
    return out


def snap_queue(state: dict | None) -> tuple[str | None, bool]:
    """BUG-033: the snapshot export queue (state snap) in one line, and whether it starves (the oldest request waits
    >= SNAP_STARVE_S: dfllm audit and bp sites --fresh get no file)."""
    sn = (state or {}).get("snap")
    if not isinstance(sn, dict):
        return None, False
    q, old, drop = sn.get("q") or 0, sn.get("old_s") or 0, sn.get("drop") or 0
    if not q:
        return (f"snapshot queue: empty ({sn.get('done', 0)} written, {drop} dropped this boot)" if drop else None), False
    run = ""
    if sn.get("run"):
        wait = sn.get("wait") or ""
        run = (f"; first {sn['run']} {sn.get('p', '?')} by {sn.get('by', '?')} {sn.get('pct', 0)}%"
               + (f" ({wait})" if wait else ""))
    line = (f"snapshot queue: {q} waiting, oldest {_mins(old)}{run}"
            + (f"; {drop} dropped this boot" if drop else ""))
    # a big export that gets its slices is slow, not starving: the first one waits ('busy ...', 'paced N min',
    # 'not started N min')
    wait = str(sn.get("wait") or "")
    return line, old >= SNAP_STARVE_S and (wait.startswith("busy") or wait.endswith(" min"))


# FR-87 (Run 14: the fair-play hook lives in <repo>/.claude/settings.json; the game session started in the parent folder, so
# Claude Code never read it and a private routine.lua ran every round, deleting popups): is the PreToolUse hook active in
# THIS session? Read-only: the settings files Claude Code reads for a session started in `project` (its .claude/settings.json
# and settings.local.json, the user's ~/.claude/settings.json), a hook entry whose command runs `dfpilot.hook` for Bash, and
# the hook module reachable from the project folder. Outside a Claude Code session the check is skipped.
SESSION_ENV = ("CLAUDECODE", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_ENTRYPOINT")
HOOK_MODULE = "dfpilot.hook"


def _settings(project: Path, home: Path) -> list[Path]:
    return [project / ".claude" / "settings.json", project / ".claude" / "settings.local.json",
            home / ".claude" / "settings.json"]


def _hook_entries(doc) -> list[tuple[str, str]]:
    """(matcher, command) of every PreToolUse hook in a settings document that runs the dfpilot hook."""
    out = []
    pre = ((doc or {}).get("hooks") or {}).get("PreToolUse") if isinstance(doc, dict) else None
    for ent in pre if isinstance(pre, list) else []:
        if not isinstance(ent, dict):
            continue
        for h in ent.get("hooks") if isinstance(ent.get("hooks"), list) else []:
            cmd = h.get("command") if isinstance(h, dict) else None
            if isinstance(cmd, str) and HOOK_MODULE in cmd:
                out.append((str(ent.get("matcher") or ""), cmd))
    return out


def _covers_bash(matcher: str) -> bool:
    try:
        return matcher in ("", "*") or re.fullmatch(matcher, "Bash") is not None
    except re.error:
        return False


def _project_dir(env: dict, cwd: Path) -> Path:
    """The folder the session started in: CLAUDE_PROJECT_DIR when the shell has it, else the nearest folder from the cwd up
    that holds a .claude folder (the shell may have walked down into the repo), else the cwd itself."""
    p = env.get("CLAUDE_PROJECT_DIR")
    if p:
        return Path(p)
    for d in [cwd, *list(cwd.parents)[:6]]:
        if (d / ".claude").is_dir():
            return d
    return cwd


def hook_check(env: dict | None = None, cwd: Path | None = None, home: Path | None = None) -> tuple[str, str]:
    """(state, text): state 'skip' (no Claude Code session in this shell), 'active', 'broken' (configured, but the hook module
    cannot be reached from the project folder: the hook command fails and Claude Code goes on) or 'inactive'."""
    env = os.environ if env is None else env
    if not any(env.get(k) for k in SESSION_ENV):
        return "skip", "hook: not checked (this shell is not a Claude Code session)"
    cwd = Path(cwd) if cwd is not None else Path.cwd()
    try:
        home = Path(home) if home is not None else Path.home()
    except (RuntimeError, KeyError, OSError):          # no home folder known: only the project's own settings count
        home = Path("/nonexistent-home")
    project = _project_dir(env, cwd)
    repo = Path(__file__).resolve().parent.parent
    found = []
    for f in _settings(project, home):
        try:
            doc = json.loads(f.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        found += [(f, m, c) for m, c in _hook_entries(doc) if _covers_bash(m)]
    if not found:
        return "inactive", (f"hook: not active in this session: {project} has no .claude/settings.json with the dfllm "
                            f"PreToolUse hook (the repo's is {repo / '.claude' / 'settings.json'}); a session started "
                            "in a parent folder never reads it, so nothing blocks inline lua, dfhack-run lua -f or "
                            "popup deletion. Start Claude Code inside the repo folder (QUICKSTART) or copy that hook block "
                            "into the start folder's .claude/settings.json")
    for f, m, c in found:
        lead = re.match(r'\s*cd\s+"?([^"&;$]+?)"?\s*&&', c)          # a fixed `cd <dir> &&`; else the project folder
        root = Path(lead.group(1)) if lead else project
        if (root / "dfpilot" / "hook.py").is_file():
            return "active", f"hook: active (Bash is covered by {f}; the hook module is in {root})"
    f, m, c = found[0]
    return "broken", (f"hook: configured in {f} but `{HOOK_MODULE}` cannot be reached from {project} (no dfpilot/hook.py "
                      "there or in the folder of its `cd`): the command would fail and Claude Code would go on without the "
                      "check")


def popup_gone_line(save_dir: Path, now_tick: int | None) -> str | None:
    """FR-87: the kernel's POPUP_GONE events (a popup left the screen and the kernel did not dismiss it) of the last game
    week: '3 popups vanished without a kernel dismiss in 7 days (last: "..."); the player's click looks the same'."""
    evs = files.tail_events(Path(save_dir), 0, limit=300, types={"POPUP_GONE"})
    if isinstance(now_tick, int):
        evs = [e for e in evs if isinstance(e.get("tick"), int) and 0 <= now_tick - e["tick"] <= 7 * 1200]
    if not evs:
        return None
    n = sum(e["d"].get("n", 1) if isinstance(e.get("d"), dict) and isinstance(e["d"].get("n"), int) else 1 for e in evs)
    last = (evs[-1].get("d") or {}).get("text") or evs[-1].get("msg", "")
    return (f"{n} popup{'s' if n != 1 else ''} vanished without a kernel dismiss in the last 7 game days (last: "
            f"\"{str(last)[:80]}\"); the player's click looks the same, a private script's delete too (kern.log 'popup vanished')")


def diagnose(save_dir: Path) -> tuple[list[str], list[str]]:
    """(report lines, problems)."""
    d = Path(save_dir)
    out, bad = [], []
    active = paths.active_save()
    hb, age = files.read_heartbeat(d)
    state, info = files.read_state_ex(d)
    out.append(f"doctor {d.name}: ACTIVE={'yes' if active == d.name else active or 'none'} heartbeat {fmt_age(age)}"
               + (f" frame {hb['frame']} {'paused' if hb['paused'] else 'running'}" if hb else "")
               + (f" | state seq {info['seq']} slot {info['slot']}" if state else " | no valid state"))
    if active == d.name and (age is None or age > HB_MAX_S):
        bad.append(f"heartbeat {fmt_age(age)} old (> {HB_MAX_S}s): DF hung or kern stopped")
    if state is None and info.get("errors"):
        bad.append("state unreadable: " + "; ".join(f"{k}: {v}" for k, v in info["errors"].items())[:200])
    s = perf_summary(read_perf(d))
    tempo_by = ((state or {}).get("owners") or {}).get("tempo")
    if s:
        tps = " ".join(f"{m} {med} ({lo}-{hi})" for m, (med, lo, hi) in sorted(s["tps"].items()))
        out.append(f"ticks/s median by mode over {s['span_s'] // 60} min: {tps}; last {s['last']['tps']} "
                   f"pop {s['last']['pop']} units {s['last']['units']} items {s['last']['items']}")
        units = s["last"]["units"]
        out.append(f"kernel {s['ms_s_avg']} ms/s avg, {s['ms_s_max']} max (limit {s['budget']}"
                   + (f" for {units} units" if s["budget"] != KERN_MS_S else "") + "); "
                   f"max frame gap {s['gap_max']} ms; gaps > 3 s: {s['gaps3']}")
        top = " ".join(f"{k} {v:.1f}" for k, v in s["mods"][:8])
        if s["mods"]:
            out.append("modules ms/s: " + top)
            out.append(top_cost(s))
        if s["repeat"] is not None:            # FR-62: the same frame time, timed again by DFHack
            out.append(f"DFHack repeat counter {s['repeat']:.1f} ms/s: the whole dfllm frame callback (unpaused frames, "
                       f"getTickCount clock), a cross-check of the kernel total, not a module")
        for m, (med, _, _) in s["tps"].items():
            if m in TPS_MIN and med < TPS_MIN[m] and not (m == "PEACE" and s["last"]["pop"] > 55):
                if m == "PEACE" and tempo_by in ("brake", "inbox"):
                    out.append(f"{m} median {med} ticks/s: tempo held by {tempo_by} (supply brake or tempo.lower)")
                else:
                    bad.append(f"{m} median {med} ticks/s < {TPS_MIN[m]}"
                               + (f" (kernel {s['ms_s_avg'] / 10:.1f} % of real time, {units} units, "
                                  f"{s['last']['items']} items)" if m == "PEACE" else ""))
        if s["ms_s_avg"] > s["budget"]:
            owners = ", ".join(f"{k} {v:.0f}" for k, v in s["mods"][:3])
            bad.append(f"kernel {s['ms_s_avg']} ms/s > {s['budget']}" + (f" ({units} units)" if s["budget"] != KERN_MS_S else "")
                       + (f": top {owners}" if owners else ""))
        out.extend(gap_lines(s))
        bad.extend(gap_problems(s))
    else:
        out.append("perf.csv: no rows")
    off = files.follow_off(d)
    if off:                                    # FR-29: a silent follow is not "all is well"
        (bad if active == d.name else out).append(off + ("" if active == d.name else " (DF not running this save)"))
    hstate, htext = hook_check()               # FR-87: the fair-play hook of this session
    (bad if hstate in ("inactive", "broken") else out).append(htext)
    t = (state or {}).get("t") or {}
    gone = popup_gone_line(d, t.get("abs", t["y"] * 403200 + t["tick"]) if t else None)
    if gone:
        out.append(gone)
    od = (state or {}).get("orders")
    if od and od.get("bad"):                   # FR-39: DF 53.16 crashes on make-item orders without a subtype
        bad.append(f"{od['bad']} manager order(s) of MakeArmor/Pants/Shoes/Gloves/Helm/Weapon/Ammo/Shield type without "
                   f"item_subtype: DF crashes when a dwarf takes the job (dfllm cmd inspect what=orders)")
    if od and od.get("jam"):                   # BUG-061: a workshop type's slots are full of jobs that cancel at once
        bad.append(f"orders: {od['jam']} (dfllm cmd inspect what=orders: slabs, shops)")
    if state:
        k = state["k"]
        out.append(f"state: tps {state['t']['tps']} ms/s {k['ms_s']} gap {k['gap_max_ms']} ms faults {k['faults']}"
                   f" slow {','.join(k['slow']) or '-'} disabled {','.join(k.get('disabled', [])) or '-'}"
                   + (f" ms_max {k['ms_max']}" if "ms_max" in k else ""))
        if k.get("disabled"):
            bad.append(f"disabled modules: {','.join(k['disabled'])}")
        sq, starving = snap_queue(state)           # BUG-033
        if sq:
            out.append(sq)
        if starving:
            bad.append(f"snapshot exports starve ({sq.split(': ', 1)[1]}): dfllm audit and bp sites --fresh get no file "
                       f"(kern.log 'snapshot:' lines; BUG-033)")
    evs = files.tail_events(d, 0, limit=300, types={"KERNEL_SLOW", "KERN_FAULT", "PERF_DEGRADED", "ACT_FAIL", "ORDER_BAD"})
    for e in evs[-6:]:
        out.append(f"  #{e['n']} {e['type']}: {e.get('msg', '')}")
    stuck = [n for n, a in files.pending_inbox(d) if a > INBOX_STUCK_S]
    if stuck:
        bad.append(f"{len(stuck)} inbox file(s) older than {INBOX_STUCK_S}s (kern not reading): {stuck[0]}")
    try:
        size = (d / "events.jsonl").stat().st_size
        if size > EVENTS_WARN_B * 1.2:
            bad.append(f"events.jsonl {size >> 20} MB: rotation not happening")
    except OSError:
        pass
    rs = files.read_json(paths.runtime_root() / "restore.json")
    if isinstance(rs, dict) and rs.get("active") and active is None:
        bad.append(f"restore.json active for {rs.get('save')} with no ACTIVE save: settings not restored (crash?)")
    lock = files.read_json(paths.runtime_root() / "live.lock")
    if isinstance(lock, dict):
        out.append(f"live.lock: {lock.get('holder')} {lock.get('purpose')}")
    out_k2, bad_k2 = supervise_lines(files.read_json(paths.runtime_root() / "supervise.json"), time.time())
    return out + out_k2, bad + bad_k2


def supervise_lines(doc, now: float) -> tuple[list[str], list[str]]:
    """K2: what supervise.json says about the load of the save (BUG-099: a fort that waits for a click is a problem, not a
    quiet title screen; FR-81: the DFHack version of the running game and of the last successful load)."""
    out, bad = [], []
    if not isinstance(doc, dict):
        return out, bad
    d = doc.get("dfhack") if isinstance(doc.get("dfhack"), dict) else {}
    last = (doc.get("last_loaded") or {}).get("ver") if isinstance(doc.get("last_loaded"), dict) else None
    if d.get("ver"):
        out.append(f"supervise: DFHack {d['ver']}" + (f", the last successful load ran on {last}" if last else "")
                   + (" (changed since: the title-screen load is untested there)" if d.get("changed") else ""))
    nc = doc.get("needs_click")
    if isinstance(nc, dict):
        wall = nc.get("wall") if isinstance(nc.get("wall"), (int, float)) else now
        bad.append(f"no fort runs: supervise could not load '{nc.get('save')}' for {fmt_age(max(0, now - wall))} "
                   f"(DFHack {nc.get('ver') or '?'}: {nc.get('why')}); click Continue by hand"
                   + (f"; the screen showed: {nc['screen']}" if nc.get("screen") else ""))
    return out, bad


def run(args, save_dir: Path) -> int:
    lines, bad = diagnose(save_dir)
    for x in lines:
        print(x)
    print("verdict: OK" if not bad else "verdict: " + str(len(bad)) + " problem(s)")
    for b in bad:
        print(f"  - {b}")
    return 1 if bad else 0


def add_parser(sub) -> None:
    sub.add_parser("doctor", help="ticks/s, kernel ms per module, frame gaps, stalls")
