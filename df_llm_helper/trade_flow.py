"""F15 trade orchestration as a state machine (flow from the trade automation notes / Run 5).

Arrival -> pause -> quicksave -> resume + broker (prep + job) -> mark goods -> wait until the haulers have brought
them (game running) -> pause + open window -> selection (dry) -> review (trade planner or approval) -> selection live
-> confirm -> finish -> release broker -> resume. Without an immediate approval the window is closed and the game runs
on (WAIT) until the approval comes; then the window is opened again (RETEST 2026-10-02: MARK went on before the goods
were in the depot, and the open window held the game paused during the review).
Pure logic: step(observation, now) -> commands. Observation = JSON of 'claude/handel status'.
Hard rules: selection/confirmation only with exact focus 'dwarfmode/Trade/Default' and stability >= 2 s;
caravan leaves -> abort with rollback; every state has a timeout.
"""
from __future__ import annotations

from dataclasses import dataclass, field

__all__ = ["TradeObs", "TradeFlow", "STATES", "ALLOWED", "TERMINAL", "obs_from_status"]

STATES = ["IDLE", "PAUSE", "SAVE", "BROKER", "MARK", "OPEN", "SELECT_DRY", "REVIEW", "WAIT", "SELECT_LIVE", "CONFIRM",
          "FINISH", "RELEASE", "RESUME", "DONE", "ABORT", "FAILED"]
# commands that may be issued at all in a state (property test)
ALLOWED = {
    "PAUSE": {"claude/advance 0"},
    "SAVE": {"quicksave"},
    "BROKER": {"claude/handel prep --live", "claude/handel broker --live --force-job", "claude/advance run"},
    "MARK": {"claude/handel plan", "claude/handel mark --live"},
    "OPEN": {"claude/advance 0", "claude/handel open --live"},
    "SELECT_DRY": {"claude/handel select --dry"},
    "REVIEW": set(),
    "WAIT": {"claude/handel finish --live", "claude/advance run"},
    "SELECT_LIVE": {"claude/handel select --live"},
    "CONFIRM": {"claude/handel confirm --live", "claude/handel accept --live"},
    "FINISH": {"claude/handel finish --live"},
    "RELEASE": {"claude/handel release --live"},
    "RESUME": {"claude/advance run"},
    "ABORT": {"claude/handel abort --live", "claude/handel finish --live", "claude/handel release --live",
              "claude/advance run"},
}
TERMINAL = ("DONE", "ABORT", "FAILED")
FOCUS_TRADE = "dwarfmode/Trade/Default"
TIMEOUT_S = {"BROKER": 300, "OPEN": 60, "SELECT_DRY": 60, "REVIEW": 120, "SELECT_LIVE": 60, "CONFIRM": 60,
             "FINISH": 60}
MARK_MAX_S = 600        # haulers still busy after this: open anyway with what is in the depot (no abort)


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


def obs_from_status(j: dict, *, paused: bool = False, stable_s: float = 0.0, last_ok: bool = True,
                    plan_ok: bool | None = None) -> TradeObs:
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
                    haul_pending=haul)


@dataclass
class TradeFlow:
    state: str = "IDLE"
    since: float = 0.0
    retries: dict = field(default_factory=dict)
    log: list = field(default_factory=list)
    approved: bool = False                  # approval for the live purchase (orchestrator/player)
    abort_reason: str = ""

    def _go(self, state: str, now: float, why: str = "") -> None:
        self.log.append(f"{self.state} -> {state}" + (f" ({why})" if why else ""))
        self.state, self.since = state, now
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
        if s in TIMEOUT_S and now - self.since > TIMEOUT_S[s]:
            self.abort_reason = f"timeout in {s}"
            self._go("ABORT", now, self.abort_reason)
            return self._abort_cmds(o)

        if s == "IDLE":
            if o.caravan_state == "AtDepot":
                self._go("PAUSE", now, "caravan at depot")
                return ["claude/advance 0"]
            return []
        if s == "PAUSE":
            if o.paused:
                self._go("SAVE", now)
                return ["quicksave"]
            return ["claude/advance 0"] if self._retry("pause", 3) else self._fail(now, "pause has no effect")
        if s == "SAVE":
            if not o.last_ok:
                return self._fail(now, "quicksave failed - no trading without a save")
            self._go("BROKER", now)
            # the game runs again: the broker walks to the depot and the haulers bring the goods (paused nobody moves)
            return ["claude/handel prep --live", "claude/handel broker --live --force-job", "claude/advance run"]
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
            return ["claude/advance 0", "claude/handel open --live"]
        if s == "OPEN":
            if o.trade_open and o.focus == FOCUS_TRADE and o.stable_s >= 2:
                self._go("SELECT_DRY", now)
                return ["claude/handel select --dry"]
            if o.trade_open:
                return []                                                 # wait until stable
            return ["claude/handel open --live"] if self._retry("open", 2) else self._abort(now, o,
                                                                                            "window not open")
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
            return ["claude/handel finish --live", "claude/advance run"]
        if s == "WAIT":
            if self.approved:
                self._go("OPEN", now, "approved")
                return ["claude/advance 0", "claude/handel open --live"]
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
            return ["claude/advance run"]
        if s == "RESUME":
            self._go("DONE", now)
            return []
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
        cmds += ["claude/handel release --live", "claude/advance run"]
        return cmds

    def _fail(self, now: float, why: str) -> list[str]:
        self.abort_reason = why
        self._go("FAILED", now, why)
        return []
