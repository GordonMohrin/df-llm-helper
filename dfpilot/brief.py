"""`dfllm status` (<= 300 tokens) and `dfllm brief` (<= 1.5k tokens) from runtime files only."""
from __future__ import annotations

import re
import time
from pathlib import Path

from . import files, paths, schema
from .events import SEASON, YEAR, clip, est_tokens, fmt_age, fmt_d, fmt_event, fmt_tick, fmt_ticks

STATUS_TOKENS, BRIEF_TOKENS = 300, 1500
SUPPLY_MIN = {"drink_d": 170, "food_d": 60}
SRC_LABEL = {"beds": "no beds", "drink": "no drink", "food": "no food", "toppled": "toppled buildings"}   # FR-74
POP_QUIET_MIN = 10                        # FR-74: "no migrant wave in a year" is shown in the status from this many citizens
STRESS_SHOW = 20                          # show the stress sources from this share of stressed citizens
# FR-74 / decision 16: what the game documents about migrants (docs: the Immigration page of the wiki, DFHack's
# fix/population-cap and pop-control): the diagnosis names them, nothing steers the migrants
MIGRANT_RULES = ("the game: waves 1-2 fixed, later ones follow the wealth the last departing dwarf caravan reported, "
                 "deaths + insane of the last 5 years (>= 10 dangerous), population_cap and max-pop; none is steered")
# B digest order (most useful first); unlisted B types follow alphabetically
DIGEST_ORDER = ["ALERT_START", "ALERT_END", "LOCKDOWN_END", "STOCK_LOW", "MATERIAL_SHORT", "MOOD_NEED",
                "MOOD_START", "MOOD_END", "CANCEL_LOOP", "BREACH_STOP", "PROJECT_REQUEST", "DEATH_CLUSTER", "DEATH",
                "CAPTURE", "CARAVAN", "MIGRANTS", "PETITION", "READY_CHANGE", "POPCAP", "AUDIT", "DRILL_RESULT",
                "PHASE", "PROJECT_DONE", "KERNEL_SLOW", "ACT_FAIL", "WEALTH", "PAUSE"]


LIMITS = {"A": 50, "B": 500, "CMD": 50}   # newest events kept per section (all DECISION_NEEDED of the year)
NO_D = {"DEATH", "DEATH_CLUSTER"}       # digest types whose msg already says everything (FR-64: cause, evidence)


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
        self.full = full
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
    al = s.get("alarm")
    defcon = f"DEFCON {al['defcon']}" if al else "DEFCON ?"     # FR-53: first on line 1
    unready = " UNREADY" if unready_r0(ctx) else ""            # FR-65: never a plain "PEACE" while R0 fails
    return (f"{defcon} | {ctx.save}{df} {fmt_tick(ctx.now_tick())} {mode}" + (f"({_ago(ctx, since)})" if since else "")
            + unready + (f" {s['phase']}" if "phase" in s else "") + f" {t.get('tps', '?')}t/s {run}{hold}"
            + f" hb {fmt_age(ctx.hb_age)}")


def line_save(save_dir: Path, now: float | None = None) -> str:
    """Run 10: the last `dfllm save` failed (<save>/quicksave.json ok 0, within a day): the game is not saved."""
    from .save import read_record
    rec = read_record(save_dir)
    now = time.time() if now is None else now
    if rec is None or rec["ok"] or now - rec["wall"] > 86400:
        return ""
    if rec.get("state") == "running":      # BUG-069: DF was still writing at the limit; not a failure yet
        age = max(0.0, now - rec["wall"])
        if age > 1800:                     # nobody settled it (no dfllm save, no follow): do not call it running for ever
            return f"QUICKSAVE UNSETTLED {fmt_age(age)} ago (never confirmed; dfllm save settles it): {clip(rec['why'], 90)}"
        return f"QUICKSAVE RUNNING {fmt_age(age)} ago: {clip(rec['why'], 120)}"
    return f"QUICKSAVE FAILED {fmt_age(max(0.0, now - rec['wall']))} ago: {clip(rec['why'], 120)}"


def line_guard(save_dir: Path) -> str:
    """FR-68: the stop guard `dfllm stop` left running in a dangerous mode (<save>/guard.json)."""
    g, age = files.read_guard(save_dir)
    if g is None or g["on"] != 1:
        return ""
    if age > files.GUARD_STALE_S:
        return (f"GUARD last seen {fmt_age(age)} ago (DF closed or crashed?): the FPS cap may still be {g['cap']}; "
                "the next dfllm boot or dfllm restore heals it")
    kinds = g.get("kinds") if isinstance(g.get("kinds"), dict) else {}
    ks = ", ".join(f"{k} {n}" for k, n in sorted(kinds.items()) if isinstance(n, int))
    last = str(g.get("last") or "")
    return (f"GUARD: kernel stopped in {g.get('mode', '?')} {fmt_age(max(0.0, time.time() - g['since']))} ago; "
            f"dfllm-guard holds FPS cap {g['cap']}{', timestream off' if g['ts_off'] else ''}, dismissed {g['n']} "
            f"popup{'s' if g['n'] != 1 else ''}" + (f" ({ks}; last: {clip(last, 40)})" if g["n"] else "")
            + " | dfhack-run dfllm boot resumes the kernel, dfllm restore releases the clock")


def unready_r0(ctx: Ctx) -> dict | None:
    """FR-65: the `ready` state while readiness is R0 (the siege readiness gate fails), else None."""
    r = ctx.s.get("ready")
    return r if isinstance(r, dict) and r.get("lvl") == 0 else None


R0_FORTCORE = ("no_outer", "no_inner", "bridge:", "levers:", "no_kern", "no_refuge")
WALL_RE = re.compile(r"\bwall -?\d+,-?\d+,-?\d+ (floor|ramp)\b")    # bp.topo.choke's wall in an audit finding


def line_unready(ctx: Ctx) -> str:
    """FR-65: 'SIEGE UNREADY (R0): <blockers> | <n> ways in without door or bridge: x,y,z kind ... | traps N |
    next: ...' (DESIGN §5.4 lists the blockers)."""
    r = unready_r0(ctx)
    if r is None:
        return ""
    fails, a = r.get("fail") or [], r.get("audit") or {}
    out = [f"SIEGE UNREADY (R0): {','.join(fails) or '?'}"]
    n, ents = r.get("open", -1), r.get("ents") or []
    pd = r.get("pd")
    if isinstance(pd, int):                    # FR-70: an open perimeter in PEACE is a stop signal; count the days
        out.append(f"PERIMETER OPEN {pd} day{'s' if pd != 1 else ''}: {r.get('pw') or '?'}")
    off = files.auto_seal_off(ctx.dir, n if isinstance(n, int) else 0) if getattr(ctx, "dir", None) else None
                                               # DECISIONS 2: follow --no-auto places nothing
    if off:
        out.append(off.replace("auto-seal off", "AUTO-SEAL OFF", 1) if isinstance(pd, int) else off)
    if n > 0:
        out.append(f"{n} way{'s' if n != 1 else ''} in without door or bridge: " + ", ".join(ents)
                   + (", ..." if n > len(ents) else ""))
    else:
        out.append("ways in: not checked yet" if n < 0 else "ways in: all with a door or bridge")
    t = a.get("min_traps", 0)
    why = "" if "bypass" not in fails else " (counted as if the bypass were walled)" if t else " (a bypass skips the hall)"
    out.append(f"traps {t}{why}" if a.get("age", -1) >= 0 else "traps ? (no audit)")
    route = r.get("route") if isinstance(r.get("route"), str) else ""
    if route:                                  # Run 10: the bypass stood for months; name it and its wall
        out.append(f"audit route: {route}")
    why = a.get("why") if isinstance(a.get("why"), str) else ""
    if why:                                    # BUG-043 (Run 11 y479): the audit box over the tile cap, for weeks
        out.append(f"audit snapshot refused: {why}")
    nxt = []
    if WALL_RE.search(route):
        nxt.append("wall it: dfllm cmd bp.place tpl=seal site=S1 at=audit (or a plan build seal p.at=audit)")
    elif route:
        nxt.append("no wall tile on that route: dfllm cmd inspect what=entrances")
    if why:
        nxt.append("the refusal's way out, then dfllm audit")
    elif a.get("age", -1) < 0 or any(f in ("audit", "audit_old") for f in fails):
        nxt.append("dfllm audit")
    if n > 0:
        nxt.append("close the open ways in (dfllm cmd bp.place tpl=seal site=S1 at=last)")
    if "open_perimeter" in fails:              # FR-70: max-pop and the ★ phases stay held until it is closed
        nxt.append("open perimeter: seal first (max-pop is held at the population from perimeter.hold_pop citizens "
                   "and `plan check` refuses a higher phase_target); a lost bridge: the keeper rebuilds it in quiet "
                   "PEACE or replaces it by wall + door (dfllm cmd inspect what=defense)")
    if any(f.startswith(R0_FORTCORE) for f in fails):
        nxt.append("build the missing fortcore pieces (plan)")
    where, far, lbl = refuge_place(ctx.s)      # BUG-040: where Tiefe+ lies and its nearest accepted water
    if "refuge_dry" in fails:                  # Run 11 siege 8: a dry Tiefe+ holds the citizens only in a breach
        nxt.append("the refuge has no drink" + (f" ({where})" if where else "")
                   + ": its drink store (tpl refuge_drink, FR-69; plan) or a well/cistern there")
    if "hospital_out" in fails:                # BUG-036: lying patients cannot walk to the refuge in a breach
        if far:                                # BUG-040 (Run 11 y453): Tiefe+ has no accepted water: Kern+ next to it
            nxt.append("the hospital lies outside Kern+/Tiefe+: Tiefe+ has no accepted water near it, so plan it inside "
                       f"Kern+ next to {lbl or 'accepted water'} (dfllm bp sites hospital), then remove the old zones")
        else:
            nxt.append("the hospital lies outside Kern+/Tiefe+: plan it inside Tiefe+ next to accepted water (a cistern "
                       "there first), then remove the old zones")
    if "burrow_lost" in fails:                 # BUG-096 (Run 14 note 70): Kern+ or the refuge lost a well or the refuge
        bg = (ctx.s.get("alert") or {}).get("bg")
        bg = bg if isinstance(bg, dict) else {}
        nxt.append(f"{bg.get('b') or 'Kern+/Tiefe+'} lost tiles that held {bg.get('crit') or 'a well or the refuge'}: the kernel "
                   f"paints them again ({bg.get('st') or 'see status `burrows`'}); where it cannot, paint them in the burrows "
                   "screen (w) or place the room again")
    if "office" in fails:                      # BUG-055 (Run 14 y577): a vacant office the kernel could not fill
        office = r.get("office") if isinstance(r.get("office"), str) else ""
        nxt.append(office or "a vacant office or squads without a leader: dfllm cmd inspect what=offices")
    lost = [f.split(":", 1)[1] for f in fails if f.startswith("lost:")]
    if lost:                                   # BUG-048: the keeper replaces it by wall + door (no question any more)
        nxt.append(f"{','.join(lost)} lost to building destroyers: the kernel replaces it by wall + door in quiet PEACE "
                   f"(dfllm cmd inspect what=defense; dfllm cmd bridge.rebuild only on Gordon's word)")
    if nxt:
        out.append("next: " + "; ".join(nxt))
    return _join(out)


QUIET_WHY = {"near": "a hostile is near", "inside": "a hostile inside Kern+", "great": "a great danger in reach",
             "recent": "a trigger within the last 2,400 ticks", "armed": "the threat scan is armed",
             "stale": "no fresh census", "run": "running"}


def lockdown_text(al: dict) -> str:
    """BUG-065 (Run 14, a gremlin held a lockdown for months while the brief said 'threat 0 vis'): the lockdown with its
    age and limit, its cause (unit, race, position, tiles to the nearest citizen outside Kern+ and entrance, harmless
    or dangerous) or that nothing is in sight, and why the quiet clock does not run."""
    txt = f"lockdown {al['why']}"
    if "age" in al:
        days = al["age"] / 1200
        lim = al.get("lim", 0)
        txt += (f" {days:.1f} of {lim / 1200:g} days" + (" (past the limit)" if al["age"] > lim else "")
                if lim else f" {days:.1f} days, no limit")
    by = al.get("by")
    if by:
        near = [f"{by['dc']} tiles from a citizen outside Kern+"] if by["dc"] >= 0 else []
        if by["de"] >= 0:
            near.append(f"{by['de']} from an entrance")
        txt += (f": cause {by['k']} {by['id']} {by['race']} at {','.join(str(c) for c in by['pos'])}"
                + "".join(f", {x}" for x in near)
                + (f", size {by['sz']}" if "sz" in by else ", size unknown")
                + (", harmless" if by.get("hl") else ", dangerous")
                + (f" (+{by['n'] - 1} more)" if by.get("n", 1) > 1 else ""))
    elif "qw" in al:
        txt += ": no hostile in sight"
    if al.get("qw"):
        txt += f"; quiet clock: {QUIET_WHY.get(al['qw'], al['qw'])}"
    return txt


def alarm_items(ctx: Ctx) -> list[tuple[int, str]]:
    """FR-51/53/55/58: the clock governor, the lockdown, unacked interrupts, lever latency and the arrival ETA. I1: ranked
    parts for the status (the lockdown with its cause, the unacked interrupts and the ETA are rank 2 and stay when the
    clock, the doors, the recall, the far invaders and the lever latency (rank 3) are cut); the brief joins them."""
    s, out = ctx.s, []
    c = s.get("clock")
    if c:
        if c["held"] or (c["orig"] and c["cap"] < c["orig"]):
            out.append((3, f"clock: held {c['cap']} t/s, reason {c['why'] or '?'}"))
        else:
            out.append((3, f"clock: free (cap {c['cap'] or '?'}" + (f", timestream {c['ts']}" if c["ts"] > 0 else "") + ")"))
    al = s.get("alarm")
    if al:
        if al["lock"]:
            out.append((2, lockdown_text(al)))
            if "doors" in al:                  # BUG-012: doors forbidden, and those waiting for citizens outside
                out.append((3, f"doors {al['doors']} forbidden" + (f", {al['dwait']} waiting for {al.get('dout', 0)}"
                                                                   f" citizens outside" if al.get("dwait") else "")
                            + (f", {al['dref']} refused (flag reset)" if al.get("dref") else "")))   # BUG-015
            if al.get("rn"):                   # BUG-035: the open recall (called, still out, who cannot come)
                out.append((3, f"recall: {al.get('rleft', al['rn'])} of {al['rn']} still outside {al.get('rto') or '?'}"
                            + (f" ({al['rstuck']} cannot come: RECALL stuck names them)" if al.get("rstuck") else "")
                            + (f", +{al['rnew']} more out since" if al.get("rnew") else "")))
        if al.get("ln"):                       # M3 (BUG-112): the lone harmless intruder's clock in SIEGE/BREACH
            ln = al["ln"]
            out.append((2, f"lone harmless intruder x{ln['n']} for {ln['age'] / 1200:.1f} d"
                        + (f", released in {ln['rel'] / 1200:.1f} d" if "rel" in ln else ", no release (confine.siege_release off)")
                        + (f"; kernel kill order: {ln['kill']}" if ln.get("kill") else "")))
        if al.get("ben"):                      # M3 (BUG-111): invaders by DF's flag that are no hostile to the player
            out.append((3, "not counted as hostile (id:why): " + ", ".join(al["ben"])))
        if al.get("far"):                      # Run 11: invaders a lockdown expired far (they re-arm on approach)
            out.append((3, f"{al['far']} invaders far (lockdown expired; re-arm within lockdown_near)"))
        if al["unacked"]:
            out.append((2, f"{al['unacked']} interrupts unacked (last #{al['last']}, acked #{al['ack']}): dfllm ack"))
        eta = al.get("eta", -1)
        if eta >= 0:
            tps = (s.get("t") or {}).get("tps") or 0
            out.append((2, f"eta ~{eta} t" + (f" (~{round(eta / tps)} s)" if tps > 0 else "") + " to the nearest entrance"))
    lv = s.get("lever")
    if lv:
        out.append((3, "lever_latency_s " + (f"{lv['lat_s']} ({lv['lat_t']} t)" if lv["lat_t"] >= 0 else "-")
                    + (f", {lv['pend']} pulls pending {lv['wait_s']} s" if lv["pend"] else "")))
    return out


def line_alarm(ctx: Ctx) -> str:
    """FR-51/53/55/58 as one line (the brief): alarm_items joined."""
    return _join(t for _, t in alarm_items(ctx))


def pop_diag(ctx: Ctx) -> str:
    """FR-74 (Run 13/14: 50 -> 33 in peace, no migrants since y481): who the citizens are (adults = not BABY and not
    CHILD; the rest are children, babies and residents), the peak, the deaths of the last year by cause and the migrant
    waves seen. In status only while the fort lost a tenth of its peak or saw no wave in a year; the brief always, with
    the game's migration conditions."""
    care = ctx.s.get("care") or {}
    pd = care.get("pop")
    cit = (ctx.s.get("pop") or {}).get("cit")
    if not isinstance(pd, dict) or not isinstance(cit, int):
        return ""
    shrunk = pd["peak"] - cit >= max(3, pd["peak"] // 10)
    quiet = pd["waves"] == 0 and cit >= POP_QUIET_MIN       # review: a young small fort has seen no wave yet, that is no trend
    if not (ctx.full or shrunk or quiet):
        return ""
    ad = (ctx.s.get("pop") or {}).get("adults")
    died = care.get("died_y") if isinstance(care.get("died_y"), dict) else {}
    by = ", ".join(f"{k} {v}" for k, v in sorted(died.items(), key=lambda kv: (-kv[1], kv[0]))[:4])
    last = "none seen" if pd["lastw"] < 0 else f"last {pd['lastw']} d ago"
    out = (f"pop trend: {cit} of peak {pd['peak']}, {ad if isinstance(ad, int) else '?'} adults + {pd['kids']} children/babies"
           f" + {pd['res']} residents; deaths in 365 d: {pd['dy']}" + (f" ({by})" if by else "")
           + f"; migrants in 365 d: {pd['waves']} waves, {pd['mig']} people ({last})")
    return out + ("; " + MIGRANT_RULES if ctx.full and (shrunk or quiet) else "")


def curse_items(ctx: Ctx) -> list[tuple[int, str]]:
    """BUG-115 (Run 14 y707: 23 dwarves became werecavies and nobody knew): 'CURSED 3 (ids 12,45,78), 1 in were-form, next full
    moon ~d206 (in 4 d)'. Rank 2: it stays when the clock, the doors and the readiness detail are cut. The moon is an estimate
    until a transformation wave was seen (state curse.mo calibrates from it)."""
    c = ctx.s.get("curse")
    if not isinstance(c, dict):
        return []
    ids = c.get("ids") or []
    total = (c.get("n") or 0) + (c.get("tf") or 0)
    txt = f"CURSED {total}" + (f" (ids {','.join(str(i) for i in ids)}" + (f" +{total - len(ids)}" if total > len(ids) else "") + ")"
                               if ids else "")
    txt += f", {c['tf']} in were-form" if c.get("tf") else ""
    if "mo" in c:
        txt += f", next full moon ~d{c['mo']} (in {c.get('mi', '?')} d)"
    if c.get("dead"):
        txt += f", {c['dead']} died"
    return [(2, txt)]


def line_stress0(ctx: Ctx) -> str:
    """FR-83 (note 93): 'stress level 0 (desperate): 4 units: 12 Urist, 40 Kel ...'; the names the unit sheets show."""
    s0 = (ctx.s.get("care") or {}).get("s0")
    if not isinstance(s0, dict) or not s0.get("n"):
        return ""
    ids, nm = s0.get("ids") or [], s0.get("nm") or []
    who = ", ".join(f"{i} {n}" for i, n in zip(ids, nm))
    return (f"stress level 0 (desperate): {s0['n']} units" + (f": {who}" if who else "")
            + (f" +{s0['n'] - len(ids)}" if s0["n"] > len(ids) else "") + " (dfllm cmd inspect what=unit key=<id>)")


# FR-84: the countermeasure of each stress source the kernel names (care.src keys), the top one is shown in the brief
STRESS_FIX = {"ghosts": "a slab and a tomb for every dead (autoslab, tombs.repair)",
              "deaths": "bury the dead at once (coffins, tombs), no body left lying",
              "beds": "bedrooms (bp.place bedrooms)", "drink": "brew and keep drink in stock",
              "food": "farms, kitchen, meals", "rooms": "a dining hall and rooms (plan propose)",
              "toppled": "a temple and a tavern (plan propose); the culprits are named by BUILDING_TOPPLED"}
TANTRUM_SHOWN = 3
TARGET_WORDS = ("statue", "altar", "temple", "throne", "pedestal", "shrine")


def tantrum_targets(ctx: Ctx) -> dict[str, int]:
    """FR-84: buildings toppled in tantrums in the last year (BUILDING_TOPPLED, the `n` further ones counted), by name."""
    out: dict[str, int] = {}
    for e in ctx.b:
        if e.get("type") == "BUILDING_TOPPLED":
            d = _d(e)
            w = str(d.get("what") or "?")
            out[w] = out.get(w, 0) + 1 + (d.get("n") if isinstance(d.get("n"), int) else 0)
    return out


def line_stress(ctx: Ctx) -> str:
    """FR-84 (note 84e): the top stress source with its countermeasure, and what the tantrums tore down (statues and temple
    objects first: the Run 14 curse followed a toppled statue). Brief only; nothing when there is nothing to say."""
    c = ctx.s.get("care") or {}
    src = c.get("src") if isinstance(c.get("src"), dict) else {}
    parts = []
    if src and c.get("stressed_pct", 0) >= STRESS_SHOW:
        k, v = sorted(src.items(), key=lambda kv: (-kv[1], kv[0]))[0]
        parts.append(f"stress {c['stressed_pct']}%: top cause {SRC_LABEL.get(k, k)} {v} -> {STRESS_FIX.get(k, 'see plan propose')}")
    tg = tantrum_targets(ctx)
    if tg:
        order = sorted(tg.items(), key=lambda kv: (not any(w in kv[0].lower() for w in TARGET_WORDS), -kv[1], kv[0]))
        shown = ", ".join(f"{w} {n}" for w, n in order[:TANTRUM_SHOWN])
        art = any(any(w in k.lower() for w in TARGET_WORDS) for k in tg)
        parts.append(f"tantrums tore down {sum(tg.values())} buildings in a year ({shown}"
                     + (f", +{len(tg) - TANTRUM_SHOWN} kinds" if len(tg) > TANTRUM_SHOWN else "") + ")"
                     + ("; a toppled statue or temple object preceded the Run 14 curse: calm the stressed first" if art else ""))
    return " | ".join(parts)


def stale_note(s: dict, key: str) -> str:
    """BUG-071: ' (last known 2d ago)' when the kernel published `key` from its last known value (state stale: game ticks)."""
    age = (s.get("stale") or {}).get(key)
    return f" (last known {fmt_ticks(age)} ago)" if isinstance(age, int) else ""


def pop_items(ctx: Ctx) -> list[tuple[int, str]]:
    """Ranked parts of the pop line (I1: status ranks them apart, so the long pop trend and the readiness summary go before
    the lockdown line does; the brief joins them): pop (1), the pop trend (3), the readiness summary (3)."""
    s = ctx.s
    out: list[tuple[int, str]] = []
    p = s.get("pop")
    if p:
        out.append((1, f"pop {p.get('cit', '?')} ({p.get('adults', '?')}ad {p.get('soldiers', '?')}sol)"
                       f" cap {p.get('cap', '?')} gate {p.get('gate_cap', '?')}" + stale_note(s, "pop")))
    out.append((3, pop_diag(ctx)))
    r = s.get("ready")
    if r:
        a = r["audit"]
        if r["lvl"] == 0:
            head = "R0 UNREADY"                # the blockers stand in the SIEGE UNREADY line (FR-65)
        else:
            head = f"R{r['lvl']}" + (f" fail:{','.join(r['fail'])}" if r["fail"] else " ok")
        drill = f"drill {fmt_ticks(r['drill_age'])}"
        if r["drill_age"] < 0:                 # FR-65: say why no drill ran and how to run one
            drill += (f" (auto: {r['dhold']}; run dfllm cmd drill)" if r.get("dhold") else " (run dfllm cmd drill)")
        if r.get("dref"):                      # BUG-110: drills refused for want of O1/B1 (counted once a game day)
            drill += f" [{r['dref']} refused: build fortcore stage 2/3 first]"
        audit = (f"audit {'ok' if a['ok'] else 'FAIL'} {fmt_ticks(a['age'])}" if a["age"] >= 0
                 else "audit never (run dfllm audit)")
        if a.get("cov"):                       # BUG-043: what its snapshot covered (margin, shafts, pieces out)
            audit += f" ({a['cov']})"
        low = any(str(f).startswith("traps<") for f in r["fail"]) and a["age"] >= 0
        out.append((3, f"{head} worn {r['worn']}% cv {r['cv']} {drill} {audit} traps {a['min_traps']}"
                       + (" (dfllm audit: where the cheapest route enters the hall)" if low else "")))
    return out


def line_pop(ctx: Ctx) -> str:
    return _join(t for _, t in pop_items(ctx))


def src_name(w: dict, i: int) -> str:
    """BUG-040: 'well 19098 at 137,77,143 in Kern+' from state water.src/src_l, else 'accepted water at x,y,z'."""
    src, lbl = w.get("src") or [], w.get("src_l") or []
    pos = ",".join(str(v) for v in src[i])
    if i < len(lbl) and isinstance(lbl[i], str) and lbl[i]:
        kind, _, inn = lbl[i].partition(" in ")
        return f"{kind} at {pos}" + (f" in {inn}" if inn else "")
    return f"accepted water at {pos}"


def refuge_place(s: dict) -> tuple[str, bool, str]:
    """BUG-040 (Run 11 y453: 'Tiefe+ has no drink' and nobody knew where Tiefe+ lies): ('Tiefe+ 126-128,56-77
    z129-136; no accepted water in it, nearest: well 19098 at 137,77,143 in Kern+, 9 tiles', dry = no wet well in the
    refuge (state water.refuge_ok 0), the nearest source's label) from state alert.ref (box, wd, ws) and water (src,
    src_l, refuge_ok); ('', False, '') while the state does not say where the refuge lies."""
    ref = ((s.get("alert") or {}).get("ref") or {}) if isinstance(s.get("alert"), dict) else {}
    box = ref.get("box") if isinstance(ref, dict) else None
    if not (isinstance(box, list) and len(box) == 6):
        return "", False, ""
    where = f"Tiefe+ {box[0]}-{box[3]},{box[1]}-{box[4]} z{box[2]}-{box[5]}"
    w = s.get("water") if isinstance(s.get("water"), dict) else {}
    dry = w.get("refuge_ok") == 0
    src, wd, ws = w.get("src") or [], ref.get("wd", -1), ref.get("ws")
    if not src or not isinstance(wd, int) or wd < 0:
        return where + "; no accepted water in the fort", True, ""
    i = next((k for k, p in enumerate(src) if p == ws), 0)
    lbl = src_name(w, i)
    return where + ("; no accepted water in it" if dry else "") + f"; nearest accepted water: {lbl}, {wd} tiles", dry, lbl


def _hospital(s: dict, st: dict) -> str:
    """BUG-034: the hospital's water as the kernel's water module judges it (state water: an accepted source within
    `near` tiles of every hospital zone; src = accepted sources; the patients), else care's narrower stock.hosp_water
    (a wet well beside a hospital zone, on its level)."""
    w = s.get("water")
    if isinstance(w, dict):
        h = "none" if not w["hosp"] else ("ok" if w["hosp_ok"] else "DRY")
        return (f" hospital {h} src {len(w['src'])}"
                + (f" ({src_name(w, 0)})" if w["src"] and w.get("src_l") else "")       # BUG-040: which and where
                + (f" patients {w['patients']} (thirst {w['thirst_max']})" if w["patients"] else ""))
    return f" water {'ok' if st['hosp_water'] else 'NO'}" if "hosp_water" in st else ""


def mandatory_fix(miss: list) -> str:
    """FR-76: the placement that builds exactly the missing mandatory workshops (follow does it itself on the kernel's
    request; `only` is cmd.place's list of shops to build)."""
    return "dfllm cmd bp.place tpl=workshops site=S1 only=" + ",".join(miss)


def adopt_line(s: dict) -> str:
    """FR-76 (state adopt, runner): what stands in the fort the kernel adopted (a reclaimed one has workshops no project of
    ours built), the manifest repairs (BUG-066: workshops gone from it) and the mandatory workshops it lacks, with the fix."""
    a = s.get("adopt")
    if not isinstance(a, dict) or not (a.get("rec") or a.get("gone") or a.get("miss")):
        return ""                                       # a fort the kernel built itself: nothing worth a line
    bits = [f"{a['ws']} workshops standing"]
    if a.get("new"):
        bits.append(f"{a['new']} adopted")
    if a.get("gone"):
        bits.append(f"{a['gone']} destroyed, out of the manifest")
    bits += [f"{a[k]} {k}" for k in ("stock", "wells", "beds", "doors") if k in a]
    txt = ("adopted fort: " if a.get("rec") else "manifest: ") + ", ".join(bits)
    miss = a.get("miss") or []
    if miss:
        txt += f"; MISSING {', '.join(miss)}: follow places them, or `{mandatory_fix(miss)}`"
    return txt


IDLE_NAMES = (("rest", "rest"), ("hurt", "hurt"), ("mood", "mood"), ("free", "no job"))


def idle_clause(lb: dict) -> str:
    """FR-77: 'idle 54% = 7 of 13 adults (rest 2, hurt 1, mood 1, no job 3; 6 soldiers not counted; the kernel holds 2
    projects: dfllm cmd inspect what=workload splits the rest) starving 0'. The kernel's daily scan knows a unit's own state
    (rest, hurt, mood); `no job` is the rest, which `inspect workload` splits further (held by a kernel rule, no labor
    holder, no reachable work). Without the breakdown (an older kernel): 'idle 20% starving 0'."""
    why, n = lb.get("why"), lb.get("n")
    if not isinstance(why, dict) or not isinstance(n, int):
        return f"idle {lb['idle']}% starving {lb['starving']}"
    parts = [f"{label} {why[k]}" for k, label in IDLE_NAMES if why.get(k)]
    idle_n = sum(v for v in why.values() if isinstance(v, int))
    extra = []
    if lb.get("sold"):
        extra.append(f"{lb['sold']} soldiers not counted")
    held = lb.get("held", 0)
    if held:
        extra.append(f"the kernel holds {held} project{'s' if held != 1 else ''}")
    inner = ", ".join(parts) or "no reason of its own state"
    tail = "; ".join(([inner] if not extra else [inner] + extra))
    hint = ": dfllm cmd inspect what=workload splits the rest" if why.get("free") or held else ""
    return f"idle {lb['idle']}% = {idle_n} of {n} adults ({tail}{hint}) starving {lb['starving']}"


def supply_items(ctx: Ctx) -> list[tuple[int, str]]:
    """Ranked parts of the supply line (I1: one rank-1 bundle of stock, forbidden, adopted fort, orders, stress, deaths,
    coffins and idle pushed the lockdown line out of the status): the stock sentence with its cause (why the stills do not
    brew, the forbidden stock) stays rank 1; the rest is three rank-4 lines (adopted fort and the manager note, care, work and orders) that go first. The brief joins them all."""
    s, out, fort, care, work = ctx.s, [], [], [], []
    st = s.get("stock")
    if st:
        lo = {k for k, m in SUPPLY_MIN.items() if k in st and st[k] < m}
        # BUG-059 (Run 12 y503: 12 starved under "food 41 d", meals 0): the hungry citizens come first, and no prepared
        # meal beside them says that the food days count raw food nobody cooks
        hungry = st.get("hungry", 0)
        out.append((1, "stock " + (f"HUNGRY {hungry} " if hungry else "") + " ".join(
            f"{k[:-2]} {st[k]}d" + ("!" if k in lo else "") for k in ("drink_d", "food_d") if k in st)
            + (f" meals {st['meals']}" if "meals" in st else "")
            + (" (raw food is not cooked)" if hungry and st.get("meals") == 0 else "")
            + _hospital(s, st)
            # Run 10: the ore search and the leather a mood missed (plan propose/check read them too)
            + (f" ore {st['ore']} bars {st.get('bars', '?')}" + (" (explore)" if st.get("metal") == "explore" else "")
               # Run 11: metal short for the soldiers (the kernel asks every caravan for metal), gear to melt
               + (" METAL SHORT" if st.get("mshort") else "") + (f" melt {st['melt']}" if st.get("melt") else "")
               if "ore" in st else "")
            + (f" leather {st['leather']}" if "leather" in st else "")
            + (f" moods missed {','.join(st['mood_miss'])}" if st.get("mood_miss") else "")
            + stale_note(s, "stock")))
        # BUG-042: why the stills do not brew while drink is below the target (the kernel's own cause)
        if st.get("dwhy"):
            out.append((1, f"drink: {st['dwhy']}"))
        # FR-76 (Run 12 Trussroads, reclaimed: 3026 of 3058 drinks forbidden, "drink 46d!"): the forbidden stock the days
        # above do not count, and what the kernel does about it
        if st.get("dforb") or st.get("fforb"):
            parts = [f"{st[k]} {name} items forbidden" for k, name in (("dforb", "drink"), ("fforb", "food")) if st.get(k)]
            out.append((1, ", ".join(parts) + " (not in the days above; the kernel unforbids them)"))
    ad = adopt_line(s)
    if ad:
        fort.append(ad)
    od = s.get("orders")
    if isinstance(od, dict) and od.get("mgr"):
        # BUG-042: orders wait for the manager: how many, how long, why (the office's chair/table, ...)
        fort.append(f"orders: {od.get('unval', 0)} unvalidated, oldest {od.get('uval_d', 0)} d: {od['mgr']}")
    c = s.get("care")
    if c:
        # FR-74: the sources of a high stress; BUG-062: tomb zones left closed to citizens
        src = c.get("src") if isinstance(c.get("src"), dict) else {}
        srcs = ", ".join(f"{SRC_LABEL.get(k, k)} {v}" for k, v in sorted(src.items(), key=lambda kv: (-kv[1], kv[0])))
        care.append(f"stress {c['stressed_pct']}%" + (f" ({srcs})" if srcs and c["stressed_pct"] >= STRESS_SHOW else "")
                   + f" naked {c['naked']} ghosts {c['ghosts']} corpses {c['corpses_old']}"
                   # BUG-105: bodies on a tile nobody can path to (tree crowns): apart from the burial goal
                   + (f" (+{c['corpses_unreach']} unreachable)" if c.get("corpses_unreach") else "")
                   + f" tombs {c['tombs_free']}" + (f" ({c['tombs_locked']} closed to citizens)" if c.get("tombs_locked") else "")
                   + f" moods {c['moods']}")
        died = c.get("died")
        if died:                               # FR-64: citizen deaths of the last season by cause
            care.append("deaths (season) " + ", ".join(f"{k} {n}" for k, n in sorted(died.items(),
                                                                                   key=lambda kv: (-kv[1], kv[0]))))
        cf = c.get("coffins")
        if cf and (cf["want"] > c["tombs_free"] or cf["order"] or cf["proj"]):
            # FR-61 coffin provisioner: free tombs wanted, slots missing, coffin items, open orders, project
            care.append(f"coffins want {cf['want']} short {cf['short']} stock {cf['stock']} order {cf['order']}"
                       + (f" proj {cf['proj']}" if cf["proj"] else "")
                       # FR-76 (Run 12 reclaim: the kernel only said "short coffins"): no Carpenters workshop, no coffin
                       + (" (no Carpenters workshop stands: see adopted fort)"
                          if "Carpenters" in ((s.get("adopt") or {}).get("miss") or []) and cf["short"] else ""))
    # BUG-106: the hospital's gaps (the tokens; `inspect what=hospital` has the counts), a rank-4 line like the care line
    gaps = (s.get("water") or {}).get("gaps") if isinstance(s.get("water"), dict) else None
    if gaps:
        care.append("hospital gaps: " + ", ".join(gaps) + " (dfllm cmd inspect '{\"what\":\"hospital\"}')")
    lb = s.get("labor")
    if lb:
        work.append(idle_clause(lb) + stale_note(s, "labor"))
    od = s.get("orders")
    if od:                                     # FR-01/FR-39: orders that cannot run, crash-class orders
        # BUG-059: of the stuck orders, the ones that miss a workshop (named) apart from the ones that miss a worker
        why = [x for x in (f"workshop missing {od['stuck_ws']}: {od.get('ws', '?')}" if od.get("stuck_ws") else "",
                           f"no worker {od['stuck_lab']}" if od.get("stuck_lab") else "") if x]
        work.append(f"orders {od['n']}" + (f" stuck {od['stuck']}" if od["stuck"] else "")
                   + (f" ({'; '.join(why)})" if why else "")
                   + (f" UNSAFE {od['bad']} (no item_subtype: DF crash)" if od["bad"] else "")
                   # BUG-061: a workshop type's slots are full of jobs that cancel at once
                   + (f" JAM {od['jam']}" if od.get("jam") else ""))
    # three rank-4 lines (each as before: parts joined by ' | '); the last goes first, a line that does not fit goes whole
    return out + [(4, _join(g)) for g in (fort, care, work) if g]


def line_supply(ctx: Ctx) -> str:
    return _join(t for _, t in supply_items(ctx))


def def_parts(ctx: Ctx) -> tuple[list[str], list[str]]:
    """The defense line in two parts. J3: the core is what a siege needs (threat, bridges, alert with the refuge's trust, the
    army's count, intake, caravan); the detail (the melee sets, the free metal gear, the militia rotation of FR-79: 40-100
    tokens) comes last in status and brief. One atomic line used to leave status whole when its detail grew: at 80
    citizens one rotation line took the bridges and `refuge NOT TRUSTED` with it, and in a siege the line did not fit at all."""
    s, out, extra = ctx.s, [], []
    th = s.get("threat")
    if th:
        al = s.get("alarm")
        out.append(f"threat {th['vis']} vis" + (" ARMED" if th["armed"] else "")
                   # BUG-065: a held lockdown is not 'nothing': say what holds it
                   + (f" (lockdown holds: quiet clock {al['qw']})" if th["vis"] == 0 and al and al.get("lock")
                      and al.get("qw") else ""))
    if s.get("bridges"):
        # BUG-030: a destroyed bridge stands out (an open way, no pulls for it)
        out.append("bridges " + " ".join(f"{b} {'DESTROYED' if v == 'destroyed' else v}"
                                         for b, v in sorted(s["bridges"].items())))
    if s.get("alert"):
        out.append(line_alert(s["alert"]))
    m = s.get("mil")
    if m:
        out.append(f"mil {m['squads']}sq {m['soldiers']}sol worn {m['worn']}% cv {m['cv']} metal {m['metal_pct']}%"
                   f" station {m['on_station']}")
        cap = m.get("cap")
        if cap:                                # Run 11: the melee squads follow the armor + weapon + shield sets
            extra.append(f"melee {cap['melee']}/{cap['want']} (gear sets {cap['sets']})"
                         + (f", +{cap['xbow']} crossbow (metal short)" if cap["xbow"] else ""))
        free = {k: v for k, v in (m.get("free") or {}).items() if v}
        if free:                               # FR-46: free metal gear by category (loot included)
            extra.append("free metal " + " ".join(f"{k} {v}" for k, v in sorted(free.items())))
        for key, r in sorted((m.get("rot") or {}).items()):        # FR-79: the militia rotation per squad
            extra.append(line_rot(key, r))
    wv = s.get("wave")
    if wv and wv.get("bw"):                    # M3 (BUG-114): why a BREACH has not ended
        out.append(f"BREACH since {wv.get('ba', 0) / 1200:.1f} d: {wv['bw']}")
    elif wv:                                   # intake waves and the sortie through O1 (Gordon 2026-10-16)
        out.append(f"intake {wv['ph']} (waves {wv['n']})" + (f": {wv['why']}" if wv.get("why") else "")
                   + (f", sortie {wv['so']}" if wv.get("so") else "")
                   # BUG-030: the deep defense (civilians in the refuge, squads at the core station)
                   + (f", DEEP {wv['deep']}: civilians in the refuge, squads in the core" if wv.get("deep") else ""))
    tr = s.get("trade")
    if tr and tr["caravan"]:
        out.append("CARAVAN on map")
    return out, extra


def line_def(ctx: Ctx) -> str:
    core, extra = def_parts(ctx)
    return _join(core + extra)


def line_rot(key: str, r: dict) -> str:
    """FR-79 (state mil.rot): 'militia B 9-11 off duty: 4/4 sit, 45 eligible, served 0-1, turnover in 98 d; held: lockdown'. The
    counts, never names; `why` is what holds the turnover or how the last one ended."""
    if "n" not in r:                           # no squad to rotate (yet), or its target is 0
        return f"militia {key} {r.get('w', '?')}: {r.get('why', 'no squad')}"
    txt = (f"militia {key} {r.get('w', '?')} {'on duty' if r.get('on') else 'off duty'}: {r.get('n', '?')}/{r.get('z', '?')} sit,"
           f" {r.get('e', '?')} eligible, served {r.get('lo', 0)}-{r.get('hi', 0)}")
    nx = r.get("nx")
    if nx is not None:
        txt += ", turnover due" if nx == 0 else f", turnover in {nx} d"
    if r.get("why"):
        txt += f"; {r['why']}"
    return txt


def line_alert(al: dict) -> str:
    """FR-33/37: the civ-alert burrow (seal's audited choice), its size and the citizens inside it."""
    b = al["burrow"] or "no confinement (whole fort)"
    txt = f"alert {b}" + (f" {al['tiles']}t {al['inside']} in" if al["burrow"] else "")
    if not al["ok"]:
        txt += f" ({al['want']} refused" + (f": {al['why']}" if al.get("why") else "") + ")"
    ref = al.get("ref") if isinstance(al.get("ref"), dict) else {}
    if ref.get("tr") == 0:                     # BUG-049: Tiefe+ is trusted only while separated (fresh), hatched, empty
        txt += f" | refuge NOT TRUSTED: {ref.get('trw') or '?'}"
    return txt


def line_burrow(ctx: Ctx) -> str:
    """BUG-096/FR-80 (state alert.bg, seal's burrow guard): 'burrows: Kern+ 9 of 121 tiles (runtime), 40 painted again, repairing;
    held: well,refuge' while a burrow is below its last good reading (the worst one; '+N more' for others), '' when none."""
    bg = (ctx.s.get("alert") or {}).get("bg")
    if not isinstance(bg, dict):
        return ""
    txt = (f"burrows: {bg.get('b', '?')} {bg.get('now', '?')} of {bg.get('was', '?')} tiles ({bg.get('c', '?')}), "
           f"{bg.get('fx', 0)} painted again" + (f", {bg['st']}" if bg.get("st") else ""))
    if bg.get("crit"):
        txt += f"; held: {bg['crit']}"
    if bg.get("n", 1) > 1:
        txt += f" (+{bg['n'] - 1} more)"
    return txt


def line_proj(ctx: Ctx, n: int = 3) -> str:
    pr = ctx.s.get("proj") or []
    if not pr:
        return "proj none" if "proj" in ctx.s else ""
    items = [f"{i} {st} {pct}%" + (f" BLOCKED:{b}" if b else "") for i, st, pct, b in pr[:n]]
    return "proj " + ", ".join(items) + (f" +{len(pr) - n}" if len(pr) > n else "")


def line_sched(ctx: Ctx) -> str:
    """Run 11 siege 8 (state sched, runner): 'seal open: 3 pieces (c1a147c261), others paused' while an open seal or plug
    pauses the housing/work projects (`runs first` when it pauses none now, e.g. outside PEACE), 'seal stuck 3 d: ...,
    others run (SEAL_STUCK)' once it built nothing for seal_first.stuck_days; 'rebuild: pop 2 < 10, only
    seal/tombs/food/beds (4 paused, ends at 12)' while the rebuild policy holds."""
    sc = ctx.s.get("sched")
    if not isinstance(sc, dict):
        return ""
    out = []
    se = sc.get("seal")
    if isinstance(se, dict):
        n = se.get("n", 0)
        more = f" +{se['more']} seal{'s' if se['more'] != 1 else ''}" if se.get("more") else ""
        what = f"{n} piece{'s' if n != 1 else ''} ({se.get('proj')}{more})"
        if se.get("stuck"):
            out.append(f"seal stuck {se.get('days', 0)} d: {what}, others run (SEAL_STUCK)")
        else:
            out.append(f"seal open: {what}, " + ("others paused" if se.get("paused") else "runs first"))
    rb = sc.get("rb")
    if isinstance(rb, dict):
        tail = ", ".join(x for x in (f"{rb['paused']} paused" if rb.get("paused") else "",
                                     f"ends at {rb['hi']}" if rb.get("hi") else "") if x)
        out.append(f"rebuild: pop {rb.get('pop')} < {rb.get('lo')}, only seal/tombs/food/beds" + (f" ({tail})" if tail
                                                                                                  else ""))
    out += sched_queue(sc)
    return _join(out)


def sched_queue(sc: dict) -> list[str]:
    """BUG-037 (Run 11 y449: six projects 'queued' at 0 % for months): who holds the runner's slots while projects wait
    ('queued: 6 behind c1a148696a3d6da701 seal, depot7 depot 9 d no progress, ...'), a runner whose runs stopped ('runner:
    no run ended for 30 d (task 2/9 work c1a1..., 900 slices): dfllm doctor') and the parked projects."""
    out = []
    run = sc.get("run")
    if isinstance(run, dict):
        at = (f" (task {run.get('i')}/{run.get('n')} {run.get('task', '?')}, {run.get('sl', 0)} slices)"
              if run.get("task") else "")
        out.append(f"runner: no run ended for {run.get('d')} d{at}: dfllm doctor, inspect modules")
    q = sc.get("q")
    if isinstance(q, dict) and q.get("n"):
        who = ", ".join(f"{i} {t}" + (f" {d} d no progress" if d >= 2 else "") for i, t, d in q.get("by") or [])
        out.append(f"queued: {q['n']} behind {who or '?'}")
    if sc.get("pk"):
        out.append(f"{sc['pk']} parked (blocked for good: bp.cancel, PROJECT_BLOCKED)")
    return out


def line_kern(ctx: Ctx) -> str:
    s = ctx.s
    k = s.get("k")
    out = []
    if k:
        out.append(f"kern {k['ms_s']}ms/s gap {k['gap_max_ms']}ms faults {k['faults']}"
                   + (f" top {k['top']}" if k.get("top") else "")             # BUG-033: the top cost owner
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


def line_snap(ctx: Ctx) -> str:
    """BUG-033: a starving snapshot export queue (the oldest request waits >= doctor.SNAP_STARVE_S), else ''."""
    from .doctor import snap_queue
    line, starving = snap_queue(ctx.s)
    return f"{line} (dfllm audit / bp sites --fresh wait; dfllm doctor)" if line and starving else ""


def _no_state(ctx: Ctx) -> str:
    errs = "; ".join(f"{k}: {v}" for k, v in ctx.info.get("errors", {}).items()) or "no state file"
    return f"no valid state ({errs[:160]})"


# ---------------------------------------------------------------- status
def fit_ranked(items: list[tuple[int, str]], budget: int, clip_tokens: int = 90) -> str:
    """BUG-071: join the lines in order, within the token budget, by RANK instead of position. Rank 0 (the clock line) and
    rank 1 (pop, stock, the warnings) stay. Over budget: whole lines of rank >= 3 go (highest rank, latest first); then the
    long rank-2 lines (UNREADY, alarm) are cut to clip_tokens; then those go; only then are the rank-1 lines shortened.
    (The old fit dropped lines from the end, so a long UNREADY or alarm line pushed pop and stock out and status showed the
    clock line alone.)"""
    its = [[r, t] for r, t in items if t]

    def text() -> str:
        return "\n".join(t for _, t in its)

    def drop(min_rank: int) -> bool:
        low = [i for i, (r, _) in enumerate(its) if r >= min_rank]
        if not low:
            return False
        worst = max(its[i][0] for i in low)
        its.pop(max(i for i in low if its[i][0] == worst))
        return True
    while est_tokens(text()) > budget and drop(3):
        pass
    for cut in (clip_tokens, 60):          # I1: cut the rank-2 lines harder before one of them goes whole
        if est_tokens(text()) > budget:
            for it in its:
                if it[0] == 2:
                    it[1] = clip(it[1], min(cut, clip_tokens))
    while est_tokens(text()) > budget and drop(2):
        pass
    while est_tokens(text()) > budget:
        mid = [i for i, (r, _) in enumerate(its) if r == 1 and est_tokens(its[i][1]) > 12]
        if not mid:
            its[0][1] = clip(its[0][1], budget)
            break
        i = max(mid, key=lambda k: est_tokens(its[k][1]))
        its[i][1] = clip(its[i][1], max(10, est_tokens(its[i][1]) - 20))
    return text()


def status_text(save_dir: Path) -> str:
    ctx = Ctx(save_dir, full=False)
    lines = [(0, line_head(ctx)), (1, line_guard(save_dir)), (1, files.follow_off(save_dir)),   # FR-68, FR-29
             (1, line_save(save_dir))]
    if ctx.state is None:
        lines.append((1, _no_state(ctx)))
    else:
        lines += [(2, line_unready(ctx))] + curse_items(ctx) + alarm_items(ctx) + pop_items(ctx) + supply_items(ctx)
        s0 = (ctx.s.get("care") or {}).get("s0")
        if isinstance(s0, dict) and s0.get("n"):
            lines.append((4, f"desperate (stress 0): {s0['n']}" + (f" ids {','.join(str(i) for i in s0.get('ids') or [])}"
                                                                   if s0.get("ids") else "")))
        core, extra = def_parts(ctx)
        lines += [(3, _join(core)), (3, line_burrow(ctx)), (3, line_sched(ctx)), (4, line_proj(ctx)), (4, line_kern(ctx)),
                  (4, line_snap(ctx)),
                  (5, _join(extra))]                                 # J3: the army's detail is the first line to go
    return fit_ranked(lines, STATUS_TOKENS)


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


def sec_curse(ctx: Ctx) -> list[str]:
    """BUG-115 (note 84c): what to do while citizens are cursed. No verb isolates a unit: the burrow and the door are the
    player's (UI); a kill order stays his decision (RULES 1: citizens)."""
    c = ctx.s.get("curse")
    if not isinstance(c, dict):
        return []
    return ["1 before the full moon (curse line above) put ALL the cursed (dfllm cmd inspect what=curse) in ONE room: a burrow "
            "they are restricted to + a forbidden door; tell Gordon (no kernel verb does it)",
            "2 a were-form unit is an enemy: keep the rest away; a kill order only after Gordon's yes (DECISION_NEEDED "
            "curse_kill; squad.sortie approve:true is the logged decision)",
            "3 watch the bitten: patients with bite wounds turn at the next moon (TRANSFORM bite=1 names them)"]


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
                   + (f" [{d}]" if d and t not in NO_D and d not in str(last.get("msg", "")) else ""))
    return out


def sec_deaths(ctx: Ctx) -> list[str]:
    """FR-64: the citizens who died in the last season, by cause (the newest DEATH per unit: a death found later
    revises the first one), with the killer, a patient and a death not found yet."""
    now = ctx.now_tick()
    if not isinstance(now, int):
        return []
    last: dict[int, dict] = {}
    for e in ctx.b:
        t, d = e.get("tick"), _d(e)
        if e.get("type") == "DEATH" and isinstance(t, int) and now - t < SEASON and isinstance(d.get("unit"), int):
            last[d["unit"]] = d
    by: dict[str, list[str]] = {}
    for u, d in sorted(last.items()):
        tag = (str(u) + (f" by {d['by']}" if d.get("by") else "") + (" patient" if d.get("patient") else "")
               + (" missing" if d.get("found") == 0 else ""))
        by.setdefault(str(d.get("cause") or "unknown"), []).append(tag)
    if not by:
        return []
    groups = sorted(by.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    return [" | ".join(f"{c} {len(v)}: {', '.join(v)}" for c, v in groups)]


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
    guard = line_guard(save_dir)                   # FR-68
    if guard:
        head.append(guard)
    off = files.follow_off(save_dir)               # FR-29
    if off:
        head.append(off)
    qs = line_save(save_dir)                       # Run 10: the game is not saved
    if qs:
        head.append(qs)
    if ctx.state is None:
        head.append(_no_state(ctx))
    else:
        core, extra = def_parts(ctx)                   # J3: the army's detail last: it goes first
        head += [x for x in (line_unready(ctx), _join(t for _, t in curse_items(ctx)), line_alarm(ctx), line_pop(ctx),
                             line_supply(ctx), line_stress0(ctx), line_stress(ctx), _join(core), line_burrow(ctx),
                             line_sched(ctx), line_proj(ctx, 8), line_kern(ctx), line_snap(ctx), _join(extra)) if x]
    sections = [head]
    for title, lines in (("## plan", sec_plan(ctx)), ("## decisions open (ask Gordon)", sec_decisions(ctx)),
                         ("## curse (recipe)", sec_curse(ctx)),
                         ("## class A, newest first", sec_class_a(ctx)),
                         ("## deaths (last season)", sec_deaths(ctx)), ("## failed commands", sec_failures(ctx)),
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
