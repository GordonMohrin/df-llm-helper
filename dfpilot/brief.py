"""`dfllm status` (<= 300 tokens) and `dfllm brief` (<= 1.5k tokens) from runtime files only."""
from __future__ import annotations

from pathlib import Path

from . import files, paths, schema
from .events import YEAR, clip, est_tokens, fmt_age, fmt_d, fmt_event, fmt_tick, fmt_ticks

STATUS_TOKENS, BRIEF_TOKENS = 300, 1500
SUPPLY_MIN = {"drink_d": 170, "food_d": 60}
# B digest order (most useful first); unlisted B types follow alphabetically
DIGEST_ORDER = ["SIEGE_START", "ALERT_START", "ALERT_END", "STOCK_LOW", "MOOD_NEED", "MOOD_START", "MOOD_END",
                "CANCEL_LOOP", "BREACH_STOP", "PROJECT_REQUEST", "DEATH", "CAPTURE", "CARAVAN", "MIGRANTS",
                "PETITION", "READY_CHANGE", "POPCAP", "AUDIT", "DRILL_RESULT", "PHASE", "PROJECT_DONE",
                "KERNEL_SLOW", "ACT_FAIL", "INVASION", "WEALTH", "PAUSE"]


LIMITS = {"A": 50, "B": 500, "CMD": 50}   # newest events kept per section (all DECISION_NEEDED of the year)


def _d(e: dict) -> dict:
    d = e.get("d")
    return d if isinstance(d, dict) else {}


class Ctx:
    """Everything status/brief need, read once. Events: ONE backwards scan over the last game year with its own
    bucket per section, so a flood of class-C events (SIEGE_STATUS every 600 ticks) cannot push open decisions,
    class-A events, failed commands or the B digest out of a fixed window. full=False (status) stops as soon as
    the newest MODE and class-A events are found."""

    def __init__(self, save_dir: Path, full: bool = True):
        self.dir = Path(save_dir)
        self.save = self.dir.name
        self.state, self.info = files.read_state_ex(self.dir)
        self.hb, self.hb_age = files.read_heartbeat(self.dir)
        self.active = paths.active_save() == self.save
        plan = files.read_json(self.dir / "plan.json")
        self.plan = plan if isinstance(plan, dict) and not schema.validate("plan", plan) else None
        self.inbox = files.pending_inbox(self.dir)
        self.decisions: dict[str, dict] = {}   # id -> newest DECISION_NEEDED
        self.a, self.b, self.cmds = [], [], []  # ascending after the scan
        self.mode_ev: dict | None = None
        self._scan(full)

    def _scan(self, full: bool) -> None:
        now = self.now_tick()
        min_tick = now - YEAR if isinstance(now, int) else None
        for e in files.iter_events_rev(self.dir, 0, min_tick):
            t, c = e.get("type"), e.get("cls")
            if t == "MODE" and self.mode_ev is None:
                self.mode_ev = e
            if c == "A" and len(self.a) < LIMITS["A"]:
                self.a.append(e)
            if not full:
                if self.mode_ev is not None and self.a:
                    break
                continue
            if t == "DECISION_NEEDED":
                did = _d(e).get("id")
                if isinstance(did, str) and did not in self.decisions:
                    self.decisions[did] = e
            elif t == "CMD" and len(self.cmds) < LIMITS["CMD"]:
                self.cmds.append(e)
            if c == "B" and len(self.b) < LIMITS["B"]:
                self.b.append(e)
        for lst in (self.a, self.b, self.cmds):
            lst.reverse()

    @property
    def s(self) -> dict:
        return self.state or {}

    def now_tick(self) -> int | None:
        t = self.s.get("t")
        if not t:
            return self.hb.get("tick") if self.hb else None
        return t.get("abs", t["y"] * YEAR + t["tick"])

    def mode_since(self) -> int | None:
        """Tick of the newest MODE event, if it entered the current mode (else unknown)."""
        e = self.mode_ev
        return e.get("tick") if e and _d(e).get("to") == self.s.get("mode") else None


def _join(parts) -> str:
    return " | ".join(p for p in parts if p)


def _ago(ctx: Ctx, tick: int | None) -> str:
    now = ctx.now_tick()
    return fmt_ticks(now - tick) if isinstance(now, int) and isinstance(tick, int) and now >= tick else "?"


# ---------------------------------------------------------------- lines shared by status and brief
def line_head(ctx: Ctx) -> str:
    s = ctx.s
    t = s.get("t") or {}
    since = ctx.mode_since()
    mode = s.get("mode") or (ctx.hb or {}).get("mode") or "?"
    run = "paused" if t.get("paused") else "run"
    df = "" if ctx.active else " (not ACTIVE)"
    own = s.get("owners") or {}
    hold = (f" pause:{own['pause']}" if own.get("pause") else "") + (" tempo:inbox" if own.get("tempo") == "inbox" else "")
    return (f"{ctx.save}{df} {fmt_tick(ctx.now_tick())} {mode}" + (f"({_ago(ctx, since)})" if since else "")
            + (f" {s['phase']}" if "phase" in s else "") + f" {t.get('tps', '?')}t/s {run}{hold}"
            + f" hb {fmt_age(ctx.hb_age)}")


def line_pop(ctx: Ctx) -> str:
    s = ctx.s
    out = []
    p = s.get("pop")
    if p:
        out.append(f"pop {p.get('cit', '?')} ({p.get('adults', '?')}ad {p.get('soldiers', '?')}sol)"
                   f" cap {p.get('cap', '?')} gate {p.get('gate_cap', '?')}")
    r = s.get("ready")
    if r:
        a = r["audit"]
        out.append(f"R{r['lvl']}" + (f" fail:{','.join(r['fail'])}" if r["fail"] else " ok")
                   + f" worn {r['worn']}% cv {r['cv']} drill {fmt_ticks(r['drill_age'])}"
                   + f" audit {'ok' if a['ok'] else 'FAIL'} {fmt_ticks(a['age'])} traps {a['min_traps']}")
    return _join(out)


def line_supply(ctx: Ctx) -> str:
    s, out = ctx.s, []
    st = s.get("stock")
    if st:
        lo = {k for k, m in SUPPLY_MIN.items() if k in st and st[k] < m}
        out.append("stock " + " ".join(
            f"{k[:-2]} {st[k]}d" + ("!" if k in lo else "") for k in ("drink_d", "food_d") if k in st)
            + (f" meals {st['meals']}" if "meals" in st else "")
            + (f" water {'ok' if st['hosp_water'] else 'NO'}" if "hosp_water" in st else ""))
    c = s.get("care")
    if c:
        out.append(f"stress {c['stressed_pct']}% naked {c['naked']} ghosts {c['ghosts']} corpses {c['corpses_old']}"
                   f" tombs {c['tombs_free']} moods {c['moods']}")
    lb = s.get("labor")
    if lb:
        out.append(f"idle {lb['idle']}% starving {lb['starving']}")
    return _join(out)


def line_def(ctx: Ctx) -> str:
    s, out = ctx.s, []
    th = s.get("threat")
    if th:
        out.append(f"threat {th['vis']} vis" + (" ARMED" if th["armed"] else ""))
    if s.get("bridges"):
        out.append("bridges " + " ".join(f"{b} {v}" for b, v in sorted(s["bridges"].items())))
    m = s.get("mil")
    if m:
        out.append(f"mil {m['squads']}sq {m['soldiers']}sol worn {m['worn']}% cv {m['cv']} metal {m['metal_pct']}%"
                   f" station {m['on_station']}")
    tr = s.get("trade")
    if tr and tr["caravan"]:
        out.append("CARAVAN on map")
    return _join(out)


def line_proj(ctx: Ctx, n: int = 3) -> str:
    pr = ctx.s.get("proj") or []
    if not pr:
        return "proj none" if "proj" in ctx.s else ""
    items = [f"{i} {st} {pct}%" + (f" BLOCKED:{b}" if b else "") for i, st, pct, b in pr[:n]]
    return "proj " + ", ".join(items) + (f" +{len(pr) - n}" if len(pr) > n else "")


def line_kern(ctx: Ctx) -> str:
    s = ctx.s
    k = s.get("k")
    out = []
    if k:
        out.append(f"kern {k['ms_s']}ms/s gap {k['gap_max_ms']}ms faults {k['faults']}"
                   + (f" slow:{','.join(k['slow'])}" if k["slow"] else "")
                   + (f" disabled:{','.join(k['disabled'])}" if k.get("disabled") else ""))
    if "ev" in s:
        out.append(f"ev #{s['ev']}")
    a = ctx.a
    if a:
        out.append(f"last A #{a[-1]['n']} {a[-1]['type']} {_ago(ctx, a[-1].get('tick'))} ago")
    if ctx.inbox:
        out.append(f"inbox {len(ctx.inbox)} pending (oldest {fmt_age(max(x[1] for x in ctx.inbox))})")
    return _join(out)


def _no_state(ctx: Ctx) -> str:
    errs = "; ".join(f"{k}: {v}" for k, v in ctx.info.get("errors", {}).items()) or "no state file"
    return f"no valid state ({errs[:160]})"


# ---------------------------------------------------------------- status
def status_text(save_dir: Path) -> str:
    ctx = Ctx(save_dir, full=False)
    lines = [line_head(ctx)]
    if ctx.state is None:
        lines.append(_no_state(ctx))
    else:
        lines += [line_pop(ctx), line_supply(ctx), line_def(ctx), line_proj(ctx), line_kern(ctx)]
    return fit([[x for x in lines if x]], STATUS_TOKENS)


# ---------------------------------------------------------------- brief
def sec_plan(ctx: Ctx) -> list[str]:
    p = ctx.plan
    if not p:
        return ["plan: none applied (dfllm plan propose)"]
    pol = p["policy"]
    season = (ctx.s.get("t") or {}).get("season", 0)
    out = [f"plan y{p['year']} target {p['phase_target']} option {pol['option']} ceiling {pol['pop_ceiling']}"
           f" beauty {pol['beauty']}"]
    for i, se in enumerate(p["seasons"]):
        if i < season or not se["build"]:
            continue
        out.append(f" s{i}{'*' if i == season else ''}: " + ", ".join(f"{b['tpl']}@{b['site']}" for b in se["build"]))
    imp = (p.get("orders") or {}).get("import") or []
    if imp:
        out.append(" orders " + " ".join(imp))
    tr = p.get("trade")
    if tr and (tr["want"] or tr["sell"]):
        out.append(f" trade want {','.join(tr['want']) or '-'} sell {','.join(tr['sell']) or '-'}")
    return out


def pending_decisions() -> set[str] | None:
    """Ids Gordon has not answered (WP4 fairplay.pending: line missing or its comment starts with 'default');
    None when fairplay is unavailable."""
    try:
        from .fairplay import pending
        return set(pending(paths.config_dir() / "decisions.yaml"))
    except Exception:                          # noqa: BLE001 - WP4 missing/broken: fall back to 'line missing'
        return None


def sec_decisions(ctx: Ctx) -> list[str]:
    pend = pending_decisions()
    if pend is None:
        from .plan import load_decisions
        ans = load_decisions()
        pend = {did for did in ctx.decisions if did not in ans}
    out = []
    for did, e in sorted(ctx.decisions.items()):
        if did in pend:
            out.append(f"OPEN {did}: {_d(e).get('q') or e.get('msg', '')}")
    return out


def sec_class_a(ctx: Ctx, n: int = 8) -> list[str]:
    return [fmt_event(e) for e in reversed(ctx.a[-n:])]  # newest first: fit() trims from the end


def sec_digest(ctx: Ctx) -> list[str]:
    groups: dict[str, list[dict]] = {}
    for e in ctx.b:
        groups.setdefault(str(e.get("type", "?")), []).append(e)
    order = [t for t in DIGEST_ORDER if t in groups] + sorted(t for t in groups if t not in DIGEST_ORDER)
    out = []
    for t in order:
        evs = groups[t]
        last = evs[-1]
        d = fmt_d(_d(last), 3)
        out.append(f"{t} x{len(evs)} last {fmt_tick(last.get('tick'))}: {last.get('msg', '')}"
                   + (f" [{d}]" if d and d not in str(last.get("msg", "")) else ""))
    return out


def sec_failures(ctx: Ctx) -> list[str]:
    """Failed commands among the newest CMD events (LIMITS['CMD'])."""
    out = []
    bad = [e for e in ctx.cmds if not _d(e).get("ok", 1)]
    for e in bad[-3:]:
        d = _d(e)
        out.append(f"cmd {d.get('id')} {d.get('verb')} failed: {e.get('msg', '')}")
    return out


def brief_text(save_dir: Path, budget: int = BRIEF_TOKENS) -> str:
    ctx = Ctx(save_dir)
    head = [f"# brief {line_head(ctx)}"]
    if ctx.state is None:
        head.append(_no_state(ctx))
    else:
        head += [x for x in (line_pop(ctx), line_supply(ctx), line_def(ctx), line_proj(ctx, 8), line_kern(ctx)) if x]
    sections = [head]
    for title, lines in (("## plan", sec_plan(ctx)), ("## decisions open (ask Gordon)", sec_decisions(ctx)),
                         ("## class A, newest first", sec_class_a(ctx)), ("## failed commands", sec_failures(ctx)),
                         ("## digest B (last year)", sec_digest(ctx))):
        if lines:
            sections.append([title] + lines)
    return fit(sections, budget)


def fit(sections: list[list[str]], budget: int) -> str:
    """Join sections; drop lines from the end of the lowest-priority (last) sections until within budget.
    The first line of the first section is kept (and clipped if it alone is too long)."""
    secs = [list(s) for s in sections]

    def text():
        return "\n".join(x for s in secs for x in s)
    while est_tokens(text()) > budget:
        i = max(j for j, s in enumerate(secs) if s)
        if i == 0 and len(secs[0]) == 1:
            secs[0][0] = clip(secs[0][0], budget)
            break
        secs[i].pop()
        if i > 0 and len(secs[i]) == 1:        # only the title is left
            secs[i].pop()
    return text()


def run_status(args, save_dir: Path) -> int:
    print(status_text(save_dir))
    return 0


def run_brief(args, save_dir: Path) -> int:
    print(brief_text(save_dir, args.budget))
    return 0


def add_parsers(sub) -> None:
    sub.add_parser("status", help="one screen, <= 300 tokens")
    p = sub.add_parser("brief", help="subagent brief, <= 1.5k tokens")
    p.add_argument("--budget", type=int, default=BRIEF_TOKENS)
