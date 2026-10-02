"""Spec v3-05: tool/pick manager (`python -m df_llm_helper tools`).

Makes sure every miner has a work pick and dig jobs do not hang on missing equipment (E18, run 5: 15 work picks at 575
open dig jobs, 19 more picks in a bin, only 16 of 34 needed dwarves with the MINE labor; idle 75 % -> 32 % after the fix).

Measurement: `claude/pilot_tools status` (lua/pilot_tools.lua, read-only, live-untested).
Rules (maintenance, each action logged in state.db with its reason):
  1 pick balance   work_weapons < min(miners, picks_total) and free picks -> `claude/pickfix --apply` (frees
                   reservations, removes pick uniform specs, sets equipment update flags incl. the per-unit
                   pickup flag -> needs an exception-register entry FP08 that mentions the pick fix, otherwise refused).
                   Loop guard: max_pickfix_per_hour (6); same observation within repeat_block_s -> wait for the effect.
  2 more miners    open dig jobs > dig_jobs_min (100) and miners < picks_total -> up to max_new_miners (18) idle,
                   well-fed (hunger <= hunger_max), adult civilians join work detail `Miners` (work detail menu).
                   Never soldiers, children, patients, dwarves in a hospital zone. At most max_new_miners per hour.
  3 more picks     picks_total < miners + reserve -> forge proposal only (no automatic order; see `python -m df_llm_helper bottleneck`).
  4 plausibility   picks in containers (barracks bins) count as free; free picks are listed with their location.
  5 after load     report id dropped (save reloaded) -> pickfix once (`python -m df_llm_helper tools after-load` does it by hand).
  6 digest         'Picks 34/34, miners 34, digging 29, open dig jobs 256' or 'Picks 15/34: pickfix needed'.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone

__all__ = ["KEY", "DEFAULTS", "STATUS_CMD", "ToolsObs", "obs_from_status", "miner_candidates", "evaluate",
           "fp08_entry", "ToolsManager", "register", "check_hook"]

KEY = "tools"
DEFAULTS = {"reserve": 4, "max_new_miners": 18, "hunger_max": 30000, "workdetail": "Miners", "dig_jobs_min": 100,
            "max_pickfix_per_hour": 6, "repeat_block_s": 600,
            "pickfix_cmd": "claude/pickfix --apply", "after_load": True, "in_check": True}
STATUS_CMD = "claude/pilot_tools status"
SOURCE = "tools"


@dataclass
class ToolsObs:
    ok: bool = True
    picks_total: int = 0
    picks_free: int = 0
    free_where: list = field(default_factory=list)       # [{where, n}]
    work_weapons: int = 0
    dig_jobs: int = 0
    diggers_now: int = 0
    citizens: list = field(default_factory=list)

    @property
    def miners(self) -> int:
        return sum(1 for c in self.citizens if c.get("mine") and not c.get("child"))

    @property
    def without_pick(self) -> int:
        return sum(1 for c in self.citizens if c.get("mine") and not c.get("child") and not c.get("pick"))


def _i(v, d: int = 0) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return d


def obs_from_status(j) -> ToolsObs:
    if not isinstance(j, dict) or not j.get("ok"):
        return ToolsObs(ok=False)
    ww = j.get("work_weapons", j.get("work_picks"))
    return ToolsObs(True, _i(j.get("picks_total")), _i(j.get("picks_free")),
                    [w for w in j.get("free_where") or [] if isinstance(w, dict)], _i(ww), _i(j.get("dig_jobs")),
                    _i(j.get("diggers_now")), [c for c in j.get("citizens") or [] if isinstance(c, dict)])


def _patient(c: dict) -> bool:
    from ..care import is_patient
    return is_patient(c) or c.get("hospital") is not None


def miner_candidates(obs: ToolsObs, cfg: dict, n: int) -> list[dict]:
    """Idle, well-fed, adult civilians without MINE: never soldiers, children, patients or hospital dwarves.
    Sorted by mining skill descending, then id (deterministic)."""
    hmax = int(cfg["hunger_max"])
    pool = [c for c in obs.citizens
            if c.get("idle") and not c.get("squad") and not c.get("child") and not _patient(c)
            and not c.get("mine") and _i(c.get("hunger")) <= hmax and _i(c.get("thirst")) <= hmax]
    pool.sort(key=lambda c: (-_i(c.get("mining_skill")), _i(c.get("id"))))
    return pool[:max(0, n)]


def evaluate(obs: ToolsObs, cfg: dict | None = None, *, after_load: bool = False, max_add: int | None = None) -> dict:
    """Pure decision -> {'add_miners', 'pickfix', 'pickfix_reason', 'forge', 'miners_after', 'target', 'lines'}."""
    c = {**DEFAULTS, **(cfg or {})}
    out: dict = {"add_miners": [], "pickfix": False, "pickfix_reason": "", "forge": None, "lines": []}
    miners = obs.miners
    if obs.dig_jobs > int(c["dig_jobs_min"]) and miners < obs.picks_total:
        n = min(int(c["max_new_miners"]), obs.picks_total - miners)
        if max_add is not None:
            n = min(n, max_add)
            if max_add <= 0:
                out["lines"].append(f"Miners: loop guard ({c['max_new_miners']} added within the last hour)")
        out["add_miners"] = miner_candidates(obs, c, n)
    miners_after = miners + len(out["add_miners"])
    target = min(miners_after, obs.picks_total)
    out["miners_after"], out["target"] = miners_after, target
    if obs.work_weapons < target:
        if obs.picks_free > 0:
            out["pickfix"] = True
            out["pickfix_reason"] = (f"work picks {obs.work_weapons} < min(miners {miners_after}, picks "
                                     f"{obs.picks_total}), {obs.picks_free} free")
        else:
            out["lines"].append(f"Picks {obs.work_weapons}/{obs.picks_total}: no free pick - pickfix pointless")
    elif after_load and obs.picks_free > 0 and obs.picks_total > 0:
        out["pickfix"] = True
        out["pickfix_reason"] = "save reloaded (pick_after_load)"
    need = miners_after + int(c["reserve"])
    if obs.picks_total < need:
        out["forge"] = (f"Forge {need - obs.picks_total} pick(s) (picks {obs.picks_total} < miners {miners_after} + "
                        f"reserve {c['reserve']}); missing iron/coke -> `python -m df_llm_helper bottleneck`")
    return out


def summary(obs: ToolsObs, plan: dict | None = None) -> str:
    if plan and plan.get("pickfix"):
        return f"Picks {obs.work_weapons}/{obs.picks_total}: pickfix needed"
    return (f"Picks {obs.work_weapons}/{obs.picks_total}, miners {obs.miners}, digging {obs.diggers_now}, "
            f"open dig jobs {obs.dig_jobs}")


def free_line(obs: ToolsObs) -> str:
    if not obs.picks_free:
        return "Free picks: 0"
    return f"Free picks {obs.picks_free}: " + ", ".join(f"{w.get('where')} x{w.get('n')}" for w in obs.free_where[:4])


def fp08_entry(registry):
    """Exception-register entry FP08 that covers the per-unit pickup flag of the pick fix (reason or cmd_contains
    mentions 'pick'; an FP08 entry bound to item ids (foreign flag) does not count)."""
    if registry is None:
        return None
    now = registry._now_iso() if hasattr(registry, "_now_iso") else \
        datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for e in getattr(registry, "entries", []):
        if e.action != "FP08" or e.objects:
            continue
        if e.expires and e.expires < now:
            continue
        if e.max_uses is not None and registry.uses.get("FP08", 0) >= e.max_uses:
            continue
        if "pick" in (e.reason or "").lower() or "pick" in (e.cmd_contains or "").lower():
            return e
    return None


FP08_REFUSAL = ("pickfix refused: it writes the per-unit pickup flag (uniform.pickup_flags.update) and needs an "
                "exception-register entry FP08 for the pick fix (python -m df_llm_helper exception add FP08 --reason \"pick fix: "
                "per-unit pickup flag\" --ja \"<player quote>\")")


class ToolsManager:
    def __init__(self, client, store, clock, cfg: dict | None = None, registry=None):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.registry = registry if registry is not None else getattr(client, "registry", None)

    def observe(self) -> ToolsObs:
        r = self.client.run(STATUS_CMD)
        return obs_from_status(r.json if r.ok else None)

    def detect_loaded(self, report_id) -> bool:
        """Report id dropped since the last check -> the save was reloaded (own kv key, independent of reboot)."""
        if report_id is None:
            return False
        last = self.store.get("tools.last_report")
        self.store.set("tools.last_report", int(report_id))
        return last is not None and int(report_id) < int(last)

    def status(self) -> list[str]:
        obs = self.observe()
        if not obs.ok:
            return ["Tools: claude/pilot_tools status not readable (script installed?)"]
        plan = evaluate(obs, self.cfg)
        lines = [summary(obs, plan), free_line(obs), f"Miners without pick: {obs.without_pick}"]
        if plan["forge"]:
            lines.append("Proposal: " + plan["forge"])
        return lines

    def run(self, *, dry: bool = False, after_load: bool = False) -> tuple[list[str], bool]:
        """One maintenance pass -> (lines, acted_or_deviating)."""
        now = self.clock.now().epoch
        obs = self.observe()
        if not obs.ok:
            return ["Tools: claude/pilot_tools status not readable (script installed?)"], True
        budget = int(self.cfg["max_new_miners"]) - (0 if dry else self.store.count_actions(
            "tools_miners", "workdetail", now - 3600))
        plan = evaluate(obs, self.cfg, after_load=after_load, max_add=budget)
        out: list[str] = []
        acted = False
        # ---- rule 2: more miners (first, so the pick fix flags them too)
        if plan["add_miners"]:
            reason = (f"open dig jobs {obs.dig_jobs} > {self.cfg['dig_jobs_min']}, miners {obs.miners} < picks "
                      f"{obs.picks_total}")
            done, added = [], list(self.store.get("tools.added_miners") or [])
            for cnd in plan["add_miners"]:
                cmd = f"claude/workdetail assign {cnd['id']} {self.cfg['workdetail']} true"
                if dry:
                    done.append(f"[dry] {cnd['id']}")
                    continue
                res = self.client.run(cmd)
                ok = bool(res.ok and (not isinstance(res.json, dict) or res.json.get("ok", True)))
                self.store.log_action(now, SOURCE, "tools_miners", "workdetail", "labor", cmd, False, ok, reason)
                if ok:
                    added.append({"unit": cnd["id"], "ts": now, "reason": reason})
                done.append(f"{cnd['id']}" + ("" if ok else " (ERROR)"))
            if not dry:
                self.store.set("tools.added_miners", added[-200:])
            out.append(f"Miners +{len(done)} ({self.cfg['workdetail']}): {', '.join(done)} ({reason})")
            acted = True
        # ---- rule 1/5: pick balance
        if plan["pickfix"]:
            acted = True
            out.append(self._pickfix(now, obs, plan, dry))
        # ---- rule 3/4/6
        out += plan["lines"]
        if plan["lines"]:
            acted = True
        if plan["forge"]:
            out.append("Proposal: " + plan["forge"])
        if obs.work_weapons < plan["target"] and obs.picks_free:
            out.append(free_line(obs))
        out.insert(0, summary(obs, plan))
        return out, acted or obs.work_weapons < plan["target"]

    def _pickfix(self, now: float, obs: ToolsObs, plan: dict, dry: bool) -> str:
        cmd = self.cfg["pickfix_cmd"]
        sig = [obs.work_weapons, obs.picks_free, plan["miners_after"], obs.picks_total]
        last = self.store.get("tools.last_pickfix") or {}
        if last.get("sig") == sig and now - float(last.get("ts", 0)) < float(self.cfg["repeat_block_s"]):
            return f"pickfix: waiting for the effect of the last run ({int(now - last['ts'])} s ago, nothing changed)"
        if not dry and self.store.count_actions("tools_pickfix", "pickfix", now - 3600) >= \
                int(self.cfg["max_pickfix_per_hour"]):
            return f"pickfix: loop guard ({self.cfg['max_pickfix_per_hour']}/h reached)"
        entry = fp08_entry(self.registry)
        if entry is None:
            if not dry:
                self.store.warn(now, SOURCE, "tools:fp08", FP08_REFUSAL, "warn")
            return FP08_REFUSAL
        if dry:
            return f"[dry] {cmd} ({plan['pickfix_reason']})"
        self.registry.consume("FP08")
        res = self.client.run(cmd)
        ok = bool(res.ok and (not isinstance(res.json, dict) or res.json.get("ok", True)))
        reason = plan["pickfix_reason"] + f"; FP08: {entry.reason}"
        self.store.log_action(now, SOURCE, "tools_pickfix", "pickfix", "picks", cmd, False, ok, reason)
        self.store.set("tools.last_pickfix", {"ts": now, "sig": sig})
        after = res.json.get("work_weapons") if isinstance(res.json, dict) else None
        flagged = res.json.get("flagged") if isinstance(res.json, dict) else None
        return (f"pickfix {'ok' if ok else 'ERROR'} ({plan['pickfix_reason']})"
                + (f" -> work picks {after}" if after is not None else "")
                + (f", {flagged} dwarves flagged" if flagged is not None else ""))


# ---- CLI / check
def cmd_tools(args) -> int:
    from ..cli import _pilot
    p = _pilot(args)
    tm = ToolsManager(p.client, p.store, p.clock, p.cfg.get(KEY, {}))
    if args.action == "status":
        print("\n".join(tm.status()))
        return 0
    lines, _ = tm.run(dry=args.dry_run, after_load=args.action == "after-load")
    print("\n".join(lines))
    return 0


def register(sub) -> None:
    s = sub.add_parser("tools", help="Tool/pick manager (spec v3-05): check|status|after-load",
                       description="Tool/pick manager, spec v3-05. check = one maintenance pass (miners, pickfix with "
                                   "FP08 entry, forge proposal), status = show, after-load = pickfix once after reload.")
    s.add_argument("action", nargs="?", default="check", choices=["check", "status", "after-load"])
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_tools)


def check_hook(pilot, report, dry: bool) -> list[str]:
    cfg = pilot.cfg.get(KEY, {}) or {}
    tm = ToolsManager(pilot.client, pilot.store, pilot.clock, cfg)
    snap = getattr(report, "snapshot", None)
    loaded = bool({**DEFAULTS, **cfg}.get("after_load")) and \
        tm.detect_loaded(getattr(snap, "max_report_id", None) if snap is not None else None)
    lines, show = tm.run(dry=dry, after_load=loaded)
    return lines[:5] if show else []
