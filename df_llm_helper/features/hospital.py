"""FEATURE-004: hospital watch (`python -m df_llm_helper hospital`), staff posts and the plaster check.

Wounded citizens during the Run 5 siege, and nobody checked whether care was possible. Root cause found live
(02.10.2026): the hospital location's staff posts (world.occupations DOCTOR/DIAGNOSTICIAN/SURGEON/BONE_DOCTOR) were all
empty - then the game creates NO care jobs at all, whatever labors the citizens have.

- status (read only, one `claude/pilot_hospital status` call): staff posts per hospital location (filled by a living
  adult? a post that points at a dead unit counts as unfilled), citizens per care labor (idle/injured/in a squad),
  patients and how long they wait without a care job, hospital zone furniture (beds, table, traction bench, chest),
  duplicated/orphaned hospitals, water reachable from the hospital and in the refuge burrow (BUG-423 refuge_supply),
  supplies (cloth, thread, splints, crutches, plaster, soap; forbidden ones apart) and successor suggestions for the
  empty posts. One line for the digest: `Hospital ok` or `HOSPITAL: 3 patients, 0 doctors with SURGERY, water
  unreachable`; a changed problem set writes one warning (crit -> one wake line), an unchanged state stays silent.
- staff [--apply]: fills the unfilled posts the way the location menu does (`pilot_hospital staff <post> <unit>`) and
  gives the new staff the care labors (`pilot_care labors`). Without --apply: plan only. --apply needs an
  exception-register entry HOSPITAL (player consent).
- plan: the medical supply planner (planners/medical.py): splints/crutches from wood, plaster powder ONLY when
  gypsum-class stone (gypsum, alabaster, selenite, satinspar) is in stock or on visible tiles.
Lua part: lua/pilot_hospital.lua (LIVE-UNTESTED). Pure post/staff rules live in care.py.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from .. import care

__all__ = ["KEY", "DEFAULTS", "STATUS_CMD", "HospitalEval", "evaluate", "wait_update", "summary_line", "status_lines",
           "staff_plan", "supply_plan", "track", "Hospital", "register", "check_hook"]

KEY = "hospital"
STATUS_CMD = "claude/pilot_hospital status"
DEFAULTS = {
    "wait_ticks": 2400,         # a patient without any care job for this many game ticks is reported as waiting
    "stress_max": 75000,        # post candidates above this stress are skipped
    "labors": ["DIAGNOSE", "SURGERY", "BONE_SETTING", "SUTURING", "DRESSING_WOUNDS", "FEED_WATER_CIVILIANS",
               "RECOVER_WOUNDED"],     # given to new hospital staff (staff --apply)
    "targets": {},              # supply targets for the planner (planners/medical.DEFAULT_TARGETS)
    "every_s": 600,             # check_hook interval (the status call walks all items once: not every minute)
    "in_check": True,
}


@dataclass
class HospitalEval:
    patients: list = field(default_factory=list)
    staff: dict = field(default_factory=dict)
    problems: list = field(default_factory=list)     # (level, key, text): level crit|warn
    info: list = field(default_factory=list)         # report-only lines (orphaned locations, supplies)
    unfilled: list = field(default_factory=list)     # unfilled posts (care.unfilled_posts)
    suggestions: list = field(default_factory=list)  # (post, candidate)
    waiting: list = field(default_factory=list)      # patient ids waiting longer than wait_ticks
    doctors: int = 0

    @property
    def ok(self) -> bool:
        return not self.problems

    @property
    def critical(self) -> bool:
        return any(p[0] == "crit" for p in self.problems)


def _list(v) -> list:
    if isinstance(v, dict):                 # an empty Lua table may arrive as {}
        return list(v.values())
    return [x for x in v or [] if isinstance(x, dict)]


def wait_update(patients: list[dict], prev: dict | None, tick: int | None, wait_ticks: int) -> tuple[list, dict]:
    """Patients without a care job since >= wait_ticks: (waiting ids, new memory {id: first tick without a job})."""
    prev = {str(k): v for k, v in (prev or {}).items()}
    if tick is None:
        return [], prev
    mem, waiting = {}, []
    for p in patients:
        jobs = p.get("care_jobs")
        if isinstance(jobs, (list, dict)) and jobs:
            continue
        k = str(p.get("id"))
        first = int(prev.get(k, tick))
        mem[k] = first
        if tick - first >= wait_ticks:
            waiting.append(p.get("id"))
    return waiting, mem


def evaluate(data: dict, cfg: dict | None = None, *, waiting: list | None = None) -> HospitalEval:
    c = {**DEFAULTS, **(cfg or {})}
    ev = HospitalEval()
    cits = _list(data.get("citizens"))
    hs = _list(data.get("hospitals"))
    locs = _list(data.get("locations"))
    ev.patients = [p for p in cits if care.is_patient(p)]
    ev.staff = care.labor_staff(cits)
    ev.doctors = len({x.get("id") for x in cits if set(x.get("labors") or []) & {"DIAGNOSE", "SURGERY", "BONE_SETTING"}
                      and not x.get("squad")})
    ev.waiting = list(waiting or [])
    pat = bool(ev.patients)
    lvl = "crit" if pat else "warn"

    def add(level, key, text):
        ev.problems.append((level, key, text))

    # staff posts (addendum 02.10.2026)
    zoned = [loc for loc in locs if loc.get("zones")]
    ev.unfilled = care.unfilled_posts(locs)
    for loc in zoned:
        posts = [p for p in loc.get("posts") or [] if isinstance(p, dict)]
        if not posts:
            add(lvl, "posts", f"no staff posts at hospital location {loc.get('id')} (assign the location to the zone)")
        elif not care.location_staffed(posts):
            add(lvl, "posts", "no staff posts filled" + (f" (location {loc.get('id')})" if len(zoned) > 1 else ""))
    dead = [p for p in ev.unfilled if p.get("dead_holder")]
    if dead:
        add("warn", "posts_dead", "posts held by dead units: " + ", ".join(
            f"{p.get('type')} #{p.get('id')} (unit {p.get('unit_id')})" for p in dead[:4]))
    orphans = [loc.get("id") for loc in locs if not loc.get("zones")]
    if orphans:
        ev.info.append(f"orphaned hospital locations without a zone: {orphans} (report only)")
    # labors
    if pat:
        for L in care.HOSPITAL_LABORS:
            if ev.staff.get(L, {}).get("n", 0) == 0:
                add("warn", f"labor:{L}", f"0 doctors with {L}")
    if ev.waiting:
        add("warn", "waiting", f"{len(ev.waiting)} patient(s) without a care job > {c['wait_ticks']} ticks")
    # zones
    if not hs:
        if pat or locs:
            add(lvl, "zone", "no hospital zone")
    else:
        for h in hs:
            if not int(h.get("beds") or 0):
                add(lvl, "beds", f"hospital zone {h.get('id')} without beds")
            if not int(h.get("tables") or 0):
                add("warn", "tables", f"hospital zone {h.get('id')} without a table (surgery)")
            if not int(h.get("containers") or 0):
                add("warn", "containers", f"hospital zone {h.get('id')} without a chest (supplies)")
        for d in care.duplicate_hospitals(hs):
            if d[0] == "locations":
                ev.info.append(f"several hospital locations in use: {list(d[1])} (report only)")
            else:
                add("warn", "duplicate", f"hospital zones {d[0]} and {d[1]} overlap (report only, nothing deleted)")
    # water
    w = data.get("water") if isinstance(data.get("water"), dict) else {}
    if hs and w.get("reach_hospital") is False:
        add(lvl, "water_hospital", "water unreachable from the hospital (no well/drink reachable)")
    ref = data.get("refuge") if isinstance(data.get("refuge"), dict) else None
    if ref is not None and ref.get("water_ok") is False:
        add("warn", "water_refuge", "water unreachable in the refuge burrow (no drink, well or water tile)")
    # supplies
    sup = data.get("supplies") if isinstance(data.get("supplies"), dict) else {}
    forb = sup.get("forbidden") if isinstance(sup.get("forbidden"), dict) else {}
    keys = ("cloth", "thread", "splint", "crutch", "plaster", "soap")
    if sup:
        ev.info.append("supplies: " + ", ".join(f"{k} {int(sup.get(k) or 0)}" + (f" (+{int(forb[k])} forbidden)"
                                                                            if int(forb.get(k) or 0) else "")
                                                for k in keys))
    blocked = [k for k in keys if int(forb.get(k) or 0) and not int(sup.get(k) or 0)]
    if blocked:
        add("warn", "forbidden", "supplies only forbidden: " + ", ".join(blocked) + " (unforbid them)")
    if pat and sup:
        miss = [k for k in ("cloth", "thread", "splint") if not int(sup.get(k) or 0) and k not in blocked]
        if miss:
            add("warn", "supplies", "no " + "/".join(miss) + " for the patients")
    # successors for the empty posts
    held = {(p.get("holder") or {}).get("id") for loc in locs for p in loc.get("posts") or []
            if isinstance(p, dict) and care.post_filled(p)}
    cands = care.post_candidates(cits, len(ev.unfilled), stress_max=int(c["stress_max"]), exclude=held)
    ev.suggestions = list(zip(ev.unfilled, cands))
    return ev


def summary_line(ev: HospitalEval) -> str:
    if ev.ok:
        return f"Hospital ok ({len(ev.patients)} patients, {ev.doctors} doctors)"
    crit = [t for lvl, k, t in ev.problems if lvl == "crit"]
    labs = [k.split(":", 1)[1] for _, k, _ in ev.problems if k.startswith("labor:")]
    rest = [t for lvl, k, t in ev.problems if lvl != "crit" and not k.startswith("labor:")]
    parts = crit + ([f"0 doctors with {'/'.join(labs)}"] if labs else []) + rest
    line = f"HOSPITAL: {len(ev.patients)} patients, " + ", ".join(parts)
    return line if len(line) <= 200 else line[:199].rstrip() + "…"


def status_lines(ev: HospitalEval) -> list[str]:
    out = [summary_line(ev)]
    for lvl, _, t in ev.problems:
        out.append(f"{'!!' if lvl == 'crit' else '!'} {t}")
    def one(L, d):
        extra = [f"{d[k]} {w}" for k, w in (("idle", "idle"), ("injured", "injured"), ("squad", "in a squad")) if d[k]]
        return f"{L} {d['n']}" + (f" ({', '.join(extra)})" if extra else "")
    st = ", ".join(one(L, d) for L, d in ev.staff.items())
    out.append(f"staff: {st}")
    if ev.patients:
        out.append("patients: " + ", ".join(f"{p.get('id')} {care.short_name(p.get('name'), 16)}"
                                            f" ({'/'.join(_list_str(p.get('care_jobs'))) or 'no care job'})"
                                            for p in ev.patients[:8]))
    out += ev.info
    for post, cand in ev.suggestions:
        out.append(f"post {post.get('type')} #{post.get('id')} (location {post.get('location')}) -> "
                   f"{cand.get('id')} {care.short_name(cand.get('name'), 20)} (care skill {cand.get('care_skill', 0)})")
    if len(ev.suggestions) < len(ev.unfilled):
        out.append(f"{len(ev.unfilled) - len(ev.suggestions)} post(s) without a candidate (all citizens soldiers, "
                   "miners, patients or stressed)")
    return out


def _list_str(v) -> list[str]:
    return [str(x) for x in v] if isinstance(v, list) else []


def staff_plan(ev: HospitalEval, cfg: dict) -> list[str]:
    """Commands that fill the empty posts and give the care labors (one pair per post)."""
    labs = ",".join(cfg.get("labors") or DEFAULTS["labors"])
    out = []
    for post, cand in ev.suggestions:
        out.append(f"claude/pilot_hospital staff {post.get('id')} {cand.get('id')} --apply")
        out.append(f"claude/pilot_care labors {cand.get('id')} {labs}")
    return out


def supply_plan(data: dict, cfg: dict):
    from ..planners.medical import plan_medical
    sup = data.get("supplies") if isinstance(data.get("supplies"), dict) else {}
    pats = sum(1 for p in _list(data.get("citizens")) if care.is_patient(p))
    return plan_medical({k: v for k, v in sup.items() if k != "forbidden"}, data.get("gypsum"), patients=pats,
                        targets=cfg.get("targets") or None)


def _sig(ev: HospitalEval) -> str:
    return json.dumps(sorted({k for _, k, _ in ev.problems}))


def track(store, now: float, ev: HospitalEval, *, record: bool = True) -> tuple[bool, list[str]]:
    """State-change rule (problem kinds, not counts): one warning per change (crit -> one wake line); unchanged: []."""
    sig = _sig(ev)
    prev = store.get("hospital.sig")
    if prev == sig:
        return False, []
    line = summary_line(ev)
    if record:
        store.set("hospital.sig", sig)
        if not ev.ok:
            key = "hospital:" + hashlib.sha1(sig.encode("utf-8")).hexdigest()[:10]
            store.warn(now, "hospital", key, line, "crit" if ev.critical else "warn")
    if ev.ok and prev not in (None, "[]"):
        return True, [line + " (resolved)"]
    return True, [line]


class Hospital:
    def __init__(self, client, store, clock, cfg: dict | None = None, registry=None):
        self.client, self.store, self.clock, self.registry = client, store, clock, registry
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def read(self) -> dict | None:
        r = self.client.run(STATUS_CMD)
        j = r.json if r.ok and isinstance(r.json, dict) else None
        return j if j and j.get("ok") else None

    def evaluate(self, data: dict, *, record: bool = True) -> HospitalEval:
        pats = [p for p in _list(data.get("citizens")) if care.is_patient(p)]
        tick = data.get("tick") if isinstance(data.get("tick"), int) else None
        waiting, mem = wait_update(pats, self.store.get("hospital.wait"), tick, int(self.cfg["wait_ticks"]))
        if record:
            self.store.set("hospital.wait", mem)
        return evaluate(data, self.cfg, waiting=waiting)

    def staff(self, ev: HospitalEval, *, apply: bool) -> list[str]:
        cmds = staff_plan(ev, self.cfg)
        if not cmds:
            return ["Hospital posts: nothing to fill" if not ev.unfilled else
                    f"Hospital posts: {len(ev.unfilled)} unfilled, no candidate"]
        if not apply:
            return [f"[dry] {c}" for c in cmds] + ["(plan only - add --apply; needs a register entry HOSPITAL)"]
        if self.registry is None or not self.registry.allows("HOSPITAL"):
            return ["Refused: filling hospital posts needs the player's consent in the register: python -m "
                    "df_llm_helper exception add HOSPITAL --local --reason 'staff the hospital' --ja '<quote>'"] + \
                   [f"[dry] {c}" for c in cmds]
        now = self.clock.now().epoch
        out = []
        for c in cmds:
            r = self.client.run(c)
            j = r.json if isinstance(r.json, dict) else {}
            ok = bool(r.ok and j.get("ok", True) and not j.get("error"))
            self.store.log_action(now, "hospital", "hospital", "staff" if "pilot_hospital" in c else "labors",
                                  c.split()[2], c, False, ok, str(j.get("error") or j.get("done") or "")[:200])
            out.append(("ok   " if ok else "ERROR ") + c + (f" ({j.get('error')})" if j.get("error") else ""))
        return out


def _load_file(path: str):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig")), None
    except (OSError, ValueError) as e:
        return None, f"hospital: --file not readable ({e})"


def _cmd(args) -> int:
    reg = None
    if args.file:
        data, err = _load_file(args.file)
        if err:
            print(err)
            return 2
        cfg = dict(DEFAULTS)
        ev = evaluate(data, cfg)
        h = None
    else:
        from ..cli import _pilot          # lazy: no cli import at module level (import cycles)
        p = _pilot(args)
        reg = getattr(p.client, "registry", None)
        h = Hospital(p.client, p.store, p.clock, p.cfg.get(KEY, {}), registry=reg)
        data = h.read()
        if data is None:
            print(f"hospital: {STATUS_CMD} not readable (pilot_hospital installed? python -m df_llm_helper install-lua)")
            return 2
        cfg = h.cfg
        ev = h.evaluate(data, record=args.action == "status")
    if args.action == "plan":
        print("\n".join(supply_plan(data, cfg).lines() or ["Medical supplies: nothing to order"]))
        return 0
    if args.action == "staff":
        if h is None:
            print("\n".join([f"[dry] {c}" for c in staff_plan(ev, cfg)] or ["Hospital posts: nothing to fill"]))
            return 0
        print("\n".join(h.staff(ev, apply=bool(args.apply))))
        return 0
    if args.json:
        print(json.dumps({"ok": ev.ok, "critical": ev.critical, "summary": summary_line(ev),
                          "problems": [{"level": a, "key": b, "text": t} for a, b, t in ev.problems],
                          "info": ev.info, "waiting": ev.waiting,
                          "suggestions": [{"post": p.get("id"), "type": p.get("type"), "unit": c.get("id")}
                                          for p, c in ev.suggestions]}, ensure_ascii=False))
    else:
        lines = status_lines(ev)
        pl = supply_plan(data, cfg)
        lines += [f"plan: {ln}" for ln in pl.lines()]
        print("\n".join(lines))
    return 0 if ev.ok else 1


def register(sub) -> None:
    s = sub.add_parser("hospital", help="hospital watch: staff posts, care labors, patients, water, supplies, plaster")
    s.add_argument("action", nargs="?", default="status", choices=["status", "staff", "plan"])
    s.add_argument("--apply", action="store_true",
                   help="staff: really fill the posts + care labors (register entry HOSPITAL required)")
    s.add_argument("--file", default=None, help="recorded pilot_hospital status JSON instead of the game")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=_cmd)


def check_hook(pilot, report, dry: bool) -> list[str]:
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    last = pilot.store.get("hospital.last")
    if last is not None and now - float(last) < float(cfg["every_s"]):
        return []
    if not dry:
        pilot.store.set("hospital.last", now)
    h = Hospital(pilot.client, pilot.store, pilot.clock, cfg)
    data = h.read()
    if data is None:
        return []                       # script missing: `hospital` itself says so
    _, lines = track(pilot.store, now, h.evaluate(data, record=not dry), record=not dry)
    return lines
