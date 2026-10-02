"""Spec 04: hunger and hospital watcher (`python -m df_llm_helper care`).

Measures patients, doctors, hospital zones and care cancellations per cycle (`claude/pilot_care status`, not tested live,
plus gamelog). Rules:
  care_labors            fewer than min_doctors doctors -> up to pick_count idle civilians get all
                         care labors (labor menu); never soldiers, never dwarves with a pickaxe, never children/patients.
  care_duplicate_hospital several hospital zones at the same place / several hospital locations -> report only.
  care_floor_zone        a lying patient outside the hospital -> hint.
Escalation (hints only): 'Give water: No water source' > water_cancel_hint, meals/head < min_meals_per_head,
hunger/thirst > crit_* -> top-5 list.
"""
from __future__ import annotations

import re

from dataclasses import dataclass, field

from .anomaly import cancel_loops

__all__ = ["DEFAULTS", "CareObs", "obs_from_status", "doctors", "pick_candidates", "duplicate_hospitals",
           "evaluate", "CareWatch"]

DEFAULTS = {"min_doctors": 3, "pick_count": 5, "crit_hunger": 50000, "crit_thirst": 50000,
            "labors": ["DIAGNOSE", "SURGERY", "BONE_SETTING", "SUTURING", "DRESSING_WOUNDS", "FEED_WATER_CIVILIANS",
                       "RECOVER_WOUNDED"],
            "doctor_labors": ["DIAGNOSE", "SURGERY", "BONE_SETTING"],
            "water_cancel_hint": 50, "min_meals_per_head": 0.2, "max_labor_runs_per_hour": 1}
STATUS_CMD = "claude/pilot_care status"


@dataclass
class CareObs:
    citizens: list = field(default_factory=list)
    hospitals: list = field(default_factory=list)
    locations: list = field(default_factory=list)      # hospital locations {id, zones}; zones 0 = orphaned
    care_jobs: dict = field(default_factory=dict)
    meals: int | None = None
    ok: bool = True


def obs_from_status(j) -> CareObs:
    if not isinstance(j, dict) or not j.get("ok"):
        return CareObs(ok=False)
    jobs = j.get("care_jobs")
    return CareObs([c for c in j.get("citizens") or [] if isinstance(c, dict)],
                   [h for h in j.get("hospitals") or [] if isinstance(h, dict)],
                   [x for x in j.get("hospital_locations") or [] if isinstance(x, dict)],
                   jobs if isinstance(jobs, dict) else {}, j.get("meals"))


def is_patient(c: dict) -> bool:
    """Live 01.10.: #wounds also counts healed scars (56 'wounded', really 6 in the hospital). Patient = cannot
    stand, is lying down (job Rest) or has wounds AND is in the hospital."""
    return bool(c.get("cant_stand") or c.get("job") == "Rest" or (c.get("wounds") and c.get("hospital") is not None))


def doctors(obs: CareObs, cfg: dict) -> list[dict]:
    dl = set(cfg["doctor_labors"])
    return [c for c in obs.citizens if dl & set(c.get("labors") or []) and not c.get("squad")]


def pick_candidates(obs: CareObs, cfg: dict, n: int) -> list[dict]:
    """Idle civilians: no squad, no pickaxe, no child, no patient, not yet all care labors.
    Sorted by care skill descending, then id (deterministic)."""
    want = set(cfg["labors"])
    pool = [c for c in obs.citizens
            if c.get("idle") and not c.get("squad") and not c.get("pick") and not c.get("child")
            and not is_patient(c) and not want <= set(c.get("labors") or [])]
    pool.sort(key=lambda c: (-int(c.get("care_skill") or 0), int(c.get("id") or 0)))
    return pool[:max(0, n)]


def _overlap(a: dict, b: dict) -> bool:
    return (a.get("z") == b.get("z") and a.get("x1", 0) <= b.get("x2", -1) and b.get("x1", 0) <= a.get("x2", -1)
            and a.get("y1", 0) <= b.get("y2", -1) and b.get("y1", 0) <= a.get("y2", -1))


def duplicate_hospitals(hs: list[dict]) -> list[tuple]:
    out = []
    for i, a in enumerate(hs):
        for b in hs[i + 1:]:
            if _overlap(a, b):
                out.append((a.get("id"), b.get("id")))
    locs = sorted({h.get("location") for h in hs if isinstance(h.get("location"), int) and h["location"] >= 0})
    if len(locs) > 1:
        out.append(("locations", tuple(locs)))
    return out


def evaluate(obs: CareObs, cfg: dict, *, water_cancels: int = 0) -> dict:
    """Pure evaluation -> {'labor_targets', 'warnings', 'hints', 'critical', 'doctors'}."""
    c = {**DEFAULTS, **(cfg or {})}
    docs = doctors(obs, c)
    targets = pick_candidates(obs, c, c["pick_count"]) if len(docs) < c["min_doctors"] else []
    warnings, hints = [], []
    for d in duplicate_hospitals(obs.hospitals):
        if d[0] == "locations":
            warnings.append(f"Hospital duplicated: {len(d[1])} hospital locations {list(d[1])} - report only, nothing deleted")
        else:
            warnings.append(f"Hospital duplicated: zones {d[0]} and {d[1]} overlap - report only, nothing deleted")
    orphans = [x.get("id") for x in obs.locations if not x.get("zones")]
    if orphans:
        warnings.append(f"Hospital location without zone (orphaned): {orphans} - report only, nothing deleted")
    patients = [p for p in obs.citizens if is_patient(p)]
    floor = [p for p in patients if p.get("cant_stand") and p.get("hospital") is None]
    if floor:
        hints.append(f"{len(floor)} patient(s) lying outside the hospital (zone missing/too small): "
                     + ", ".join(str(p.get("id")) for p in floor[:5]))
    if patients and not obs.hospitals:
        hints.append("Wounded, but no hospital zone")
    if water_cancels > c["water_cancel_hint"]:
        hints.append(f"'Give water: No water source' {water_cancels}x -> water source missing (kb wasser_quelle)")
    pop = len(obs.citizens)
    if obs.meals is not None and pop and obs.meals / pop < c["min_meals_per_head"]:
        hints.append(f"Meals {obs.meals} for {pop} citizens (< {c['min_meals_per_head']}/head) -> kitchen/forecast")
    crit = [p for p in obs.citizens
            if int(p.get("hunger") or 0) > c["crit_hunger"] or int(p.get("thirst") or 0) > c["crit_thirst"]]
    crit.sort(key=lambda p: -max(int(p.get("hunger") or 0), int(p.get("thirst") or 0)))
    return {"labor_targets": targets, "warnings": warnings, "hints": hints, "critical": crit[:5], "doctors": docs,
            "patients": patients}


def short_name(name, n: int = 28) -> str:
    """'Aban Stelidkol "Washedwheels", Mechanic' -> 'Aban Stelidkol' (BUG-215: [:24] cut inside the nickname)."""
    s = re.sub(r'\s*"[^"]*"', "", str(name or "")).split(",")[0].strip()
    return s[:n]


def crit_line(p: dict, obs: CareObs) -> str:
    """One actionable line per starving/dehydrated citizen (BUG-215): where, which feeding jobs are open, what to do."""
    who = f"{p.get('id')} {short_name(p.get('name'))}" + (" (child)" if p.get("child") else "")
    head = f"!! {who}: hunger {p.get('hunger')}, thirst {p.get('thirst')}"
    feed = sum(int(v) for k, v in (obs.care_jobs or {}).items() if k in ("GiveFood", "GiveWater"))
    meals = f", meals {obs.meals}" if obs.meals is not None else ""
    if p.get("hospital") is not None:
        return (f"{head}, patient in hospital {p.get('hospital')} ({p.get('job') or 'no job'}): feeding jobs "
                f"{feed}{meals} -> check FEED_WATER_CIVILIANS labor and food/drink stockpile near the hospital")
    return (f"{head}, not in a hospital ({p.get('job') or 'no job'}){meals} -> food/drink reachable? "
            "(python -m df_llm_helper reach)")


class CareWatch:
    def __init__(self, client, tools, store, clock, cfg: dict, gamelog_lines=None):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.gamelog_lines = gamelog_lines or (lambda: [])

    def water_cancels(self) -> int:
        loops = cancel_loops(self.gamelog_lines(), min_count=1)
        return sum(l.count for l in loops if l.job == "Give water" and "No water source" in l.reason)

    def run(self, *, dry: bool = False) -> list[str]:
        now = self.clock.now().epoch
        r = self.client.run(STATUS_CMD)
        obs = obs_from_status(r.json if r.ok else None)
        if not obs.ok:
            return ["Care: claude/pilot_care status not readable (script installed?)"]
        ev = evaluate(obs, self.cfg, water_cancels=self.water_cancels())
        out: list[str] = []
        for p in ev["critical"]:
            out.append(crit_line(p, obs))
        if ev["labor_targets"]:
            reason = (f"{len(ev['doctors'])} doctors < {self.cfg['min_doctors']}, {len(ev['patients'])} wounded")
            if not dry and self.store.count_actions("care_labors", "labors", now - 3600) >= \
                    self.cfg["max_labor_runs_per_hour"]:
                out.append("Care labors: loop guard (already set this hour)")
            else:
                labs = ",".join(self.cfg["labors"])
                done = []
                for t in ev["labor_targets"]:
                    cmd = f"claude/pilot_care labors {t['id']} {labs}"
                    if dry:
                        done.append(f"[dry] {t['id']}")
                        continue
                    res = self.client.run(cmd)
                    ok = res.ok and isinstance(res.json, dict) and res.json.get("ok", True)
                    self.store.log_action(now, "care", "care_labors", "labors", "labors", cmd, False, bool(ok), reason)
                    done.append(f"{t['id']}" + ("" if ok else " (ERROR)"))
                out.append(f"Care labors set for {', '.join(done)} ({reason})")
        for w in ev["warnings"]:
            out.append(w)
            if not dry:
                self.store.warn(now, "care", "care:dup_hospital", w, "warn")
        out += ev["hints"]
        if not dry:
            for p in ev["critical"]:
                self.store.warn(now, "care", f"care:crit:{p.get('id')}",
                                f"Patient {p.get('id')} hunger {p.get('hunger')} thirst {p.get('thirst')}", "crit")
        return out[:8] or [f"Care ok ({len(ev['patients'])} wounded, {len(ev['doctors'])} doctors)"]
