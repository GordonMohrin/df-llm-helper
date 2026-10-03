"""F15 trade orchestration as a state machine (flow from the trade automation notes / Run 5).

Arrival -> pause -> quicksave -> resume + broker (prep + job) -> mark goods -> wait until the haulers have brought
them (game running) -> pause + open window -> selection (dry) -> review (trade planner or approval) -> selection live
-> confirm -> finish -> release broker -> resume. Without an immediate approval the window is closed and the game runs
on (WAIT) until the approval comes; then the window is opened again (RETEST 2026-10-02: MARK went on before the goods
were in the depot, and the open window held the game paused during the review).
Pure logic: step(observation, now) -> commands. Observation = JSON of 'claude/handel status'.
Hard rules: selection/confirmation only with exact focus 'dwarfmode/Trade/Default' and stability >= 2 s;
caravan leaves -> abort with rollback; every state has a timeout.
pause.hold (BUG-223): a pause guard lifts every pause without tools/pause.hold and pauses a running game again while it
exists, so the automaton owns a hold with reason 'trade': written in PAUSE (kept through SAVE), deleted in BROKER
before 'advance run' (broker and haulers must walk), written again for OPEN/REVIEW, deleted in WAIT/RELEASE/ABORT/
FAILED. The local commands HOLD_CMD/RELEASE_CMD are executed by the caller (holds.run_helper), never sent to the game;
RELEASE_CMD never deletes an alarm/gefahr hold.
OPEN during danger (BUG-225): with an alarm/siege (obs.danger) or a foreign window on top (Squads, a popup) the window
cannot be opened; OPEN then waits ("blocked: ...", own timeout BLOCKED_MAX_S) instead of burning its retries, and an
abort because the window did not open may re-enter OPEN while the caravan is still at the depot (marked goods stay).
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .holds import HOLD_CMD, RELEASE_CMD

__all__ = ["TradeObs", "TradeFlow", "STATES", "ALLOWED", "TERMINAL", "obs_from_status", "HOLD_CMD", "RELEASE_CMD",
           "blocker"]

STATES = ["IDLE", "PAUSE", "SAVE", "BROKER", "MARK", "OPEN", "SELECT_DRY", "REVIEW", "WAIT", "SELECT_LIVE", "CONFIRM",
          "FINISH", "RELEASE", "RESUME", "DONE", "ABORT", "FAILED"]
# commands that may be issued at all in a state (property test)
ALLOWED = {
    "PAUSE": {HOLD_CMD, "claude/advance 0"},
    "SAVE": {"quicksave"},
    "BROKER": {"claude/handel prep --live", "claude/handel broker --live --force-job", RELEASE_CMD,
               "claude/advance run"},
    "MARK": {"claude/handel plan", "claude/handel mark --live"},
    "OPEN": {HOLD_CMD, "claude/advance 0", "claude/handel open --live"},
    "SELECT_DRY": {"claude/handel select --dry"},
    "REVIEW": set(),
    "WAIT": {"claude/handel finish --live", RELEASE_CMD, "claude/advance run"},
    "SELECT_LIVE": {"claude/handel select --live"},
    "CONFIRM": {"claude/handel confirm --live", "claude/handel accept --live"},
    "FINISH": {"claude/handel finish --live"},
    "RELEASE": {"claude/handel release --live"},
    "RESUME": {RELEASE_CMD, "claude/advance run"},
    "ABORT": {"claude/handel abort --live", "claude/handel finish --live", "claude/handel release --live",
              RELEASE_CMD, "claude/advance run"},
    "FAILED": {RELEASE_CMD},
}
TERMINAL = ("DONE", "ABORT", "FAILED")
FOCUS_TRADE = "dwarfmode/Trade/Default"
TIMEOUT_S = {"BROKER": 300, "OPEN": 60, "SELECT_DRY": 60, "REVIEW": 120, "SELECT_LIVE": 60, "CONFIRM": 60,
             "FINISH": 60}
MARK_MAX_S = 600        # haulers still busy after this: open anyway with what is in the depot (no abort)
OPEN_RETRIES = 5        # BUG-225: 'handel open' attempts before 'window not open' ...
OPEN_RETRY_GAP_S = 8    # ... at least this far apart (two blind retries within seconds were too few)
BLOCKED_MAX_S = 600     # OPEN blocked by danger / a foreign window this long -> abort (caravan time runs out)
REENTER_MAX = 2         # re-entries ABORT -> OPEN per caravan after 'window not open' / 'blocked'
REENTER_REASONS = ("window not open", "blocked")
# focus prefixes on which 'claude/handel open --live' can work (plain map, the depot sheet, the trade window)
OPEN_FOCUS = ("dwarfmode/Default", "dwarfmode/ViewSheets", "dwarfmode/Trade")


@dataclass
class TradeObs:
    caravan_state: str | None = None       # Approaching | AtDepot | Leaving | None (none)
    broker_in_depot: bool = False
    broker_job: str | None = None
    focus: str = ""
    trade_open: bool = False
    stable_s: float = 0.0
    paused: bool = False
    last_ok: bool = True                    # last command successful?
    plan_ok: bool | None = None             # trade planner/dry run plausible?
    haul_pending: int | None = None         # BringItemToDepot jobs of the depot (None = unknown)
    danger: str = ""                        # BUG-225: danger state ('' = none; holds.danger_reason)


def blocker(o: TradeObs) -> str:
    """Why the trade window cannot be opened right now ('' = nothing blocks): danger or a foreign window on top."""
    if o.danger:
        return f"alarm active ({o.danger})"
    f = o.focus or ""
    if "/Squads" in f:
        return f"squads window open (focus {f})"
    if f and not f.startswith(OPEN_FOCUS):
        return f"focus={f}"
    return ""


def obs_from_status(j: dict, *, paused: bool = False, stable_s: float = 0.0, last_ok: bool = True,
                    plan_ok: bool | None = None, danger: str = "") -> TradeObs:
    car = (j.get("caravans") or [{}])[0] if j.get("caravans") else {}
    broker = j.get("broker") or {}
    ui = j.get("trade_ui") or {}
    focus = (j.get("focus") or [""])[0]
    deps = [d for d in j.get("depots") or [] if isinstance(d, dict)]
    jobs = deps[0].get("jobs") if deps else None
    haul = sum(1 for x in jobs if x == "BringItemToDepot") if isinstance(jobs, list) else None
    return TradeObs(caravan_state=car.get("state"), broker_in_depot=bool(broker.get("in_depot")),
                    broker_job=broker.get("job"), focus=focus, trade_open=bool(ui.get("open")),
                    stable_s=stable_s, paused=paused, last_ok=last_ok, plan_ok=plan_ok,
                    haul_pending=haul, danger=danger)


@dataclass
class TradeFlow:
    state: str = "IDLE"
    since: float = 0.0
    retries: dict = field(default_factory=dict)
    log: list = field(default_factory=list)
    approved: bool = False                  # approval for the live purchase (orchestrator/player)
    abort_reason: str = ""
    blocked_since: float | None = None      # OPEN blocked since (BUG-225)
    last_try: float | None = None           # last 'handel open' attempt
    last_answer: str = ""                   # last answer of 'handel open --live' (set by the caller, for the abort text)
    reentries: int = 0
    note: str = ""                          # current sub state for 'trade status' (e.g. "blocked: alarm active")

    def _go(self, state: str, now: float, why: str = "") -> None:
        self.log.append(f"{self.state} -> {state}" + (f" ({why})" if why else ""))
        self.state, self.since = state, now
        if state != "OPEN":
            self.blocked_since, self.note = None, ""
        if state in TERMINAL:
            self.approved = False          # an approval is valid for ONE trade only (BUG-202: stale approval)

    def _retry(self, key: str, limit: int) -> bool:
        self.retries[key] = self.retries.get(key, 0) + 1
        return self.retries[key] <= limit

    def approve(self) -> None:
        self.approved = True

    def renew_if_gone(self, o: TradeObs) -> bool:
        """Terminal state and no caravan on the map any more -> fresh automaton for the next caravan (BUG-202)."""
        if self.state in TERMINAL and o.caravan_state is None:
            self.__init__()
            return True
        return False

    def step(self, o: TradeObs, now: float) -> list[str]:
        self.renew_if_gone(o)
        s = self.state
        # global abort conditions
        if s not in ("IDLE", "DONE", "ABORT", "FAILED", "RESUME", "RELEASE") and o.caravan_state in (None, "Leaving"):
            self.abort_reason = "caravan is leaving"
            self._go("ABORT", now, self.abort_reason)
            return self._abort_cmds(o)
        if s == "ABORT" and self.can_reenter(o):
            self.reentries += 1
            self.retries.pop("open", None)
            self.blocked_since, self.last_try, self.note = None, now, ""
            self._go("OPEN", now, f"re-enter {self.reentries}/{REENTER_MAX}: caravan still at the depot "
                                  f"(after '{self.abort_reason}')")
            self.abort_reason = ""
            return [HOLD_CMD, "claude/advance 0", "claude/handel open --live"]
        if s == "OPEN" and not o.trade_open and blocker(o):
            return self._open_blocked(o, now)
        if s in TIMEOUT_S and now - self.since > TIMEOUT_S[s]:
            self.abort_reason = f"timeout in {s}"
            self._go("ABORT", now, self.abort_reason)
            return self._abort_cmds(o)

        if s == "IDLE":
            if o.caravan_state == "AtDepot":
                self._go("PAUSE", now, "caravan at depot")
                return [HOLD_CMD, "claude/advance 0"]
            return []
        if s == "PAUSE":
            if o.paused:
                self._go("SAVE", now)
                return ["quicksave"]
            if self._retry("pause", 3):
                return [HOLD_CMD, "claude/advance 0"]
            return self._fail(now, "pause has no effect (pause.hold 'trade' written and 'claude/advance 0' sent 4 "
                                   "times; the game was still running - check the pause guard / claude/tempo)")
        if s == "SAVE":
            if not o.last_ok:
                return self._fail(now, "quicksave failed - no trading without a save")
            self._go("BROKER", now)
            # the game runs again: the broker walks to the depot and the haulers bring the goods (paused nobody moves)
            return ["claude/handel prep --live", "claude/handel broker --live --force-job", RELEASE_CMD,
                    "claude/advance run"]
        if s == "BROKER":
            if o.broker_in_depot:
                self._go("MARK", now)
                return ["claude/handel plan", "claude/handel mark --live"]
            if o.broker_job not in ("TradeAtDepot", "BringItemToDepot") and self._retry("broker", 2):
                return ["claude/handel broker --live --force-job"]      # broker lost the job
            return []
        if s == "MARK":
            waited = now - self.since
            # markForTrade creates the BringItemToDepot jobs at once, so the next status already lists them
            if o.haul_pending is None or o.haul_pending > 0:
                if waited <= MARK_MAX_S:
                    return []                                             # haulers still bringing goods
                why = (f"{o.haul_pending} haul jobs still open" if o.haul_pending else "haul state unknown") + \
                    f" after {MARK_MAX_S} s - opening with the goods in the depot"
            else:
                why = "goods in the depot"
            self._go("OPEN", now, why)
            self.last_try = now
            return [HOLD_CMD, "claude/advance 0", "claude/handel open --live"]
        if s == "OPEN":
            if o.trade_open and o.focus == FOCUS_TRADE and o.stable_s >= 2:
                self.note = ""
                self._go("SELECT_DRY", now)
                return ["claude/handel select --dry"]
            if o.trade_open:
                return []                                                 # wait until stable
            if self.blocked_since is not None:                            # the blocker is gone: start afresh
                self.log.append(f"OPEN unblocked after {int(now - self.blocked_since)} s")
                self.blocked_since, self.note, self.since, self.last_try = None, "", now, now
                self.retries.pop("open", None)
                return [HOLD_CMD, "claude/advance 0", "claude/handel open --live"]
            if self.last_try is not None and now - self.last_try < OPEN_RETRY_GAP_S:
                return []                                                 # give the window time to appear
            if self._retry("open", OPEN_RETRIES):
                self.last_try = now
                return ["claude/handel open --live"]
            ans = f" (last answer: {self.last_answer[:120]})" if self.last_answer else ""
            return self._abort(now, o, "window not open" + ans)
        if s == "SELECT_DRY":
            if not self._ui_ok(o):
                return self._abort(now, o, "focus lost")
            if o.plan_ok is False:
                return self._abort(now, o, "dry run implausible (ratio/weight)")
            self._go("REVIEW", now)
            return []
        if s == "REVIEW":
            if not self._ui_ok(o):
                return self._abort(now, o, "focus lost")
            if self.approved:
                self._go("SELECT_LIVE", now)
                return ["claude/handel select --live"]
            # no approval yet: close the window (it pauses the game) and keep playing until the approval comes
            self._go("WAIT", now, "waiting for approval, window closed, game runs")
            return ["claude/handel finish --live", RELEASE_CMD, "claude/advance run"]
        if s == "WAIT":
            if self.approved:
                self._go("OPEN", now, "approved")
                self.retries.pop("open", None)
                self.last_try = now
                return [HOLD_CMD, "claude/advance 0", "claude/handel open --live"]
            return []
        if s == "SELECT_LIVE":
            if not self._ui_ok(o) or not o.last_ok:
                return self._abort(now, o, "selection failed")
            self._go("CONFIRM", now)
            return ["claude/handel confirm --live", "claude/handel accept --live"]
        if s == "CONFIRM":
            if not o.last_ok:
                return self._abort(now, o, "confirmation failed")
            self._go("FINISH", now)
            return ["claude/handel finish --live"]
        if s == "FINISH":
            self._go("RELEASE", now)
            return ["claude/handel release --live"]
        if s == "RELEASE":
            self._go("RESUME", now)
            return [RELEASE_CMD, "claude/advance run"]
        if s == "RESUME":
            self._go("DONE", now)
            return []
        return []

    def can_reenter(self, o: TradeObs) -> bool:
        """ABORT because the window did not open (or OPEN stayed blocked) and the caravan still waits at the depot:
        go back to OPEN (BUG-225) - at most REENTER_MAX times, never while something still blocks."""
        return (self.state == "ABORT" and self.abort_reason.startswith(REENTER_REASONS)
                and self.reentries < REENTER_MAX and o.caravan_state == "AtDepot" and not blocker(o))

    def _open_blocked(self, o: TradeObs, now: float) -> list[str]:
        why = blocker(o)
        if self.blocked_since is None:
            self.blocked_since = now
            self.log.append(f"OPEN blocked: {why}")
        self.note = f"blocked: {why}"
        self.since = now                       # the OPEN timeout starts again once nothing blocks
        if now - self.blocked_since > BLOCKED_MAX_S:
            return self._abort(now, o, f"blocked for {int(now - self.blocked_since)} s: {why}")
        return []

    def _ui_ok(self, o: TradeObs) -> bool:
        return o.trade_open and o.focus == FOCUS_TRADE and o.stable_s >= 2

    def _abort(self, now: float, o: TradeObs, why: str) -> list[str]:
        self.abort_reason = why
        self._go("ABORT", now, why)
        return self._abort_cmds(o)

    def _abort_cmds(self, o: TradeObs) -> list[str]:
        cmds = []
        if o.trade_open:
            cmds += ["claude/handel abort --live", "claude/handel finish --live"]
        cmds += ["claude/handel release --live", RELEASE_CMD, "claude/advance run"]
        return cmds

    def _fail(self, now: float, why: str) -> list[str]:
        self.abort_reason = why
        self._go("FAILED", now, why)
        return [RELEASE_CMD]
