"""FEATURE-003: `python -m df_llm_helper forbid-watch` - forbidden own containers/drinks/food/material and the cause.

Run 5: 1043 own items (barrels with drinks, blocks) were forbidden, the dwarves cancelled `Drink: Forbidden area`, the
digest showed 'Getraenke 475' and hygiene stayed silent until citizens died of thirst (BUG-125, BUG-423).

- status (read only): `claude/pilot_forbid status` (lua/pilot_forbid.lua): own forbidden items by class, drinks/food
  blocked by a forbidden container, claimed/dump-marked items for comparison, a cause per forbidden item (dump zone,
  own/other dead, used ammo, foreign-made loot, a dense 'area', unknown), the densest map blocks and the standing
  orders forbid_*. Falls back to `claude/pilot_hygiene forbid` (counts only, no causes) when pilot_forbid is missing.
- game log: `X cancels <job>: Forbidden area` lines read from paths.gamelog (own offset), counted over the last
  forbid_watch.log_minutes; the correlation line says whether drinking/eating is blocked or whether the cancels come
  without forbidden items (burrow/zone).
- script logs: `claude/*` logs below paths.tools (out/*.log, events.log) that mention forbidding (cause hint).
- fix: `forbid-watch fix [--classes drink,food,container] [--apply]` clears the forbid flag of own items of those
  classes (the item menu's forbid toggle, a normal player action). Dry run by default; siege loot ('other') is never
  unforbidden; foreign/trader goods are never touched (lua/pilot_forbid.lua, lint rule L13); every id is logged.
- check: every every_s; a warning line (repeated on change or after 30 min) when drinks/food blocked > *_warn_pct or
  Forbidden-area cancels > cancel_warn; on a change INTO a warning state one crit warning (wake line, digest).
"""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

__all__ = ["KEY", "DEFAULTS", "STATUS_CMD", "FALLBACK_CMD", "FIX_CLASSES", "ForbidReport", "parse_status",
           "count_cancels", "assess", "report_lines", "ForbidWatch", "register", "check_hook"]

KEY = "forbid_watch"
DEFAULTS = {
    "log_minutes": 10,            # window for the Forbidden-area cancels (game log lines carry no time: arrival time)
    "cancel_warn": 10,            # Forbidden-area cancels in the window from which check warns
    "drink_warn_pct": 20,         # share of drinks blocked (own flag or forbidden container) from which check warns
    "food_warn_pct": 20,
    "first_tail_lines": 300,      # first read of the game log: only its last lines count as 'recent'
    "every_s": 300,               # check interval (cheap: one item scan)
    "fix_classes": ["drink", "food", "container"],
    "fix_max": 2000,              # items per fix call (the Lua never takes more than 5000)
    "fix_per_hour": 3,            # loop protection for fix --apply
    "repeat_s": 1800,             # an unchanged warning line repeats in check after this time
    "in_check": True,
}
STATUS_CMD = "claude/pilot_forbid status"
FALLBACK_CMD = "claude/pilot_hygiene forbid"
FIX_CLASSES = ("drink", "food", "container", "material")
CLASSES = ("container", "drink", "food", "material", "other")
CAUSES = ("dump_zone", "own_dead", "other_dead", "used_ammo", "foreign_made", "area", "unknown")
CAUSE_TEXT = {"dump_zone": "on a dump zone (DF forbids what it dumped)", "own_dead": "own dead (standing order)",
              "other_dead": "other dead / kill zone (standing order)", "used_ammo": "used ammo (standing order)",
              "foreign_made": "foreign-made (siege loot?)", "area": "dense area (mass forbid designation or a script)",
              "unknown": "unknown"}
_CANCEL = re.compile(r"\bcancels\s+(?P<job>[^:]+?):\s*Forbidden area", re.I)
_SCRIPT_FORBID = re.compile(r"forbid", re.I)


@dataclass
class ForbidReport:
    ok: bool = False
    source: str = ""                   # pilot_forbid | pilot_hygiene (fallback, no causes)
    total: int = 0
    classes: dict = field(default_factory=dict)
    drink_total: int = 0
    drink_blocked: int = 0
    drink_in_container: int = 0
    food_total: int = 0
    food_blocked: int = 0
    causes: dict = field(default_factory=dict)
    clusters: list = field(default_factory=list)
    standing: dict = field(default_factory=dict)
    in_job: int | None = None
    dump: int | None = None
    hidden: int = 0
    cancels: int = 0
    cancel_jobs: dict = field(default_factory=dict)
    log_minutes: int = 10
    log_note: str = ""
    scripts: list = field(default_factory=list)
    state: str = "ok"                  # ok | info | warn | area
    error: str = ""

    @property
    def drink_pct(self) -> int:
        return round(100 * self.drink_blocked / self.drink_total) if self.drink_total else 0

    @property
    def food_pct(self) -> int:
        return round(100 * self.food_blocked / self.food_total) if self.food_total else 0


def _d(v) -> dict:
    return v if isinstance(v, dict) else {}


def _l(v) -> list:
    return list(v.values()) if isinstance(v, dict) else list(v or [])


def parse_status(j: dict | None, source: str) -> ForbidReport:
    """`pilot_forbid status` or the fallback `pilot_hygiene forbid` JSON -> ForbidReport (state not yet set)."""
    r = ForbidReport(source=source)
    if not isinstance(j, dict) or not j.get("ok"):
        r.error = "not readable"
        return r
    r.ok = True
    c = _d(j.get("classes"))
    r.classes = {k: int(c.get(k) or 0) for k in CLASSES}
    r.total = int(j.get("total") or 0)
    dr, fo = _d(j.get("drink")), _d(j.get("food"))
    r.drink_total, r.drink_blocked = int(dr.get("total") or 0), int(dr.get("blocked") or 0)
    r.drink_in_container = int(dr.get("in_forbidden_container") or 0)
    r.food_total, r.food_blocked = int(fo.get("total") or 0), int(fo.get("blocked") or 0)
    ca = _d(j.get("causes"))
    r.causes = {k: int(ca.get(k) or 0) for k in CAUSES} if ca else {}
    r.clusters = [x for x in _l(j.get("clusters")) if isinstance(x, dict)]
    r.standing = {k: bool(v) for k, v in _d(j.get("standing")).items()}
    fl = _d(j.get("flags"))
    if fl:
        r.in_job, r.dump = int(fl.get("in_job") or 0), int(fl.get("dump") or 0)
    r.hidden = int(j.get("hidden") or 0)
    return r


def count_cancels(lines: list[str]) -> tuple[int, dict]:
    """Forbidden-area cancels in game-log lines -> (count, {job: count})."""
    jobs: dict = {}
    for ln in lines:
        m = _CANCEL.search(ln)
        if m:
            job = re.sub(r"\s+", " ", m.group("job").strip())
            jobs[job] = jobs.get(job, 0) + 1
    return sum(jobs.values()), jobs


def assess(r: ForbidReport, cfg: dict) -> str:
    """ok | info (forbidden items below the thresholds, e.g. siege loot) | warn (supply blocked or many cancels while
    items are forbidden) | area (many Forbidden-area cancels without forbidden items: burrow/zone)."""
    if not r.ok:
        return "ok"
    many = r.cancels > int(cfg.get("cancel_warn", 10))
    blocked = r.drink_blocked > 0 or r.food_blocked > 0
    if r.total == 0 and not blocked:
        return "area" if many else "ok"
    if r.drink_pct > int(cfg.get("drink_warn_pct", 20)) or r.food_pct > int(cfg.get("food_warn_pct", 20)) or many:
        return "warn"
    return "info"


def digest_line(r: ForbidReport) -> str:
    return (f"Forbidden own items: {r.total} (drinks {r.drink_blocked}/{r.drink_total}, "
            f"food {r.food_blocked}/{r.food_total})")


def forbid_line(r: ForbidReport) -> str:
    """The correlation line, e.g. 'FORBID: 1043 own items forbidden (drinks 475 = 100 %), 37 Forbidden-area cancels in
    10 min -> drinking blocked'."""
    c = f"{r.cancels} Forbidden-area cancels in {r.log_minutes} min"
    if r.total == 0 and r.drink_blocked == 0 and r.food_blocked == 0:
        return f"FORBID: 0 own items forbidden, {c}" + (
            ": Forbidden-area cancels without forbidden items (burrow/zone?)" if r.cancels else "")
    line = f"FORBID: {r.total} own items forbidden (drinks {r.drink_blocked} = {r.drink_pct} %), {c}"
    tail = []
    if r.drink_blocked and (r.cancels or r.drink_pct >= 50):
        tail.append("drinking blocked")
    if r.food_blocked and (r.cancels or r.food_pct >= 50):
        tail.append("eating blocked")
    return line + (" -> " + ", ".join(tail) if tail else "")


def report_lines(r: ForbidReport, cfg: dict) -> list[str]:
    if not r.ok:
        return ["Forbidden own items: not readable (claude/pilot_forbid and claude/pilot_hygiene forbid missing? "
                "reinstall the Lua scripts: python -m df_llm_helper install-lua --apply)"]
    mark = {"warn": "!! ", "area": "! "}.get(r.state, "")
    out = [("! " if r.state == "warn" else "") + digest_line(r)]
    if r.total or r.drink_blocked or r.food_blocked or r.cancels:
        out.append(mark + forbid_line(r))
    if r.total or r.drink_blocked or r.food_blocked:
        cl = r.classes
        out.append(f"classes: containers {cl.get('container', 0)}, drinks {cl.get('drink', 0)}, food {cl.get('food', 0)}, "
                   f"material {cl.get('material', 0)}, other {cl.get('other', 0)}; drinks blocked "
                   f"{r.drink_blocked}/{r.drink_total} ({r.drink_in_container} in forbidden containers), food blocked "
                   f"{r.food_blocked}/{r.food_total}")
    if r.causes and r.total:
        out.append("causes: " + ", ".join(f"{CAUSE_TEXT[k]} {v}" for k, v in r.causes.items() if v))
    elif r.total and r.source == "pilot_hygiene":
        out.append("causes: unknown (claude/pilot_forbid not installed; counts from claude/pilot_hygiene forbid)")
    for c in r.clusters[:3]:
        cls = _d(c.get("classes"))
        where = [f"stockpile #{c['pile']}"] if c.get("pile") is not None else []
        where += [f"dump zone #{c['zone']}"] if c.get("zone") is not None else []
        out.append(f"where: z{c.get('z')} x{c.get('x1')}..{c.get('x2')} y{c.get('y1')}..{c.get('y2')}: {c.get('n')} "
                   + "(" + ", ".join([f"{k} {v}" for k, v in sorted(cls.items())] + where) + ")")
    if r.hidden:
        out.append(f"{r.hidden} forbidden own items on undiscovered tiles (not listed)")
    on = [k for k, v in sorted(r.standing.items()) if v]
    if on:
        out.append("standing orders on: " + ", ".join(on) + " (they forbid dead units' items on purpose; keep them "
                   "during sieges)")
    if r.cancel_jobs:
        out.append("cancels: " + ", ".join(f"{j} {n}" for j, n in sorted(r.cancel_jobs.items(), key=lambda kv: -kv[1])[:5])
                   + (f" ({r.log_note})" if r.log_note else ""))
    if r.scripts:
        out += [f"script log: {s}" for s in r.scripts[:3]]
    elif r.total:
        out.append("script logs: no claude/* log mentions forbidding")
    if r.in_job is not None:
        out.append(f"for comparison: own items claimed by a job {r.in_job}, dump-marked {r.dump}")
    fixable = sum(r.classes.get(k, 0) for k in cfg.get("fix_classes") or FIX_CLASSES)
    if fixable and r.state in ("warn", "info") and r.source == "pilot_forbid":
        out.append(f"fix: python -m df_llm_helper forbid-watch fix (dry run, {fixable} own "
                   f"{'/'.join(cfg.get('fix_classes') or FIX_CLASSES)} items; --apply unforbids them)")
    return out


class ForbidWatch:
    def __init__(self, client, store, clock, cfg: dict | None = None, *, gamelog: str | Path | None = None,
                 tools: str | Path | None = None):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.gamelog = Path(gamelog) if gamelog else None
        self.tools = Path(tools) if tools else None

    # ---- game data
    def read(self) -> ForbidReport:
        r = self.client.run(STATUS_CMD)
        if r.ok and isinstance(r.json, dict) and r.json.get("ok"):
            return parse_status(r.json, "pilot_forbid")
        r2 = self.client.run(FALLBACK_CMD)
        return parse_status(r2.json if r2.ok else None, "pilot_hygiene")

    # ---- game log (own offset; lines have no time stamp: counted at the time they are first read)
    def cancels(self, *, record: bool = True) -> tuple[int, dict, str]:
        from ..anomaly import _decode
        now = self.clock.now().epoch
        win = float(self.cfg["log_minutes"]) * 60
        hist = [h for h in (self.store.get("forbid_watch.log_hist") or []) if now - float(h[0]) <= win]
        note = ""
        lines: list[str] = []
        p = self.gamelog
        if p is not None and p.is_file():
            size = p.stat().st_size
            off = self.store.get("forbid_watch.log_offset")
            first = off is None
            off = 0 if first or int(off) > size else int(off)
            off = max(off, size - 2_000_000)
            with p.open("rb") as f:
                f.seek(off)
                lines = _decode(f.read()).splitlines()
            if first:
                lines = lines[-int(self.cfg["first_tail_lines"]):]
                note = f"first read: last {len(lines)} log lines"
            if record:
                self.store.set("forbid_watch.log_offset", size)
        elif p is not None:
            note = "game log not found"
        n, jobs = count_cancels(lines)
        hist.append([now, n, jobs])
        if record:
            self.store.set("forbid_watch.log_hist", hist[-200:])
        total, agg = 0, {}
        for _, k, js in hist:
            total += int(k)
            for j, v in (js or {}).items():
                agg[j] = agg.get(j, 0) + int(v)
        return total, agg, note

    def script_hints(self) -> list[str]:
        """claude/* logs that mention forbidding (out/*.log, events.log); the own unforbid log is listed apart."""
        if self.tools is None or not self.tools.is_dir():
            return []
        files = sorted((self.tools / "out").glob("*.log")) if (self.tools / "out").is_dir() else []
        files += [self.tools / "events.log"]
        out = []
        for f in files:
            if not f.is_file() or f.name == "forbid-fix.log":
                continue
            try:
                with f.open("rb") as fh:
                    fh.seek(max(0, f.stat().st_size - 256_000))
                    text = fh.read().decode("utf-8", errors="replace")
            except OSError:
                continue
            hits = [ln for ln in text.splitlines() if _SCRIPT_FORBID.search(ln) and "unforbid" not in ln.lower()]
            if hits:
                out.append(f"{f.name}: {len(hits)} lines mention forbid (last: {hits[-1].strip()[:90]})")
        own = (self.tools / "out" / "forbid-fix.log")
        if own.is_file():
            try:
                n = len(own.read_text(encoding="utf-8", errors="replace").splitlines())
                out.append(f"forbid-fix.log: {n} earlier unforbid runs (forbid-watch fix --apply)")
            except OSError:
                pass
        return out

    def status(self, *, record: bool = True) -> ForbidReport:
        r = self.read()
        r.log_minutes = int(self.cfg["log_minutes"])
        r.cancels, r.cancel_jobs, r.log_note = self.cancels(record=record)
        if r.ok:
            r.scripts = self.script_hints() if r.total else []
        r.state = assess(r, self.cfg)
        return r

    # ---- fix
    def fix(self, classes: list[str] | None = None, *, apply: bool = False, max_n: int | None = None) -> list[str]:
        cls = [c.strip() for c in (classes or self.cfg.get("fix_classes") or FIX_CLASSES) if c.strip()]
        bad = [c for c in cls if c not in FIX_CLASSES]
        if bad:
            raise ValueError(f"forbid-watch fix: class(es) {', '.join(bad)} not allowed (allowed: {', '.join(FIX_CLASSES)}; "
                             f"'other' = siege loot stays forbidden: the standing order protects haulers)")
        n = max(1, min(5000, int(max_n or self.cfg["fix_max"])))
        now = self.clock.now().epoch
        if apply and self.store.count_actions("forbid_watch", "fix", now - 3600) >= int(self.cfg["fix_per_hour"]):
            return [f"Loop protection: already {self.cfg['fix_per_hour']} fix runs in the last hour"]
        cmd = f"claude/pilot_forbid fix {','.join(cls)} --max {n}" + (" --apply" if apply else " --dry")
        r = self.client.run(cmd)
        j = r.json if r.ok and isinstance(r.json, dict) else None
        if j is None or "candidates" not in j:
            return ["forbid-watch fix: claude/pilot_forbid not readable (install the Lua scripts: python -m "
                    "df_llm_helper install-lua --apply); nothing changed"]
        if not j.get("ok"):
            return [f"forbid-watch fix: refused by the game script: {j.get('reason', '?')}"]
        by = ", ".join(f"{k} {v}" for k, v in sorted(_d(j.get("by_class")).items()))
        sk = _d(j.get("skipped"))
        skipped = ", ".join(f"{k} {v}" for k, v in sorted(sk.items()) if v)
        ids = ",".join(str(i) for i in _l(j.get("ids"))[:200])
        if apply:
            self.store.log_action(now, "forbid_watch", "forbid_watch", "fix", "items", cmd, False, True,
                                  f"unforbid {j.get('changed')}: {ids}"[:200])
            out = [f"Unforbade {int(j.get('changed') or 0)} own items ({by or 'none'}); log "
                   f"{j.get('log') or 'tools/out/forbid-fix.log'}"]
        else:
            out = [f"[dry] would unforbid {int(j.get('candidates') or 0)} own items ({by or 'none'}): {cmd} -> run "
                   f"again with --apply"]
        if skipped:
            out.append(f"skipped: {skipped} (hidden tiles, dump zones, other classes, over --max)")
        if ids:
            out.append(f"ids: {ids}" + (" ..." if int(j.get("candidates") or 0) > 200 else ""))
        return out


# ------------------------------------------------------------------ CLI + check
def _watch(p) -> ForbidWatch:
    return ForbidWatch(p.client, p.store, p.clock, p.cfg.get(KEY, {}), gamelog=p.cfg.get("paths.gamelog"),
                       tools=p.cfg.get("paths.tools"))


def _cmd(args) -> int:
    from ..cli import _pilot          # lazy: no cli import at module level (import cycles)
    p = _pilot(args)
    w = _watch(p)
    if args.action == "fix" or args.fix:
        classes = [c for c in (args.classes or "").split(",") if c.strip()] or None
        print("\n".join(w.fix(classes, apply=bool(args.apply), max_n=args.max)))
        return 0
    if args.apply:
        raise ValueError("--apply only with 'forbid-watch fix' (status is read only)")
    r = w.status(record=not args.dry_run)
    if args.json:
        d = asdict(r)
        d.update(drink_pct=r.drink_pct, food_pct=r.food_pct, line=digest_line(r) if r.ok else None,
                 forbid_line=forbid_line(r) if r.ok else None)
        print(json.dumps(d, ensure_ascii=False, sort_keys=True))
    else:
        print("\n".join(report_lines(r, w.cfg)))
    return 0 if r.ok else 1


def register(sub) -> None:
    s = sub.add_parser("forbid-watch", help="forbidden own containers/drinks/food/material, the cause and an unforbid "
                                            "proposal (FEATURE-003)")
    s.add_argument("action", nargs="?", default="status", choices=["status", "fix"])
    s.add_argument("--json", action="store_true", help="status: machine-readable report")
    s.add_argument("--fix", action="store_true", help="same as the action 'fix'")
    s.add_argument("--apply", action="store_true", help="fix: really clear the forbid flag (otherwise dry run)")
    s.add_argument("--classes", default=None,
                   help=f"fix: comma list of {', '.join(FIX_CLASSES)} (default forbid_watch.fix_classes)")
    s.add_argument("--max", type=int, default=None, help="fix: at most this many items (<= 5000)")
    s.add_argument("--dry-run", action="store_true", help="status: do not advance the game-log offset")
    s.set_defaults(fn=_cmd)


def check_hook(pilot, report, dry: bool) -> list[str]:
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    last = pilot.store.get("forbid_watch.last")
    if last is not None and now - float(last) < float(cfg["every_s"]):
        return []
    w = _watch(pilot)
    w.cfg = cfg
    r = w.status(record=not dry)
    if not dry:
        pilot.store.set("forbid_watch.last", now)
    if not r.ok:
        return []                     # Lua missing: stay quiet here (hygiene keeps its own forbid check)
    if not dry:
        pilot.store.set("forbid_watch.active_ts", now)
    prev = pilot.store.get("forbid_watch.state") or {}
    out: list[str] = []
    if r.state in ("warn", "area"):
        lines = report_lines(r, cfg)
        text = lines[1] if len(lines) > 1 else lines[0]
        sig = re.sub(r"\d+", "#", text)
        if prev.get("state") != r.state:            # a change INTO a warning state: wake once (crit warning)
            if not dry:
                pilot.store.warn(now, "forbid-watch", f"forbid_watch:{r.state}:{int(now)}",   # new row = new wake
                                 f"{digest_line(r)}; {forbid_line(r)}"[:200], "crit")
        if prev.get("state") != r.state or prev.get("sig") != sig or now - float(prev.get("ts") or 0) >= float(cfg["repeat_s"]):
            out = ["Forbid-watch: " + ln for ln in lines[:2]]
            if not dry:
                prev = {"state": r.state, "sig": sig, "ts": now}
                pilot.store.set("forbid_watch.state", prev)
    elif prev.get("state") in ("warn", "area"):
        out = [f"Forbid-watch: resolved - {digest_line(r)}"]
        if not dry:
            pilot.store.set("forbid_watch.state", {"state": r.state, "ts": now})
    elif not dry and prev.get("state") != r.state:
        pilot.store.set("forbid_watch.state", {"state": r.state, "ts": now})
    return out
