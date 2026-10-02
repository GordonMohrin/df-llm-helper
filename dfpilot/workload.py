"""Spec 06: workload control (`dfpilot workload`).

One snapshot -> decision tree -> ordered list `cause -> measure (command)`.
  A) many open jobs + high idle: jobs not executable (picks, fuel, suspended, cancellation patterns)
  B) hardly any work: dig queue < min_dig_queue, services off, stockpiles full, filler orders
Only maintenance is automatic (start a service, next dig stage from own rasters); everything else = proposal.
Each measure: at most once per repeat_block_s (10 min), effect after measure_after_s (idle before/after)
-> warning 'ok done'/'no effect' in the next digest + kv 'workload.effects' (empirical values).
"""
from __future__ import annotations

from dataclasses import dataclass, field

__all__ = ["DEFAULTS", "WorkObs", "Measure", "diagnose", "WorkloadPilot", "obs_from"]

DEFAULTS = {"idle_warn": 40, "idle_crit": 60, "min_dig_queue": 100, "measure_after_s": 300, "repeat_block_s": 600,
            "open_high": 50, "effect_min_pct": 5, "max_auto_per_run": 2}


@dataclass
class WorkObs:
    idle_pct: float | None = None
    idle: int | None = None
    adults: int | None = None
    jobs_open: int | None = None
    dig_queue: int | None = None
    suspended: int | None = None
    picks_total: int | None = None
    picks_free: int | None = None
    work_weapons: int | None = None
    coke: int | None = None
    coal: int | None = None
    wood: int | None = None
    full_stockpiles: int = 0
    services: dict = field(default_factory=dict)       # name -> running (bool) or missing
    cancels: dict = field(default_factory=dict)        # reason text -> count
    raster_next: str | None = None                     # next stage from stages.lua (None = none left)
    raster_known: bool = False


@dataclass
class Measure:
    key: str
    cause: str
    action: str
    cmd: str | None = None        # only for auto
    auto: bool = False
    effect: str = ""
    prio: int = 50

    def line(self) -> str:
        how = f"`{self.cmd}`" if self.cmd else "proposal"
        return f"{self.cause} -> {self.action} ({how}{', ' + self.effect if self.effect else ''})"


def _svc(obs: WorkObs, name: str) -> bool | None:
    return obs.services.get(name)


def _cancel(obs: WorkObs, needle: str) -> int:
    return sum(n for k, n in obs.cancels.items() if needle.lower() in k.lower())


def diagnose(obs: WorkObs, cfg: dict | None = None) -> list[Measure]:
    c = {**DEFAULTS, **(cfg or {})}
    if obs.idle_pct is None or obs.idle_pct < c["idle_warn"]:
        return []
    out: list[Measure] = []
    idle = obs.idle or 0
    many_open = (obs.jobs_open or 0) >= max(c["open_high"], idle)
    # ---- fuel completely gone -> spec 07
    if obs.coke == 0 and obs.wood == 0:
        out.append(Measure("brennstoff", "Coke 0 and wood 0", "Bottleneck watcher (spec 07, `dfpilot bottleneck`): "
                           "fuel chain/trade wood+coke", prio=15, effect="smelters/forges run again"))
    # ---- A) jobs present, but not executable
    if many_open:
        dig = obs.dig_queue or 0
        ww = obs.work_weapons if obs.work_weapons is not None else obs.picks_total
        if dig > 0 and ww is not None and ww < min(dig, idle):
            free = obs.picks_free or 0
            out.append(Measure("picken", f"{obs.jobs_open} jobs open, {idle} idle, only {ww} pickaxes in use",
                               "Picks/fuel: " + (f"`claude/pickfix --apply` (distribute {free} free picks)"
                                                    if free else "buy/forge pickaxes (trade, forge)"),
                               prio=10, effect=f"up to {min(idle, dig)} more diggers"))
        if _cancel(obs, "refined coal") >= 5:
            if obs.coal == 0:                         # live 01.10.: permanent kohle job = 9 s freeze per run -> never automatic
                out.append(Measure("kohle", f"'Needs refined coal' {_cancel(obs, 'refined coal')}x, coal 0",
                                   "Dig coal: run `claude/kohle run 10` once by hand (permanent job stays off, 9 s freeze)",
                                   prio=12, effect="coke for smelters"))
            else:
                out.append(Measure("koks", f"'Needs refined coal' {_cancel(obs, 'refined coal')}x",
                                   "Picks/fuel: trade for coke/wood, charcoal starter (kb koks_brennstoff)",
                                   prio=12))
        if (obs.suspended or 0) >= 10:
            out.append(Measure("suspendiert", f"{obs.suspended} jobs blocked", "check suspendmanager, "
                               "clarify building material/access", prio=30))
        if _cancel(obs, "Inappropriate dig square") >= 10:
            out.append(Measure("grabfehler", f"'Inappropriate dig square' {_cancel(obs, 'Inappropriate dig square')}x",
                               "remove invalid dig designations (check raster)", prio=25))
        if _cancel(obs, "Could not find path") >= 10:
            out.append(Measure("pfad", f"'Could not find path' {_cancel(obs, 'Could not find path')}x",
                               "check access/stairs (build)", prio=28))
    # ---- B) no work
    if obs.dig_queue is not None and obs.dig_queue < c["min_dig_queue"]:
        if _svc(obs, "raster") is False:
            out.append(Measure("grab-etappe", f"Dig queue {obs.dig_queue} < {c['min_dig_queue']}",
                               "new dig stage: start raster refill", "claude/raster start", auto=True,
                               prio=5 if not many_open else 20, effect="miners busy"))
        elif obs.raster_known and obs.raster_next is None:
            out.append(Measure("grab-etappe", f"Dig queue {obs.dig_queue} < {c['min_dig_queue']}, no stage left",
                               "design a new dig stage (exploration: extend stages.lua)",
                               prio=5 if not many_open else 20, effect="miners busy"))
        else:
            out.append(Measure("grab-etappe", f"Dig queue {obs.dig_queue} < {c['min_dig_queue']}",
                               "set a new dig stage" + (f" ({obs.raster_next})" if obs.raster_next else ""),
                               "claude/raster next", auto=True,
                               prio=5 if not many_open else 20, effect="miners busy"))
    if not many_open:
        for svc, cmd in (("orders", "claude/orders start"), ("arbeit", "claude/arbeit start")):
            if _svc(obs, svc) is False:
                out.append(Measure(f"dienst-{svc}", f"Service {svc} is not running", f"restart {svc}", cmd,
                                   auto=True, prio=8, effect="workshops/standing orders active again"))
        if obs.full_stockpiles:
            out.append(Measure("lager", f"{obs.full_stockpiles} stockpiles full", "expand stockpiles (build)", prio=35))
        out.append(Measure("fuellarbeit", "hardly any open jobs", "filler orders: smoothing/engraving, communal buildings,"
                           " more workshops (economy/build)", prio=60))
    out.sort(key=lambda m: (m.prio, m.key))
    seen, uniq = set(), []
    for m in out:
        if m.key not in seen:
            seen.add(m.key)
            uniq.append(m)
    return uniq


def obs_from(snap, *, auslastung: dict | None = None, pickfix: dict | None = None, material: dict | None = None,
             cancels: list | None = None, raster: dict | None = None, kohle: dict | None = None) -> WorkObs:
    o = WorkObs(idle_pct=snap.idle_pct, idle=snap.idle, adults=snap.adults, jobs_open=snap.jobs.open,
                dig_queue=snap.jobs.dig, suspended=snap.jobs.suspended, wood=snap.stocks.wood,
                full_stockpiles=len(snap.full_stockpiles or []))
    for name, d in (snap.services or {}).items():
        if isinstance(d, dict) and "running" in d:
            o.services[name] = bool(d["running"])
    m = (auslastung or {}).get("measure") if isinstance(auslastung, dict) else None
    if isinstance(m, dict):
        if o.dig_queue is None and isinstance(m.get("grabjobs"), int):
            o.dig_queue = m["grabjobs"]
        if o.idle is None and isinstance(m.get("idle"), int):
            o.idle = m["idle"]
        if o.idle_pct is None and isinstance(m.get("pct"), (int, float)):
            o.idle_pct = 100 - float(m["pct"])
    if isinstance(pickfix, dict):
        picks = [p for p in pickfix.get("picks") or [] if isinstance(p, dict)]
        if picks or "picks" in pickfix:
            o.picks_total = len(picks)
            o.picks_free = sum(1 for p in picks if p.get("holder") is None)
        if isinstance(pickfix.get("work_weapons"), int):
            o.work_weapons = pickfix["work_weapons"]
    st = (material or {}).get("stock") if isinstance(material, dict) else None
    if isinstance(st, dict):
        if isinstance(st.get("coke"), int):
            o.coke = st["coke"]
        if isinstance(st.get("coal"), int):
            o.coal = st["coal"]
        if isinstance(st.get("wood"), int):
            o.wood = st["wood"]
    for name, d in (("raster", raster), ("kohle", kohle)):
        if isinstance(d, dict) and isinstance(d.get("laeuft"), bool):
            o.services[name] = d["laeuft"]
    if isinstance(raster, dict) and raster:
        o.raster_known = True
        o.raster_next = raster.get("naechste") if isinstance(raster.get("naechste"), str) else None
    for cl in cancels or []:
        o.cancels[cl.reason] = o.cancels.get(cl.reason, 0) + cl.count
    return o


QUERIES = {"auslastung": "claude/auslastung status", "pickfix": "claude/pickfix", "material": "claude/material status",
           "raster": "claude/raster status", "kohle": "claude/kohle status"}


class WorkloadPilot:
    def __init__(self, client, store, clock, cfg: dict):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def observe(self, snap, cancels=None) -> WorkObs:
        """Snapshot + extra queries (read only; pickfix without --apply is a dry run)."""
        extra = {}
        for k, cmd in QUERIES.items():
            r = self.client.run(cmd)
            extra[k] = r.json if r.ok and isinstance(r.json, dict) else None
        return obs_from(snap, cancels=cancels, **extra)

    def _effects(self, obs: WorkObs, now: float) -> list[str]:
        pending = list(self.store.get("workload.pending") or [])
        keep, out = [], []
        hist = dict(self.store.get("workload.effects") or {})
        for p in pending:
            if now - p["ts"] < self.cfg["measure_after_s"] or obs.idle_pct is None:
                keep.append(p)
                continue
            before = p.get("idle_before")
            gain = (before - obs.idle_pct) if before is not None else 0
            ok = gain >= self.cfg["effect_min_pct"]
            msg = (f"ok done: {p['key']} (idle {before:.0f} -> {obs.idle_pct:.0f} %)" if ok else
                   f"no effect: {p['key']} (idle {before if before is None else round(before)} -> "
                   f"{obs.idle_pct:.0f} %)")
            out.append(msg)
            self.store.warn(now, "workload", f"workload:effect:{p['key']}", msg, "warn")
            h = hist.setdefault(p["key"], {"ok": 0, "ohne": 0})
            h["ok" if ok else "ohne"] += 1
        self.store.set("workload.pending", keep)
        self.store.set("workload.effects", hist)
        return out

    def run(self, obs: WorkObs, *, dry: bool = False) -> list[str]:
        now = self.clock.now().epoch
        out = [] if dry else self._effects(obs, now)
        ms = diagnose(obs, self.cfg)
        if not ms:
            return out + [f"Workload ok (idle {obs.idle_pct if obs.idle_pct is not None else '?'} %)"]
        head = f"Idle {obs.idle_pct:.0f} % ({obs.idle} idle, {obs.jobs_open} jobs open, dig queue {obs.dig_queue})"
        out.append(head)
        autos = 0
        pending = list(self.store.get("workload.pending") or [])
        for m in ms[:5]:
            line = "- " + m.line()
            if m.auto and m.cmd:
                if autos >= self.cfg["max_auto_per_run"]:
                    line += " [deferred]"
                elif dry:
                    line += " [dry]"
                elif self.store.count_actions("workload", m.key, now - self.cfg["repeat_block_s"]) > 0:
                    line += " [blocked: < 10 min since last time]"
                else:
                    r = self.client.run(m.cmd)
                    self.store.log_action(now, "workload", "workload", m.key, "workload", m.cmd, False, r.ok, m.cause)
                    pending.append({"key": m.key, "ts": now, "idle_before": obs.idle_pct})
                    autos += 1
                    line += " [executed]" if r.ok else " [ERROR]"
            out.append(line)
        if not dry:
            self.store.set("workload.pending", pending)
        return out[:8]
