"""Spec v3-06: remote-worker protection (spec name `python -m df_llm_helper care remote`; implemented as `python -m df_llm_helper remote`).

Protects dwarves that work far away from food/drink (run 5: miner 4156 fished ~100 tiles away at the river for hours,
hunger 62,000 -> 67,000, re-took a fishing job after each cancel; 15 dwarves had FISH).

Measurement: `claude/pilot_remote status <LABORS>` (lua/pilot_remote.lua, live-untested): position, hunger/thirst, job,
squad/child/hospital, tracked labors, supply points (food stockpiles, wells), raw fish count.
Distance to the nearest supply point ~ Chebyshev(x, y) + z_penalty * |dz|.

Rules (maintenance; every action logged in state.db with its reason):
  1 rescue     (hunger or thirst > hunger_warn/thirst_warn) and (distance > far_tiles or job in long_jobs) and the job
               maps to a labor (job_labors) -> cancel the job (UI "cancel job") and take that labor away (labor menu +
               selective work details). Recorded in kv `remote_care.taken`; given back (labor + work details) as soon
               as hunger AND thirst < recover_below. Per dwarf at most once per repeat_block_s.
  2 pool       a labor in labor_pool (FISH: 3) is held by more civilians than the pool size -> the extra ones lose it
               (the pool keeps those with the lowest hunger). Not returned automatically (`python -m df_llm_helper remote restore`).
  3 supplies   proposal only: food stockpile / drink barrel near the place of a rescued or far dwarf.
  4 escalation hunger/thirst > hunger_crit: 'critical' line with name/place; > hunger_hopeless: only moving the dwarf
               by hand helps. Each level once per dwarf (dedupe, reset below hunger_warn).
  5 fish yield fish count series in kv; < fish_min_per_hour over the last hour with fishers -> proposal to switch off.
Never selected: soldiers (squad), children; no labor change for dwarves inside a hospital zone (return waits).
"""
from __future__ import annotations

import re
import shlex
from dataclasses import dataclass, field

__all__ = ["KEY", "DEFAULTS", "RemoteObs", "obs_from_status", "distance", "nearest_supply", "selectable",
           "rescue_targets", "pool_targets", "RemoteCare", "register", "check_hook"]

KEY = "remote_care"
DEFAULTS = {"far_tiles": 40, "hunger_warn": 40000, "thirst_warn": 40000, "hunger_crit": 55000,
            "hunger_hopeless": 65000, "recover_below": 15000, "z_penalty": 3,
            "long_jobs": ["Fish", "GatherPlants"],
            "job_labors": {"Fish": "FISH", "GatherPlants": "HERBALISM", "HarvestPlants": "PLANT", "Dig": "MINE"},
            "labor_pool": {"FISH": 3}, "repeat_block_s": 600, "max_actions_per_run": 20,
            "fish_min_per_hour": 1, "in_check": True}
SOURCE = "remote_care"
TAKEN = "remote_care.taken"


@dataclass
class RemoteObs:
    ok: bool = True
    citizens: list = field(default_factory=list)
    supplies: list = field(default_factory=list)
    fish: int | None = None
    wd_everybody: list = field(default_factory=list)


def _i(v, d: int = 0) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return d


def obs_from_status(j) -> RemoteObs:
    if not isinstance(j, dict) or not j.get("ok"):
        return RemoteObs(ok=False)
    return RemoteObs(True, [c for c in j.get("citizens") or [] if isinstance(c, dict)],
                     [s for s in j.get("supplies") or [] if isinstance(s, dict)],
                     j.get("fish") if isinstance(j.get("fish"), int) else None,
                     [str(w) for w in j.get("wd_everybody") or []])


def distance(a: dict, b: dict, z_penalty: int = 3) -> int:
    return max(abs(_i(a.get("x")) - _i(b.get("x"))), abs(_i(a.get("y")) - _i(b.get("y")))) + \
        z_penalty * abs(_i(a.get("z")) - _i(b.get("z")))


def nearest_supply(c: dict, supplies: list, z_penalty: int = 3) -> tuple[int | None, dict | None]:
    best, where = None, None
    for s in supplies:
        d = distance(c, s, z_penalty)
        if best is None or d < best:
            best, where = d, s
    return best, where


def selectable(c: dict) -> bool:
    """Never soldiers, children or dwarves in a hospital zone."""
    return not c.get("squad") and not c.get("child") and c.get("hospital") is None


def short_name(name, n: int = 28) -> str:
    """Name for one line: nickname in quotes dropped (it used to be cut mid-word: 'Dodok Batokkadol "Pr')."""
    s = re.sub(r'\s*"[^"]*"', "", str(name or "")).strip()
    return s[:n]


def _need(c: dict, cfg: dict) -> int:
    return max(_i(c.get("hunger")), _i(c.get("thirst")))


def _hungry(c: dict, cfg: dict) -> bool:
    return _i(c.get("hunger")) > int(cfg["hunger_warn"]) or _i(c.get("thirst")) > int(cfg["thirst_warn"])


def rescue_targets(obs: RemoteObs, cfg: dict) -> list[dict]:
    """[{unit, labor, job, dist}] - hungry/thirsty and far away or on a long job, job maps to a labor."""
    c = {**DEFAULTS, **(cfg or {})}
    out = []
    for u in obs.citizens:
        if not selectable(u) or not _hungry(u, c):
            continue
        dist, _ = nearest_supply(u, obs.supplies, int(c["z_penalty"]))
        far = dist is not None and dist > int(c["far_tiles"])
        job = u.get("job")
        if not (far or job in c["long_jobs"]):
            continue
        labor = c["job_labors"].get(job) if job else None
        if not labor:
            continue
        out.append({"unit": u, "labor": labor, "job": job, "dist": dist})
    out.sort(key=lambda t: -_need(t["unit"], c))
    return out


def pool_targets(obs: RemoteObs, cfg: dict) -> list[tuple[dict, str]]:
    """Civilians above the pool size of a pool labor -> (unit, labor). The pool keeps the lowest hunger (then id).
    Soldiers are ignored entirely; children and hospital dwarves are never changed."""
    c = {**DEFAULTS, **(cfg or {})}
    out = []
    for labor, size in (c["labor_pool"] or {}).items():
        holders = [u for u in obs.citizens if labor in (u.get("labors") or []) and not u.get("squad")]
        if len(holders) <= int(size):
            continue
        holders.sort(key=lambda u: (_i(u.get("hunger")), _i(u.get("thirst")), _i(u.get("id"))))
        out += [(u, labor) for u in holders[int(size):] if selectable(u)]
    return out


def _ok(res) -> bool:
    return bool(res.ok and (not isinstance(res.json, dict) or res.json.get("ok", True)))


class RemoteCare:
    def __init__(self, client, store, clock, cfg: dict | None = None):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def labors(self) -> list[str]:
        return sorted(set(self.cfg["job_labors"].values()) | set((self.cfg["labor_pool"] or {}).keys()))

    def status_cmd(self) -> str:
        return f"claude/pilot_remote status {','.join(self.labors())}"

    def observe(self) -> RemoteObs:
        r = self.client.run(self.status_cmd())
        return obs_from_status(r.json if r.ok else None)

    # ---- state.db records
    def taken(self) -> list[dict]:
        return list(self.store.get(TAKEN) or [])

    def _remember(self, unit: int, labor: str, kind: str, reason: str, wds: list, now: float) -> None:
        recs = [r for r in self.taken() if not (r["unit"] == unit and r["labor"] == labor)]
        recs.append({"unit": unit, "labor": labor, "kind": kind, "reason": reason, "ts": now, "work_details": wds})
        self.store.set(TAKEN, recs)

    def _forget(self, unit: int, labor: str) -> None:
        self.store.set(TAKEN, [r for r in self.taken() if not (r["unit"] == unit and r["labor"] == labor)])

    # ---- actions
    def _labor_off(self, u: dict, labor: str, kind: str, reason: str, now: float, dry: bool) -> str:
        cmd = f"claude/pilot_remote labor {u['id']} {labor} off"
        if dry:
            return f"[dry] {labor} off {u['id']}"
        res = self.client.run(cmd)
        ok = _ok(res)
        self.store.log_action(now, SOURCE, f"remote_{kind}", "labor_off", "labor", cmd, False, ok, reason)
        if ok:
            wds = res.json.get("work_details") if isinstance(res.json, dict) else []
            self._remember(int(u["id"]), labor, kind, reason, list(wds or []), now)
        return f"{labor} off {u['id']}" + ("" if ok else " (ERROR)")

    def _cancel(self, u: dict, reason: str, now: float, dry: bool) -> str:
        cmd = f"claude/pilot_remote cancel {u['id']}"
        if dry:
            return f"[dry] cancel {u['id']}"
        res = self.client.run(cmd)
        ok = _ok(res)
        self.store.log_action(now, SOURCE, "remote_rescue", "cancel_job", "job", cmd, False, ok, reason)
        return f"cancel {u['id']}" + ("" if ok else " (ERROR)")

    def restore(self, rec: dict, reason: str, now: float, dry: bool) -> str:
        wds = ",".join(rec.get("work_details") or [])
        cmd = f"claude/pilot_remote labor {rec['unit']} {rec['labor']} on" + (f" {shlex.quote(wds)}" if wds else "")
        if dry:
            return f"[dry] {rec['labor']} back to {rec['unit']}"
        res = self.client.run(cmd)
        ok = _ok(res)
        self.store.log_action(now, SOURCE, "remote_return", "labor_on", "labor", cmd, False, ok, reason)
        if ok:
            self._forget(int(rec["unit"]), rec["labor"])
        return f"{rec['labor']} back to {rec['unit']}" + ("" if ok else " (ERROR)")

    # ---- one pass
    def run(self, *, dry: bool = False) -> tuple[list[str], bool]:
        """-> (lines, worth_showing)."""
        now = self.clock.now().epoch
        obs = self.observe()
        if not obs.ok:
            return ["Remote: claude/pilot_remote status not readable (script installed?)"], True
        c = self.cfg
        by_id = {_i(u.get("id")): u for u in obs.citizens}
        out: list[str] = []
        show = False
        budget = int(c["max_actions_per_run"])
        # ---- return labors after recovery (rescue records only)
        back = []
        for rec in self.taken():
            if rec.get("kind") != "rescue":
                continue
            u = by_id.get(_i(rec.get("unit")))
            if u is None or not selectable(u):
                continue
            if _i(u.get("hunger")) < int(c["recover_below"]) and _i(u.get("thirst")) < int(c["recover_below"]):
                back.append(self.restore(rec, f"recovered: hunger {u.get('hunger')}, thirst {u.get('thirst')} < "
                                              f"{c['recover_below']}", now, dry))
        if back:
            out.append("Labors returned: " + ", ".join(back))
            show = True
        # ---- rule 1: rescue
        last = dict(self.store.get("remote_care.last_rescue") or {})
        resc, handled = [], set()
        for t in rescue_targets(obs, c):
            u = t["unit"]
            uid = str(u["id"])
            if now - float(last.get(uid, -1e18)) < float(c["repeat_block_s"]):
                continue
            if budget <= 0:
                out.append("Remote: action limit per run reached")
                break
            where = f"({u.get('x')},{u.get('y')},{u.get('z')})"
            reason = (f"hunger {u.get('hunger')}, thirst {u.get('thirst')}, job {t['job']}, "
                      f"{'%d tiles from food/drink' % t['dist'] if t['dist'] is not None else 'no supply point known'}"
                      f" at {where}")
            parts = [self._cancel(u, reason, now, dry)]
            if t["labor"] in (u.get("labors") or []):
                parts.append(self._labor_off(u, t["labor"], "rescue", reason, now, dry))
            budget -= 1
            handled.add(_i(u["id"]))
            if not dry:
                last[uid] = now
            resc.append(f"{u['id']} {short_name(u.get('name'))}: " + " + ".join(parts) + f" ({reason})")
            if t["dist"] is not None and t["dist"] > int(c["far_tiles"]):
                out.append(f"Proposal: food stockpile/drink barrel near {where} (work place {t['dist']} tiles from "
                           f"the nearest supply point)")
        if not dry:
            self.store.set("remote_care.last_rescue", last)
        if resc:
            out = ["Remote rescue: " + r for r in resc] + out
            show = True
        # ---- rule 2: pool
        pool_done = []
        for u, labor in pool_targets(obs, c):
            if _i(u.get("id")) in handled:
                continue
            if budget <= 0:
                out.append("Remote: action limit per run reached (pool continues next run)")
                break
            reason = f"labor pool {labor}: {c['labor_pool'][labor]} holders max (hunger {u.get('hunger')})"
            pool_done.append(self._labor_off(u, labor, "pool", reason, now, dry))
            budget -= 1
        if pool_done:
            out.append("Labor pool: " + ", ".join(pool_done))
            show = True
        soldiers = {lab: sum(1 for u in obs.citizens if lab in (u.get("labors") or []) and u.get("squad"))
                    for lab in (c["labor_pool"] or {})}
        if any(soldiers.values()) and pool_done:
            out.append("Note: soldiers with pool labors are not changed: "
                       + ", ".join(f"{k} {v}" for k, v in soldiers.items() if v))
        for w in obs.wd_everybody:
            if pool_done or resc:
                out.append(f"Note: work detail {w} is 'everybody does this' - taking the labor away cannot stick")
        # ---- rule 4: escalation (dedupe per dwarf and level)
        esc = dict(self.store.get("remote_care.escalated") or {})
        for u in obs.citizens:
            uid = str(u.get("id"))
            need = _need(u, c)
            level = 2 if need > int(c["hunger_hopeless"]) else 1 if need > int(c["hunger_crit"]) else 0
            if need < int(c["hunger_warn"]):
                esc.pop(uid, None)
                continue
            if level > int(esc.get(uid, 0)):
                esc[uid] = level
                place = f"({u.get('x')},{u.get('y')},{u.get('z')})"
                txt = (f"!! critical: {u.get('id')} {short_name(u.get('name'))} hunger {u.get('hunger')}, thirst "
                       f"{u.get('thirst')} at {place}")
                if level == 2:
                    txt += " - only moving the dwarf by hand helps now (burrow/station)"
                out.append(txt)
                show = True
                if not dry:
                    self.store.warn(now, SOURCE, f"remote:crit:{uid}", txt, "crit")
        if not dry:
            self.store.set("remote_care.escalated", esc)
        # ---- rule 5: fish yield
        fl = self.fish_line(obs, now, dry)
        if fl:
            out.append(fl)
            show = show or fl.startswith("Proposal")
        if not out:
            out.append(f"Remote ok ({len(self.taken())} labors held back)")
        return out[:10], show

    def fish_line(self, obs: RemoteObs, now: float, dry: bool) -> str:
        if obs.fish is None:
            return ""
        ser = [p for p in (self.store.get("remote_care.fish") or []) if now - p[0] <= 7200]
        if not dry:
            ser.append([now, obs.fish])
            self.store.set("remote_care.fish", ser)
        else:
            ser = ser + [[now, obs.fish]]
        fishers = sum(1 for u in obs.citizens if "FISH" in (u.get("labors") or []))
        old = [p for p in ser if now - p[0] >= 3600]
        if not old or not fishers:
            return f"Fish {obs.fish}"
        base = old[-1]
        rate = max(0, obs.fish - base[1]) * 3600.0 / max(1.0, now - base[0])
        if rate < float(self.cfg["fish_min_per_hour"]):
            return (f"Proposal: fishing yields {rate:.1f} fish/h (< {self.cfg['fish_min_per_hour']}) with {fishers} "
                    f"fishers - switch FISH off (labor menu)")
        return f"Fish {obs.fish} (+{rate:.1f}/h)"

    def restore_all(self, *, dry: bool = False) -> list[str]:
        now = self.clock.now().epoch
        recs = self.taken()
        if not recs:
            return ["Nothing held back"]
        return [self.restore(r, "manual restore (python -m df_llm_helper remote restore)", now, dry) for r in recs]

    def status(self) -> list[str]:
        obs = self.observe()
        if not obs.ok:
            return ["Remote: claude/pilot_remote status not readable (script installed?)"]
        lines = []
        for u in sorted(obs.citizens, key=lambda u: -_need(u, self.cfg))[:8]:
            if _need(u, self.cfg) < int(self.cfg["hunger_warn"]) and u.get("job") not in self.cfg["long_jobs"]:
                continue
            dist, _ = nearest_supply(u, obs.supplies, int(self.cfg["z_penalty"]))
            lines.append(f"{u.get('id')} {short_name(u.get('name'))}: hunger {u.get('hunger')}, thirst "
                         f"{u.get('thirst')}, job {u.get('job')}, distance {dist}")
        for lab, size in (self.cfg["labor_pool"] or {}).items():
            n = sum(1 for u in obs.citizens if lab in (u.get("labors") or []) and not u.get("squad"))
            lines.append(f"{lab}: {n} civilians (pool {size})")
        for r in self.taken():
            lines.append(f"held back: {r['labor']} of {r['unit']} ({r['kind']}: {r['reason'][:60]})")
        return lines or ["Remote ok"]


# ---- CLI / check
def cmd_remote(args) -> int:
    from ..cli import _pilot
    p = _pilot(args)
    rc = RemoteCare(p.client, p.store, p.clock, p.cfg.get(KEY, {}))
    if args.action == "status":
        print("\n".join(rc.status()))
    elif args.action == "restore":
        print("\n".join(rc.restore_all(dry=args.dry_run)))
    else:
        print("\n".join(rc.run(dry=args.dry_run)[0]))
    return 0


def register(sub) -> None:
    s = sub.add_parser("remote", help="Remote-worker protection (spec v3-06 'python -m df_llm_helper care remote'): check|status|restore",
                       description="Remote-worker protection, spec v3-06 'python -m df_llm_helper care remote' (own command, care.py "
                                   "unchanged). check = one maintenance pass, status = show, restore = give back all "
                                   "labors held back.")
    s.add_argument("action", nargs="?", default="check", choices=["check", "status", "restore"])
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_remote)


def check_hook(pilot, report, dry: bool) -> list[str]:
    lines, show = RemoteCare(pilot.client, pilot.store, pilot.clock, pilot.cfg.get(KEY, {}) or {}).run(dry=dry)
    return lines[:6] if show else []
