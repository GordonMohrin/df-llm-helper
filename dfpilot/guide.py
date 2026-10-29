"""`dfllm next` (FR-85, Run 14 note 85): the ONE most urgent action as a ready command line.

The game session read `inspect` 635 times and never knew what to do. `next` is a pure function of what `status` and
`brief` already read (state, plan.json, alarm.txt, the newest class-A events): no live call, no new file but its own
repeat memory. A fixed priority, the first step that applies wins:

    dead       the kernel does not run (no state, not the ACTIVE save, or its heartbeat is old): nothing else can be trusted;
               no ACTIVE while DF runs here (a new embark, BUG-209)                  -> dfhack-run dfllm adopt
    interrupt  unacknowledged interrupts (state alarm.unacked)                     -> dfllm ack
    danger     a fight mode, a visible hostile, or cursed citizens (BUG-115)         -> dfllm wait ...; tell the player
    dying      patients near the thirst death line (PATIENT_DYING)                   -> dfllm cmd inspect water_sources
    mood       a MOOD_CRITICAL dwarf not ended yet                                   -> dfllm brief
    plan       no plan, a plan for a past year (YEAR_REVIEW), or a stale one (FR-86) -> dfllm plan propose y.json
    r0         readiness R0 blockers: seal, audit, hospital_out, refuge, the rest    -> the blocker's command
    idle       `NEXT: nothing`

Output: at most 4 short lines: `NEXT: <command>`, `WHY: <one line>`, optional `TELL PLAYER: <text>`, optional
`SHOW: dfllm cmd view target=...` (FR-88; in a fight the camera is the player's: `SHOW (the player runs it): ... --by gordon`).
Every command it prints is
checked by tests/test_m5_guide.py against the CLI parser and the verb registry (schema.VERBS, schema.validate_args).

Repeat memory (`<save>/.next.json`): the same command printed more than REPEAT_MAX times within REPEAT_WINDOW_S with no
change is not printed again: the next step is offered, and when nothing else applies `NEXT: nothing` says "tried N x" and
asks the player (the 635 `inspect` calls were this loop). The `danger` wait is exempt: polling is its job. BUG-147: the
count is kept per command (another command in between does not reset it), the "tried N x" answer keeps the memory, only
a green answer (nothing applies, nothing skipped) clears it; an entry expires REPEAT_WINDOW_S after its last print.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

from . import files, paths
from .events import DAY

REPEAT_MAX = 3                  # the same command this many times in REPEAT_WINDOW_S is not offered a 4th time
REPEAT_WINDOW_S = 1800
DYING_THIRST = 60000            # lua/dfllm/water.lua dying_thirst (PATIENT_DYING)
DYING_WINDOW = DAY              # a PATIENT_DYING event counts for a game day
MOOD_WINDOW = 2 * DAY           # a MOOD_CRITICAL event counts until MOOD_END/DEATH of the unit, at most this long
CURSE_EVENTS = ("CURSED", "TRANSFORM", "CURSE_MOON")     # care (BUG-115); unknown on an older kernel: harmless
CURSE_WINDOW = 30 * DAY
FIGHT_MODES = ("SIEGE", "BREACH", "ALERT", "DRILL")
HEARTBEAT_DEAD_S = 600          # an ACTIVE save whose heartbeat is older than this: the kernel is not running
WAIT = "dfllm wait --until-interrupt --timeout 15"
PLAN_CMD = "dfllm plan propose y.json"
SEAL_CMD = "dfllm cmd bp.place tpl=seal site=S1 at=last"
ADOPT_CMD = "dfhack-run dfllm adopt"     # BUG-209: a new embark (no ACTIVE while DF runs here)
HOSPITAL_CMD = "dfllm cmd bp.place tpl=hospital site=S1"
TELL_MAX = 150                  # bytes of the TELL PLAYER and WHY lines
STATE_FILE = ".next.json"
# R0 blockers (state ready.fail) that need a fortcore piece or the refuge: the plan builds them
REFUGE_FAILS = ("no_refuge", "refuge_sep", "refuge_dry", "no_kern", "no_outer", "no_inner")
KERNEL_FAILS = ("burrow_lost", "lost:", "office", "traps<", "bypass", "civ_sep", "caverns")


@dataclass
class Step:
    key: str                    # dead | interrupt | danger | curse | dying | mood | plan | r0 | idle
    cmd: str | None             # None: nothing to run (idle)
    why: str
    tell: str | None = None
    show: str | None = None             # a `dfllm cmd view target=...` line; in a fight it is the player's (--by gordon)
    show_by_player: bool = False
    stuck: bool = False                 # the "tried N x" idle step: it keeps the repeat memory (BUG-147)

    def lines(self) -> list[str]:
        out = [f"NEXT: {self.cmd or 'nothing'}", f"WHY: {self.why}"]
        if self.tell:
            out.append(f"TELL PLAYER: {self.tell}")
        if self.show:
            out.append(f"SHOW (the player runs it): {self.show} --by gordon" if self.show_by_player
                       else f"SHOW: {self.show}")
        return out

    def text(self) -> str:
        return "\n".join(self.lines())


# ---------------------------------------------------------------- facts
def gather(save_dir: Path) -> dict:
    """Everything `decide` reads, from the files `status`/`brief` read (brief.Ctx) and alarm.txt. No DF call."""
    from . import alarm, brief
    ctx = brief.Ctx(Path(save_dir))
    s = ctx.s
    f = {"state": ctx.state, "plan": ctx.plan, "hb_age": ctx.hb_age, "active": ctx.active, "a": ctx.a, "b": ctx.b,
         "now": ctx.now_tick(), "alarm": alarm.read_alarm(Path(save_dir), files.tick_cap(Path(save_dir))), "draft": None, "hosp_proj": False,
         "seal_proj": bool((s.get("sched") or {}).get("seal"))}
    if paths.active_save() is None:            # BUG-209: is DF running a save nobody adopted?
        from .doctor import df_up
        f["no_active"], f["df_up"] = True, df_up()
    draft = Path(save_dir) / "plan.draft.json"
    doc = files.read_json(draft, retry=False) if draft.exists() else None
    if isinstance(doc, dict) and isinstance(doc.get("year"), int):
        try:
            f["draft"] = {"year": doc["year"], "mtime": draft.stat().st_mtime}
        except OSError:
            pass
    plan_json = Path(save_dir) / "plan.json"
    try:
        f["plan_mtime"] = plan_json.stat().st_mtime
    except OSError:
        f["plan_mtime"] = 0.0
    fails = [str(x) for x in ((s.get("ready") or {}).get("fail") or [])]
    if "hospital_out" in fails:
        f["hosp_proj"] = _hospital_project(Path(save_dir))
    if any(x.startswith(REFUGE_FAILS) for x in fails):
        f["refuge_proj"] = _refuge_project(Path(save_dir), s, ctx.plan)
    return f


def _refuge_build(b: dict) -> bool:
    """BUG-221: a build or bp document that fixes an R0 refuge/fortcore fail: fortcore stage 3 (or a new core's stage 1),
    refuge_beds, refuge_drink, a seal that closes the ways in or the refuge (not at=audit)."""
    from .plan import REFUGE_BEDS, REFUGE_DRINK, _refuge_stage, _resite
    tpl = b.get("tpl")
    if not isinstance(tpl, str):
        return False
    if tpl == "seal":
        p = b.get("p", b.get("params")) or {}
        return str(p.get("at", "last") if isinstance(p, dict) else "last").strip().lower() != "audit"
    return tpl in (REFUGE_BEDS, REFUGE_DRINK) or _refuge_stage(b) or _resite(b)


def _refuge_project(save_dir: Path, s: dict, plan: dict | None) -> list[str]:
    """BUG-221 (live round 4: NEXT said `plan propose` right after the apply that holds fortcore stage 3 and the refuge
    beds and drink): the ids of the refuge fixes under way: this year's applied plan builds and bp projects with no
    PROJECT_DONE, and a running fortcore s3.* row of state.proj (not stopped on a breach). Cancelled projects
    (bp/.cancelled) and fortcore projects a breach stopped (core_breaches) do not count; an older bp file counts only as
    stage 3, refuge_beds/drink or a seal (the fort's first fortcore stage 1 is no new core). [] when none or unreadable."""
    from .plan import _resite, bp_files, bp_id, core_breaches, done_projects
    out: list[str] = []
    try:
        done = done_projects(save_dir)
        canc = Path(save_dir) / "bp" / ".cancelled"
        stopped = {c["proj"] for c in core_breaches(save_dir, s) if isinstance(c, dict)}

        def gone(pid: str) -> bool:
            return pid in done or pid in stopped or (canc / f"{pid}.json").is_file()
        year = (s.get("t") or {}).get("y")
        if isinstance(plan, dict) and isinstance(year, int) and plan.get("year") == year:
            for si, se in enumerate(plan.get("seasons") or []):
                for bi, b in enumerate((se or {}).get("build") or []):
                    pid = bp_id(plan["year"], si, bi)
                    if isinstance(b, dict) and not gone(pid) and _refuge_build(b):
                        out.append(pid)
        for p in bp_files(save_dir):
            doc = files.read_json(p, retry=False)
            if not gone(p.stem) and p.stem not in out and isinstance(doc, dict) and _refuge_build(doc) \
                    and not _resite(doc):
                out.append(p.stem)
    except Exception:                                   # noqa: BLE001 - unreadable plan/bp files: assume none (propose)
        return []
    for row in s.get("proj") or []:
        if isinstance(row, list) and len(row) >= 2 and row[0] == "fortcore" and str(row[1]).startswith("s3.") \
                and "breach:" not in str(row[-1]) and "fortcore" not in out:
            out.append("fortcore")
    return out


def _hospital_project(save_dir: Path) -> bool:
    """A hospital project under way: a bp file of tpl hospital with no PROJECT_DONE (a second bp.place would duplicate it)."""
    from .plan import bp_files, done_projects
    try:
        done = done_projects(save_dir)
        for p in bp_files(save_dir):
            doc = files.read_json(p, retry=False)
            if isinstance(doc, dict) and doc.get("tpl") == "hospital" and p.stem not in done:
                return True
    except Exception:                                   # noqa: BLE001 - unreadable bp files: assume none, the player sees it
        return False
    return False


def _d(e: dict) -> dict:
    return e.get("d") if isinstance(e.get("d"), dict) else {}


def _recent(f: dict, types: tuple[str, ...], window: int) -> list[dict]:
    """Class-A events of these types within `window` ticks of now, oldest first."""
    now = f.get("now")
    out = []
    for e in f.get("a") or []:
        t = e.get("tick")
        if e.get("type") in types and (not isinstance(now, int) or not isinstance(t, int) or 0 <= now - t <= window):
            out.append(e)
    return out


def _txt(text: str, n: int = TELL_MAX) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n - 1] + "~"


def _pos(p) -> str:
    return ",".join(str(int(x)) for x in p) if isinstance(p, (list, tuple)) and len(p) == 3 else ""


def _view(target) -> str | None:
    if isinstance(target, bool) or not target:
        return None
    return f"dfllm cmd view target={target}"


# ---------------------------------------------------------------- the steps, in priority order
def candidates(f: dict) -> list[Step]:
    """Every step that applies, in priority order (the first one `decide` does not skip is the answer)."""
    s = f.get("state")
    out: list[Step] = []
    dead = _dead(f)
    if dead:
        return [dead]
    s = s or {}
    fight = s.get("mode") in FIGHT_MODES
    out += _interrupt(f, s)
    out += _danger(f, s, fight)
    out += _dying(f, s, fight)
    out += _mood(f, s, fight)
    out += _plan(f, s)
    out += _r0(f, s)
    return out


def adopt_step() -> Step:
    """BUG-209 (live round 3, new embark Earthboat): DF runs and no ACTIVE file names a fort: the loaded save is not adopted
    (or the kernel is idle); every number status shows belongs to the newest folder, an earlier fort."""
    return Step("dead", ADOPT_CMD, "ACTIVE missing while DF runs: the loaded fort is not adopted (a new embark?); then "
                "dfhack-run dfllm selftest full and dfllm next again",
                "a new fort is loaded: I adopt it for the kernel first.")


def _dead(f: dict) -> Step | None:
    if f.get("no_active") and f.get("df_up"):
        return adopt_step()
    if f.get("state") is None:
        return Step("dead", "dfllm doctor", "no valid state file: the kernel is not running or DF is closed",
                    "no readable game state: is DF running with the fort loaded?")
    age = f.get("hb_age")
    if not f.get("active"):
        return Step("dead", "dfllm doctor", "this save is not the ACTIVE one: DF is closed or runs another fort; the state "
                    "below is the last one it wrote", "the game is not running this fort (or not at all).")
    if age is None or age > HEARTBEAT_DEAD_S:
        return Step("dead", "dfllm doctor", f"heartbeat {'missing' if age is None else str(int(age)) + ' s old'} in the "
                    "ACTIVE save: the kernel has stopped", "the game looks hung or the kernel stopped; look at DF")
    return None


def _interrupt(f: dict, s: dict) -> list[Step]:
    al = s.get("alarm") or {}
    items = [it for it in ((f.get("alarm") or {}).get("items") or []) if it.get("status") == "unacked"]
    n = al.get("unacked") or len(items)
    if not n:
        return []
    last = items[-1] if items else None
    what = f" {last['type']}: {last['msg']}" if last else ""
    return [Step("interrupt", "dfllm ack",
                 _txt(f"{n} interrupt{'s' if n != 1 else ''} unacked (last #{al.get('last', last['n'] if last else '?')}"
                      f"{what}); unacked, the kernel applies its lockdown default"),
                 _txt(f"{last['type']}: {last['msg']}") if last else None)]


def _danger(f: dict, s: dict, fight: bool) -> list[Step]:
    out: list[Step] = []
    th, al, mode = s.get("threat") or {}, s.get("alarm") or {}, s.get("mode")
    vis = th.get("vis", 0) if isinstance(th.get("vis"), int) else 0
    if mode in ("SIEGE", "BREACH") or vis > 0 or mode == "ALERT":
        by = al.get("by") if isinstance(al.get("by"), dict) else {}
        cause = (f"; cause {by.get('k', '?')} {by.get('id', '?')} {by.get('race', '')} at {_pos(by.get('pos'))}"
                 + (", harmless" if by.get("hl") else "")) if by else ""
        out.append(Step("danger", WAIT, _txt(f"{mode}: {vis} hostile visible{cause}; the kernel acts (gates, doors, "
                                              "alert, clock); nothing tactical for you"),
                        _txt(f"{mode}: {vis} hostile visible{cause}. The fort runs its defense; tell once, then keep "
                             "watching."), _view(by.get("id")), fight))
    cur = s.get("curse") if isinstance(s.get("curse"), dict) else {}
    evs = _recent(f, CURSE_EVENTS, CURSE_WINDOW)
    if (isinstance(cur.get("n"), int) and cur["n"] > 0) or evs:
        n = cur.get("n") if isinstance(cur.get("n"), int) else _d(evs[-1]).get("n", "?")
        tf = cur.get("tf", 0) if isinstance(cur.get("tf"), int) else 0
        ids = [i for i in cur.get("ids") or [] if isinstance(i, int)]
        show = _view(ids[0]) if ids else None
        out.append(Step("curse", "dfllm brief",
                        _txt(f"{n} cursed citizen{'s' if n != 1 else ''}" + (f", {tf} in were-form now" if tf else "")
                             + (f", next full moon in {cur['mi']} d" if isinstance(cur.get("mi"), int) else "")
                             + ": lock them in one room before the moon (the brief has the recipe)"),
                        _txt(f"{n} cursed citizen{'s' if n != 1 else ''}" + (f" ({tf} transformed)" if tf else "")
                             + (f", full moon in {cur['mi']} days" if isinstance(cur.get("mi"), int) else "")
                             + "; they turn on the next full moon and bite."), show, fight))
    return out


def _dying(f: dict, s: dict, fight: bool) -> list[Step]:
    w = s.get("water") if isinstance(s.get("water"), dict) else {}
    evs = _recent(f, ("PATIENT_DYING",), DYING_WINDOW)
    live = isinstance(w.get("patients"), int) and w["patients"] > 0 and isinstance(w.get("thirst_max"), int) \
        and w["thirst_max"] >= DYING_THIRST
    if not (live or evs):
        return []
    d = _d(evs[-1]) if evs else {}
    n = w.get("patients") if live else d.get("n", "?")
    thirst = w.get("thirst_max") if live else d.get("thirst", "?")
    units = [u for u in d.get("units") or [] if isinstance(u, int)]
    why = (f"{n} patient{'s' if n != 1 else ''} near the thirst death line (thirst {thirst})"
           + (f", carers {d['carers']} of {d['want']} wanted" if "carers" in d and "want" in d else "")
           + (f": {d['why']}" if d.get("why") else ""))
    return [Step("dying", 'dfllm cmd inspect \'{"what":"water_sources"}\'', _txt(why),
                 _txt(f"{n} patients are dying of thirst: hospital water or carers fail."),
                 _view(units[0]) if units else None, fight)]


def _ended(f: dict, unit: int, since: int | None) -> bool:
    """MOOD_END or DEATH of this unit after the MOOD_CRITICAL (class B, newest 500 events)."""
    for e in f.get("b") or []:
        if e.get("type") in ("MOOD_END", "DEATH") and _d(e).get("unit") == unit:
            t = e.get("tick")
            if not isinstance(since, int) or not isinstance(t, int) or t >= since:
                return True
    return False


def _mood(f: dict, s: dict, fight: bool) -> list[Step]:
    for e in reversed(_recent(f, ("MOOD_CRITICAL",), MOOD_WINDOW)):
        d = _d(e)
        unit = d.get("unit")
        if not isinstance(unit, int) or _ended(f, unit, e.get("tick")):
            continue
        who = d.get("name") or f"unit {unit}"
        ws = d.get("ws") or "workshop"
        pos = _pos(d.get("pos"))
        # BUG-282: a MOOD_CRITICAL of the mood's own clock carries the days left instead of the thirst
        left = d.get("left")
        clock = f"{left} d left" if isinstance(left, int) and left >= 0 else f"thirst {d.get('thirst', '?')}"
        why = (f"{who} ({unit}) in a mood at the {ws}{' ' + pos if pos else ''}, {clock}"
               + (f", missing {', '.join(d['missing'][:3])}" if d.get("missing") else "") + ": supply the missing class")
        return [Step("mood", "dfllm brief", _txt(why),
                     _txt(f"{who} is in a strange mood and may die: {d.get('why', 'material or drink missing')}."),
                     _view(unit), fight)]
    return []


def _plan(f: dict, s: dict) -> list[Step]:
    year = (s.get("t") or {}).get("y")
    if not isinstance(year, int) or s.get("mode") in ("SIEGE", "BREACH"):
        return []
    plan, draft = f.get("plan"), f.get("draft")
    if plan is None:
        why, key = "no plan applied yet: the fort builds nothing without one (RULES 4)", None
    else:
        py = plan["year"]
        if year - py < 1:
            return []
        stale = year - py >= 2
        why = (f"PLAN STALE: applied y{py}, now y{year}" if stale else f"year review due: the plan is for y{py}, now y{year}")
        key = py
    if draft and draft.get("year") in (year, year + 1) and draft.get("mtime", 0) > f.get("plan_mtime", 0):
        return [Step("plan", "dfllm plan check", _txt(why + "; a draft waits: check it, then plan apply"),
                     _txt(why) if plan is None or year - plan["year"] >= 2 else None)]
    tell = _txt(why + "; the kernel builds only what an approved plan holds") \
        if key is not None and year - key >= 2 else None
    return [Step("plan", PLAN_CMD, _txt(why + "; fix every ERROR line, plan check, plan apply"), tell)]


def _r0(f: dict, s: dict) -> list[Step]:
    r = s.get("ready") if isinstance(s.get("ready"), dict) else None
    if not r or r.get("lvl") != 0 or s.get("mode") in ("SIEGE", "BREACH"):
        return []
    fails = [str(x) for x in r.get("fail") or []]
    out: list[Step] = []
    ways = r.get("open") if isinstance(r.get("open"), int) else -1
    if (ways > 0 or "open_perimeter" in fails) and not f.get("seal_proj"):
        out.append(Step("r0", SEAL_CMD, _txt(f"R0 seal: {ways if ways > 0 else 'a'} way{'s' if ways != 1 else ''} in "
                                            f"without door or bridge{', open ' + str(r['pd']) + ' d' if isinstance(r.get('pd'), int) else ''}"
                                            f" ({r.get('pw') or 'dfllm cmd inspect what=entrances'})")))
    if any(x in ("audit", "audit_old") for x in fails):
        a = r.get("audit") or {}
        why = a.get("why") if isinstance(a.get("why"), str) and a.get("why") else ""
        out.append(Step("r0", "dfllm audit", _txt("R0 audit: " + ("the audit is old" if "audit_old" in fails else "no audit yet")
                                                  + (f"; the last request was refused: {why}" if why else ""))))
    hout = (s.get("water") or {}).get("hout") if isinstance(s.get("water"), dict) else None
    if "hospital_out" in fails and isinstance(hout, dict) and hout.get("ok") == 1 and not hout.get("pat"):
        at = ",".join(str(v) for v in hout.get("at") or [])     # BUG-131: a finished hospital inside: retire the old zone
        out.append(Step("r0", f"dfllm cmd hospital.retire zone={hout.get('z')}",
                        _txt(f"R0 hospital_out: zone {hout.get('z')} at {at} lies outside Kern+/Tiefe+ and a finished "
                             "hospital stands inside: retire the old zone (the zones screen's remove)")))
    elif "hospital_out" in fails and not f.get("hosp_proj"):
        out.append(Step("r0", HOSPITAL_CMD, "R0 hospital_out: no hospital inside Kern+/Tiefe+, patients die on the way "
                                            "(sites follow the accepted water)",
                        "The hospital lies outside the safe core; patients cannot reach the refuge."))
    elif "hospital_out" in fails:
        out.append(Step("r0", None, "R0 hospital_out: a hospital project is under way; wait for it"))
    if any(x.startswith(REFUGE_FAILS) for x in fails):
        miss = [x for x in fails if x.startswith(REFUGE_FAILS)]
        ids = f.get("refuge_proj") or []
        if ids:                                 # BUG-221: the applied plan (or a project) builds it: wait, no new propose
            out.append(Step("r0", None, _txt(f"R0 refuge/fortcore: {', '.join(miss[:4])}; the applied plan builds it "
                                             f"({', '.join(ids[:4])}{' +' + str(len(ids) - 4) if len(ids) > 4 else ''}); wait")))
        else:
            out.append(Step("r0", PLAN_CMD, _txt(f"R0 refuge/fortcore: {', '.join(miss[:4])}; the plan builds these pieces "
                                                "(fortcore stage 3, refuge drink and beds)")))
    other = [x for x in fails if x not in ("audit", "audit_old", "open_perimeter", "hospital_out")
             and not x.startswith(REFUGE_FAILS)]
    if other:
        out.append(Step("r0", "dfllm brief", _txt(f"R0 blockers: {', '.join(other[:5])}; the brief's SIEGE UNREADY line "
                                                  "names the fix")))
    return [x for x in out if x.cmd]


# ---------------------------------------------------------------- decision
def decide(f: dict, tried: tuple[str, ...] | list[str] = ()) -> Step:
    """The first step of `candidates` whose command is not in `tried` (the repeat memory); `danger` is never skipped.
    No step left: `NEXT: nothing` (idle), with what was skipped."""
    skipped: list[str] = []
    cands = candidates(f)
    for c in cands:
        if c.cmd in tried and c.key != "danger":
            skipped.append(c.cmd)
            continue
        return c
    if skipped:
        return Step("idle", None, _txt(f"tried {REPEAT_MAX}x with no change: {skipped[0]}; nothing else applies"),
                    _txt(f"I am stuck: `{skipped[0]}` did not change anything after {REPEAT_MAX} tries. Please look."),
                    stuck=True)
    s = f.get("state") or {}
    r = s.get("ready") if isinstance(s.get("ready"), dict) else {}
    waits = ""
    if r.get("lvl") == 0:
        ids = f.get("refuge_proj") or []      # BUG-221: name the refuge projects the applied plan builds
        waits = (f"; R0 waits on {','.join(str(x) for x in (r.get('fail') or [])[:4])} ("
                 + (f"the applied plan builds it: {', '.join(ids[:4])}; wait" if ids else "a project is under way") + ")")
    return Step("idle", None, _txt(f"green: {s.get('mode', '?')}"
                                   f"{' R' + str(r['lvl']) if 'lvl' in r else ''}, pop {(s.get('pop') or {}).get('cit', '?')}"
                                   f"{waits}; wait for the next wake line"))


# ---------------------------------------------------------------- repeat memory
def read_memory(save_dir: Path, now: float | None = None) -> dict:
    """{"cmd", "n", "wall"} of the last command printed plus "cmds" {cmd: {n, wall}} of every command printed within
    REPEAT_WINDOW_S (BUG-147); {} when nothing is left. A v1 file (one command) is read as one entry."""
    now = time.time() if now is None else now
    m = files.read_json(Path(save_dir) / STATE_FILE, retry=False)
    if not isinstance(m, dict):
        return {}
    raw = m.get("cmds") if isinstance(m.get("cmds"), dict) else {}
    if not raw and isinstance(m.get("cmd"), str):
        raw = {m["cmd"]: {"n": m.get("n"), "wall": m.get("wall")}}
    cmds = {c: {"n": e["n"], "wall": e["wall"]} for c, e in raw.items()
            if isinstance(c, str) and isinstance(e, dict) and isinstance(e.get("n"), int)
            and isinstance(e.get("wall"), (int, float)) and 0 <= now - e["wall"] <= REPEAT_WINDOW_S}
    if not cmds:
        return {}
    last = m.get("cmd") if m.get("cmd") in cmds else max(cmds, key=lambda c: cmds[c]["wall"])
    return {"cmd": last, "n": cmds[last]["n"], "wall": cmds[last]["wall"], "cmds": cmds}


def tried_cmds(mem: dict) -> tuple[str, ...]:
    return tuple(c for c, e in (mem.get("cmds") or {}).items() if e.get("n", 0) >= REPEAT_MAX)


def remember(save_dir: Path, mem: dict, step: Step, now: float | None = None) -> None:
    """Count the command just printed (per command, BUG-147). The "tried N x" idle step keeps the memory; a green idle step
    (nothing skipped) clears it. Never raises."""
    now = time.time() if now is None else now
    try:
        p = Path(save_dir) / STATE_FILE
        if step.cmd is None:
            if not step.stuck and p.exists():
                p.unlink()
            return
        cmds = dict(mem.get("cmds") or {})
        n = (cmds.get(step.cmd) or {}).get("n", 0) + 1
        cmds[step.cmd] = {"n": n, "wall": now}
        files.write_json_atomic(p, {"v": 2, "cmd": step.cmd, "n": n, "wall": now, "cmds": cmds})
    except OSError:
        pass


def next_step(save_dir: Path, now: float | None = None, record: bool = True) -> Step:
    f = gather(save_dir)
    mem = read_memory(save_dir, now)
    step = decide(f, tried_cmds(mem))
    if record:
        remember(save_dir, mem, step, now)
    return step


def run(args, save_dir: Path) -> int:
    step = next_step(save_dir, record=not getattr(args, "peek", False))
    print(step.text())
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("next", help="the ONE most urgent action as a ready command line (FR-85): NEXT / WHY / "
                                    "TELL PLAYER / SHOW; `NEXT: nothing` when all is green")
    p.add_argument("--peek", action="store_true", help="do not count this call in the repeat memory")
