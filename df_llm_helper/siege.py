"""Spec 01: siege autopilot (`python -m df_llm_helper siege`).

DETECT -> ASSESS -> PREPARE -> ENGAGE (loop) -> CLEANUP | ABORT, without LLM moves.
Pure logic in SiegeFlow.step(observation) -> commands; SiegeRunner executes them (DFClient), waits for the pause after
`claude/advance N` and guarantees that the squad orders are cleared (try/finally).
Data source: `claude/pilot_siege status` (lua/pilot_siege.lua, not tested live).
"""
from __future__ import annotations

from dataclasses import dataclass, field

__all__ = ["SiegeObs", "SiegeFlow", "SiegeRunner", "obs_from_status", "exit_code", "DEFAULTS"]

DEFAULTS = {"alert_radius": 40, "kill_radius": 45, "flee_dist": 70, "step_far": 300, "step_mid": 120, "step_near": 60,
            "min_blood_pct": 60, "max_losses": 2, "squad_alias": "Wache", "max_steps": 60, "rally": None,
            "poll_s": 3.0, "max_wait_s": 120.0, "starve_thirst": 40000, "starve_hunger": 60000}
STATUS_CMD = "claude/pilot_siege status"


@dataclass
class SiegeObs:
    invaders: list = field(default_factory=list)    # dicts: id, race, prof, x, y, z, dist
    berserk: list = field(default_factory=list)     # dicts: id, ...  (citizens, never a target)
    squad: dict | None = None                       # the guard squad: id, name, orders, members[...]
    civ_alert: int = 0
    ok: bool = True


def obs_from_status(j: dict | None, alias: str) -> SiegeObs:
    if not isinstance(j, dict):
        return SiegeObs(ok=False)
    squads = [s for s in j.get("squads") or [] if isinstance(s, dict)]
    sq = next((s for s in squads if str(s.get("name", "")).lower() == alias.lower()), None)
    if sq is None:  # alias as part of the name (translations/suffixes)
        sq = next((s for s in squads if alias.lower() in str(s.get("name", "")).lower()), None)
    # BUG-426: caged/chained units are never targets (pilot_siege filters them; this guards older Lua copies that report the flags)
    return SiegeObs(invaders=[i for i in j.get("invaders") or [] if isinstance(i, dict)
                              and not (i.get("caged") or i.get("chained") or i.get("captive"))],
                    berserk=[b for b in j.get("berserk") or [] if isinstance(b, dict)],
                    squad=sq, civ_alert=int(j.get("civ_alert") or 0))


@dataclass
class SiegeFlow:
    cfg: dict = field(default_factory=lambda: dict(DEFAULTS))
    state: str = "IDLE"
    steps: int = 0
    start_members: list = field(default_factory=list)
    max_invaders: int = 0
    types: dict = field(default_factory=dict)
    retreat_sent: bool = False
    reported_berserk: set = field(default_factory=set)
    report: list = field(default_factory=list)
    notify: list = field(default_factory=list)     # messages the orchestrator should push
    orders_set: bool = False
    prev_mind: float | None = None

    def _c(self, k):
        return self.cfg.get(k, DEFAULTS[k])

    def _advance_for(self, d: float) -> int:
        if d > 60:
            return int(self._c("step_far"))
        if d >= 30:
            return int(self._c("step_mid"))
        return int(self._c("step_near"))

    def _cleanup(self, sid) -> list[str]:
        cmds = []
        if sid is not None:
            cmds.append(f"claude/pilot_siege clear {sid}")
        cmds += ["claude/alert off", "HELPER delete_flag alert", "HELPER delete_flag siege",
                 "HELPER delete_flag pause.hold", "claude/advance run"]
        self.orders_set = False
        return cmds

    def _note(self, text: str) -> None:
        if text not in self.notify:
            self.notify.append(text)

    def step(self, o: SiegeObs) -> list[str]:
        if self.state in ("DONE", "ABORT"):
            return []
        sid = o.squad.get("id") if o.squad else None
        members = (o.squad or {}).get("members") or []
        alive = [m for m in members if m.get("alive", True)]
        mind = min((i.get("dist", 999) for i in o.invaders), default=None)
        fleeing = (mind is not None and mind >= self._c("flee_dist") and self.prev_mind is not None
                   and mind > self.prev_mind)
        active = [] if fleeing else list(o.invaders)
        self.prev_mind = mind
        cmds: list[str] = []
        for b in o.berserk:
            if b.get("id") not in self.reported_berserk:
                self.reported_berserk.add(b.get("id"))
                self._note(f"Citizen {b.get('id')} berserk: NO kill order (citizen); keep civilians away")
        if self.state == "IDLE":
            if not active:
                return []
            self.state = "ASSESS"
            self.start_members = [m.get("id") for m in alive]
            cmds.append("claude/advance 0")
        if self.state == "ASSESS":
            self.max_invaders = max(self.max_invaders, len(o.invaders))
            for i in o.invaders:
                key = f"{i.get('race')}/{i.get('prof')}"
                self.types[key] = self.types.get(key, 0) + 1
            if sid is None:
                self.notify.append(f"Squad '{self._c('squad_alias')}' not found: run the siege by hand")
                self.state = "ABORT"
                return cmds
            self.state = "PREPARE"
        if self.state == "PREPARE":
            if active and min(i.get("dist", 999) for i in active) <= self._c("alert_radius") and not o.civ_alert:
                cmds.append("claude/alert on")
            self.state = "ENGAGE"
            if active and min(i.get("dist", 999) for i in active) > self._c("alert_radius"):
                self.report.append("Plug proposal: close the entrances before arrival (build), no automatic building")
        if self.state == "ENGAGE":
            self.steps += 1
            if not active:                                   # all dead or fleeing
                self.state = "DONE"
                cmds += self._cleanup(sid)
                return cmds
            dead = [mid for mid in self.start_members if mid not in [m.get("id") for m in alive]]
            if len(dead) > self._c("max_losses"):
                self.state = "ABORT"
                cmds.append("claude/advance 0")
                if sid is not None:
                    cmds.append(f"claude/pilot_siege clear {sid}")
                self.notify.append(f"Siege: {len(dead)} soldiers lost (> {self._c('max_losses')}) - pause, "
                                   f"orchestrator takes over")
                return cmds
            if self.steps > self._c("max_steps"):
                self.state = "ABORT"
                cmds += [f"claude/pilot_siege clear {sid}", "claude/advance 0"]
                self.notify.append(f"Siege: loop guard after {self._c('max_steps')} steps - pause")
                return cmds
            if (not o.civ_alert and "claude/alert on" not in cmds
                    and min(i.get("dist", 999) for i in active) <= self._c("alert_radius")):
                cmds.append("claude/alert on")      # not twice in the same step (PREPARE just sent it)
            weak = [m for m in alive if m.get("blood_pct", 100) < self._c("min_blood_pct")]
            if weak:
                self._note("Retreat: " + ", ".join(f"{m.get('id')} blood {m.get('blood_pct')}%" for m in weak)
                           + ("" if self._c("rally") else " (no rally point siege.rally configured)"))
                rally = self._c("rally")
                if rally and not self.retreat_sent:
                    cmds.append(f"claude/pilot_siege move {sid} {rally[0]} {rally[1]} {rally[2]}")
                    self.retreat_sent = True
                    self.orders_set = True
                    cmds.append(f"claude/advance {self._advance_for(min(i.get('dist', 999) for i in active))}")
                    return cmds
            # BUG-426: soldiers on a kill order never eat/drink -> withdraw the order while one of them is starving
            starving = [m for m in alive if (m.get("thirst") or 0) > self._c("starve_thirst")
                        or (m.get("hunger") or 0) > self._c("starve_hunger")]
            if starving:
                self._note("Squad hungry/thirsty: " + ", ".join(str(m.get("id")) for m in starving)
                           + " - kill order withdrawn so they can eat and drink")
                if self.orders_set or (o.squad or {}).get("orders"):
                    cmds.append(f"claude/pilot_siege clear {sid}")
                    self.orders_set = False
                cmds.append(f"claude/advance {self._advance_for(min(i.get('dist', 999) for i in active))}")
                return cmds
            targets = [i for i in active if i.get("dist", 999) <= self._c("kill_radius")]
            if targets and not self.retreat_sent:
                ids = ",".join(str(i["id"]) for i in sorted(targets, key=lambda i: (i.get("dist", 0), i["id"])))
                cmds.append(f"claude/pilot_siege kill {sid} {ids}")
                self.orders_set = True
            cmds.append(f"claude/advance {self._advance_for(min(i.get('dist', 999) for i in active))}")
        return cmds

    def summary(self, losses: int | None = None) -> list[str]:
        if self.state == "ERROR":                   # tool error, not a siege (BUG-219)
            return ["Siege autopilot ERROR (no siege action taken)"] + self.report[:3]
        head = {"DONE": "Siege finished", "ABORT": "Siege ABORTED"}.get(self.state, f"Siege {self.state}")
        lines = [f"{head}: {self.max_invaders} attackers, {self.steps} steps"
                 + (f", {losses} soldiers lost" if losses is not None else "")]
        if self.types:
            lines.append("Types: " + ", ".join(f"{k} x{v}" for k, v in sorted(self.types.items(), key=lambda x: -x[1])[:5]))
        lines += self.report[:3] + self.notify[:6]
        return lines[:12]


class SiegeRunner:
    def __init__(self, client, tools, store, clock, cfg: dict):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def observe(self) -> SiegeObs:
        r = self.client.run(STATUS_CMD)
        return obs_from_status(r.json if r.ok else None, self.cfg["squad_alias"])

    def _wait_paused(self) -> None:
        waited = 0.0
        while waited < self.cfg["max_wait_s"]:
            self.clock.sleep(self.cfg["poll_s"])
            waited += self.cfg["poll_s"]
            r = self.client.run("claude/advance clock")
            if isinstance(r.json, dict) and r.json.get("paused"):
                return

    def _exec(self, cmds: list[str], dry: bool) -> list[str]:
        done = []
        now = self.clock.now().epoch
        for c in cmds:
            if dry:
                done.append("[dry] " + c)
                continue
            if c.startswith("HELPER delete_flag "):
                self.tools.delete_flag(c.split()[-1])
                ok = True
            else:
                ok = self.client.run(c).ok
            self.store.log_action(now, "siege", "siege", c.split(" ")[0], "siege", c, False, ok, "")
            done.append(("ok " if ok else "ERROR ") + c)
            if c.startswith("claude/advance ") and c.split()[-1].isdigit() and c.split()[-1] != "0":
                self._wait_paused()
        return done

    def run(self, *, loop: bool = True, dry: bool = False) -> tuple[SiegeFlow, list[str]]:
        flow = SiegeFlow(cfg=self.cfg)
        log: list[str] = []
        sid = None
        try:
            while True:
                o = self.observe()
                if not o.ok:
                    # BUG-219: an unreadable status is an error of the tool, not an aborted siege: no crit warning,
                    # no notify.flag (push to the player); if a siege really runs, the alarm flags of the guard report it
                    flow.report.append(f"{STATUS_CMD} not readable: is DF running / is lua/pilot_siege.lua installed?"
                                       + (" (steps so far: " + str(flow.steps) + ")" if flow.steps else ""))
                    if flow.steps:              # it failed in the middle of a siege: the orchestrator must take over
                        flow.notify.append("Siege: pilot_siege status lost during the siege - orchestrator takes over")
                        flow.state = "ABORT"
                    else:
                        flow.state = "ERROR"
                    break
                sid = (o.squad or {}).get("id", sid)
                cmds = flow.step(o)
                log += self._exec(cmds, dry)
                if flow.state in ("DONE", "ABORT") or (flow.state == "IDLE") or not loop or dry:
                    break
        finally:
            if flow.orders_set and flow.state != "DONE" and sid is not None and not dry:
                self.client.run(f"claude/pilot_siege clear {sid}")     # never leave orphaned orders
                flow.orders_set = False
            for n in flow.notify if not dry else []:          # a dry run writes nothing (BUG-203)
                self.store.warn(self.clock.now().epoch, "siege", f"siege:{n[:30]}", n, "crit")
            if flow.notify and not dry and flow.state == "ABORT":
                self.tools.write_flag("notify", "\n".join(flow.notify[:6]))
        return flow, log


def exit_code(flow: SiegeFlow) -> int:
    """Same code for a real and a dry run (BUG-219): 0 = nothing to do / running / done, 1 = aborted, 2 = tool error."""
    return {"ABORT": 1, "ERROR": 2}.get(flow.state, 0)
