"""Spec v3-04: time-standstill and window guard (runs inside the watcher, df_llm_helper/waechter.py).

Problem (Run 5, Y109): the game stood still for 5 minutes although pause_state was false, because the Info/Justice
screen and the Help screen were open; later a DFHack MessageBox ("trade finished") held the game, and after the trade
pause.hold ('karawane') and caravan.flag had to be deleted by hand.

Detection: the watcher's status line (CLEAR_CMD) carries pause state, focus and the frame counter (+ year tick).
If neither moves for `ticks_to_act` watcher ticks (2 s each) and a handled window class is on top, the guard sends
simulated menu input like a player would (SELECT for a MessageBox, LEAVESCREEN otherwise) until dwarfmode/Default.

Safety: never touches anything while a trade is in SELECT_LIVE/CONFIRM/FINISH (store kv "trade.flow"); grace period
for a window the player opened while time was running; at most `max_attempts` unsuccessful attempts in a row (then
one critical warning and no more input until time moves again) and at most `max_per_hour` attempts per hour.
Every action is logged in state.db (store.log_action, rule "freeze_guard").

Split: FreezeGuard.decide() is pure (observation + context -> Decision); apply() executes a decision with the
injected client/tools/store/clock. The Lua one-liners are LIVE-UNTESTED except the Info/Help LEAVESCREEN variant
(live version of 01.10.2026).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from .features.freeze_guard_cfg import DEFAULTS as CFG_DEFAULTS

__all__ = ["FocusObs", "FreezeCtx", "Decision", "FreezeGuard", "parse_status", "focus_classes", "leave_cmd",
           "apply", "ctx_from", "PROTECTED_TRADE_STATES", "DEFAULT_FOCUS", "RULE"]

RULE = "freeze_guard"
DEFAULT_FOCUS = "dwarfmode/Default"
PROTECTED_TRADE_STATES = ("SELECT_LIVE", "CONFIRM", "FINISH")
# focus class -> substring of getCurFocus(true) (order = priority for the event text)
CLASS_TOKENS = [("MessageBox", "MessageBox"), ("Trade", "/Trade"), ("Help", "Help"), ("Info", "/Info"),
                ("ViewSheets", "ViewSheets"), ("Designate", "/Designate"), ("Squads", "/Squads"),
                ("Announcement", "Announcement")]
# watcher status line: 'R 0 dwarfmode/Info/JUSTICE/OPEN_CASES|dwarfmode/Help fc=123 yt=456' (yt optional)
STATUS_RE = re.compile(r"^([PR]) (\d+) (\S*)\s*fc=(\d+)(?: yt=(\d+))?$")


@dataclass
class FocusObs:
    paused: bool
    popups: int
    focus: str
    fc: int
    yt: int | None = None


def parse_status(line: str) -> FocusObs | None:
    m = STATUS_RE.match((line or "").strip())
    if not m:
        return None
    return FocusObs(m.group(1) == "P", int(m.group(2)), m.group(3), int(m.group(4)),
                    int(m.group(5)) if m.group(5) is not None else None)


def focus_classes(focus: str) -> list[str]:
    """Window classes present in a joined focus string (empty for dwarfmode/Default and unknown screens)."""
    return [cls for cls, tok in CLASS_TOKENS if tok in (focus or "")]


def leave_cmd(key: str, tokens: list[str], allow_trade: bool = False) -> str:
    """One simulated key press on the top viewscreen, only if the focus still contains one of `tokens`
    (never on dwarfmode/Default: Escape there opens the options menu). Prints the focus afterwards. LIVE-UNTESTED
    for SELECT/MessageBox; the LEAVESCREEN variant matches the live version of 01.10.2026."""
    if key not in ("SELECT", "LEAVESCREEN"):
        raise ValueError(f"key not allowed: {key}")
    toks = ",".join(f"'{t}'" for t in tokens if re.match(r"^[A-Za-z/]+$", t))
    trade = "" if allow_trade else " and not f:find('Trade',1,true)"
    return ('lua "local g=require(\'gui\') local f=table.concat(dfhack.gui.getCurFocus(true),\'|\') local hit=false '
            f"for _,t in ipairs({{{toks}}}) do if f:find(t,1,true) then hit=true end end "
            f"if hit{trade} then g.simulateInput(dfhack.gui.getCurViewscreen(true),'{key}') end "
            "print(table.concat(dfhack.gui.getCurFocus(true),'|'))\"")


@dataclass
class FreezeCtx:
    trade_state: str | None = None
    trade_since: float | None = None
    hold: str | None = None            # text of pause.hold (None = no file)
    caravan_flag: bool = False
    hold_ts: float | None = None       # mtime of pause.hold / caravan.flag (aftercare only removes leftovers that
    caravan_ts: float | None = None    # are older than the end of the trade, never those of a new caravan)
    alert: bool = False
    enemy: bool = False
    actions_last_hour: int = 0


@dataclass
class Decision:
    kind: str                          # none | close | aftercare | give_up | capped | protected | unhandled
    focus: str = ""
    classes: list = field(default_factory=list)
    reason: str = ""
    close_box: bool = False            # aftercare: a MessageBox is open as well


class FreezeGuard:
    def __init__(self, cfg: dict | None = None):
        self.cfg = {**CFG_DEFAULTS, **(cfg or {})}
        self.last_fc: int | None = None
        self.last_yt: int | None = None
        self.last_moving = False
        self.still = 0
        self.focus: str | None = None
        self.focus_since = 0.0
        self.grace = False
        self.fails = 0
        self.gave_up = False
        self.capped = False
        self.noted: set = set()        # one-time notes (protected/unhandled) per focus
        self.aftercare_done: float | None = None

    # ---- pure decision
    def decide(self, obs: FocusObs, now: float, ctx: FreezeCtx) -> Decision:
        c = self.cfg
        moving = self.last_fc is not None and (obs.fc != self.last_fc or
                                               (obs.yt is not None and self.last_yt is not None and obs.yt != self.last_yt))
        self.still = 0 if (moving or self.last_fc is None) else self.still + 1
        if moving:                      # time runs again -> earlier attempts count as successful
            self.fails, self.gave_up, self.capped = 0, False, False
        if obs.focus != self.focus:
            # grace only for a window that appeared while time was running (= the player opened it)
            self.grace = (self.last_moving or moving) and bool(focus_classes(obs.focus)) and \
                "MessageBox" not in focus_classes(obs.focus)
            self.focus, self.focus_since = obs.focus, now
            self.noted = {n for n in self.noted if n[1] == obs.focus}
        self.last_fc, self.last_yt, self.last_moving = obs.fc, obs.yt, moving
        cls = focus_classes(obs.focus)
        # trade aftercare (spec 04 measure 4): independent of the frame counter
        if c.get("aftercare", True) and ctx.trade_state == "DONE" and ctx.trade_since != self.aftercare_done and \
                (_leftover(ctx.hold_ts, ctx) and (ctx.hold or "").startswith("karawane") or
                 ctx.caravan_flag and _leftover(ctx.caravan_ts, ctx)):
            return Decision("aftercare", obs.focus, cls, "trade DONE", close_box="MessageBox" in cls)
        if not cls:
            return Decision("none", obs.focus)
        if ctx.trade_state in PROTECTED_TRADE_STATES:
            return self._once("protected", obs.focus, cls, f"trade running ({ctx.trade_state})")
        if self.still < int(c["ticks_to_act"]) or (obs.paused and "MessageBox" not in cls):
            return Decision("none", obs.focus, cls)
        handled = set(c.get("classes") or [])
        if not (set(cls) & handled) or ("Trade" in cls and "Trade" not in handled):
            return self._once("unhandled", obs.focus, cls, "class not in freeze_guard.classes")
        if self.grace and now - self.focus_since < float(c["grace_s"]):
            return Decision("none", obs.focus, cls, "grace period")
        if self.gave_up or self.capped:
            return Decision("none", obs.focus, cls, "gave up")
        if self.fails >= int(c["max_attempts"]):
            self.gave_up = True
            return Decision("give_up", obs.focus, cls, f"{self.fails} attempts without effect")
        if ctx.actions_last_hour >= int(c["max_per_hour"]):
            self.capped = True
            return Decision("capped", obs.focus, cls, f"{ctx.actions_last_hour} attempts in the last hour")
        self.fails += 1
        self.still = 0                  # the next attempt needs another full detection window
        return Decision("close", obs.focus, cls, f"time still for {c['ticks_to_act']} ticks")

    def _once(self, kind: str, focus: str, cls: list, reason: str) -> Decision:
        key = (kind, focus)
        if key in self.noted:
            return Decision("none", focus, cls, reason)
        self.noted.add(key)
        return Decision(kind, focus, cls, reason)


def _leftover(ts: float | None, ctx: FreezeCtx) -> bool:
    """Flag file written before the trade reached DONE (+5 s slack) = leftover of that trade."""
    return ts is None or ctx.trade_since is None or ts <= float(ctx.trade_since) + 5


def ctx_from(store, tools, now: float) -> FreezeCtx:
    """Context from state.db (trade.flow, own actions) and the tools folder (pause.hold, flags)."""
    flow = store.get("trade.flow") or {}
    hold = tools.flag("pause.hold")
    car = tools.flag("caravan")
    htxt = hold.text if hold.exists else None
    from .holds import siege_active      # night audit 10.10.2026: a stale siege.flag is no enemy
    enemy = siege_active(tools) or (htxt or "").startswith(("alarm", "gefahr"))

    def ts(f):
        return now - f.age_min * 60 if f.exists and f.age_min is not None else None
    return FreezeCtx(trade_state=flow.get("state"), trade_since=flow.get("since"), hold=htxt,
                     caravan_flag=car.exists, hold_ts=ts(hold), caravan_ts=ts(car), alert=tools.flag("alert").exists,
                     enemy=enemy, actions_last_hour=store.count_actions(RULE, "close_screens", now - 3600))


def _close(client, clock, cfg: dict, cls: list, allow_trade: bool) -> tuple[bool, str, list[str]]:
    """Up to max_leave inputs, leave_gap_s apart, until dwarfmode/Default. Returns (ok, final focus, commands)."""
    handled = [x for x in cls if x in set(cfg.get("classes") or [])] or cls
    tokens = [dict(CLASS_TOKENS)[x].strip("/") for x in handled]
    cmds: list[str] = []
    focus = ""
    box = "MessageBox" in cls
    for i in range(int(cfg["max_leave"])):
        cmd = leave_cmd("SELECT" if box and i == 0 else "LEAVESCREEN", tokens, allow_trade)
        cmds.append(cmd)
        res = client.run(cmd)
        lines = (res.stdout or "").strip().splitlines()
        focus = lines[-1].strip() if lines else ""
        if res.ok and (focus == DEFAULT_FOCUS or not focus_classes(focus)):
            return True, focus, cmds
        clock.sleep(float(cfg.get("leave_gap_s", 1.0)))
    return False, focus, cmds


def apply(d: Decision, guard: FreezeGuard, ctx: FreezeCtx, *, client, tools, store, clock,
          event) -> list[str]:
    """Execute a decision. `event(level, text)` writes the events.log line. Returns short result lines."""
    now = clock.now().epoch
    cfg = guard.cfg
    out: list[str] = []
    if d.kind == "none":
        return out
    if d.kind in ("protected", "unhandled"):
        txt = f"time stood still ({d.focus}): window kept, {d.reason}" if d.kind == "unhandled" else \
            f"window kept ({d.focus}): {d.reason}"
        event("info", txt)
        store.log_action(now, "waechter", RULE, d.kind, d.focus, "", False, True, d.reason)
        return [txt]
    if d.kind in ("give_up", "capped"):
        txt = f"time stands still ({d.focus}): {d.reason}, no further input - check the game by hand"
        event("CRITICAL", txt)
        store.warn(now, "waechter", f"{RULE}:{d.kind}", txt[:200], "crit")
        store.log_action(now, "waechter", RULE, d.kind, d.focus, "", False, False, d.reason)
        return [txt]
    if d.kind == "aftercare":
        guard.aftercare_done = ctx.trade_since
        store.set(f"{RULE}.aftercare_since", ctx.trade_since)
        done = []
        if (ctx.hold or "").startswith("karawane") and _leftover(ctx.hold_ts, ctx):
            tools.delete_flag("pause.hold")
            done.append("pause.hold")
        if ctx.caravan_flag and _leftover(ctx.caravan_ts, ctx):
            tools.delete_flag("caravan")
            done.append("caravan.flag")
        cmds: list[str] = []
        ok = True
        if d.close_box:
            ok, _, cmds = _close(client, clock, cfg, ["MessageBox"], False)
            done.append("MessageBox" if ok else "MessageBox (still open)")
        if not ctx.alert and not ctx.enemy and not tools.flag("pause.hold").exists:
            client.run("claude/advance run")
            cmds.append("claude/advance run")
            done.append("advance run")
        txt = "trade aftercare: " + ", ".join(done)
        event("info", txt)
        store.log_action(now, "waechter", RULE, "trade_aftercare", "trade.flow", "; ".join(cmds)[:500], False, ok, txt)
        return [txt]
    # close
    ok, focus, cmds = _close(client, clock, cfg, d.classes, "Trade" in (cfg.get("classes") or []))
    resumed = False
    if ok and not ctx.alert and not ctx.enemy and not tools.flag("pause.hold").exists:
        client.run("claude/advance run")
        cmds.append("claude/advance run")
        resumed = True
    txt = (f"time stood still ({d.focus}): screens closed" + (", game resumed" if resumed else "")) if ok else \
        f"time stood still ({d.focus}): closing failed (focus now {focus or '?'}), attempt {guard.fails}"
    event("info" if ok else "CRITICAL", txt)
    store.log_action(now, "waechter", RULE, "close_screens", d.focus, "; ".join(cmds)[:500], False, ok, txt[:300])
    return [txt]
