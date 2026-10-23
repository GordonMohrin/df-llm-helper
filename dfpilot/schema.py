"""v2 file-format validators (stdlib only). Normative spec: docs/v2/CONTRACTS.md.

    validate(kind, doc) -> list[str]      # [] = valid
    check(kind, doc) -> doc               # raises SchemaError
    validate_args(verb, args) -> list[str]
    prune_state(doc) -> (doc | None, errs) # reader rule: drop invalid optional top-level keys
    json_schema(kind) -> dict             # JSON Schema (draft 2020-12) of the envelope

CLI: python -m dfpilot.schema validate <kind> <file>   (events.jsonl: every line)
     python -m dfpilot.schema --appendix | --json-schema <kind> | --write-appendix docs/v2/CONTRACTS.md
The constants mirror lua/dfllm/util/contract.lua (tests/test_schema.py checks both agree).
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any, Callable

V = 2
TICKS = {"DAY": 1200, "MONTH": 33600, "SEASON": 100800, "YEAR": 403200}
ID_RE = r"^[A-Za-z0-9_-]{1,40}$"
BRIDGE_RE = r"^[A-Z][A-Za-z0-9]{0,7}$"
TPL_RE = r"^[a-z][a-z0-9_]{1,31}$"
MODULE_RE = r"^[a-z][a-z_]{1,15}$"
TYPE_RE = r"^[A-Z][A-Z0-9_]{1,31}$"
TOKEN_RE = r"^[a-z_]+(:[a-z_]+)?$"
PHASE_RE = r"^P[0-7]$"
INBOX_NAME_RE = r"^(\d{13})-([A-Za-z0-9_-]{1,40})\.json$"

MODES = ["PEACE", "ALERT", "SIEGE", "BREACH", "RECOVERY", "DRILL"]
TRANSITIONS = {
    "PEACE": ["ALERT", "SIEGE", "DRILL"], "ALERT": ["PEACE", "SIEGE", "BREACH"],
    "SIEGE": ["BREACH", "RECOVERY"], "BREACH": ["RECOVERY", "SIEGE"],
    "RECOVERY": ["PEACE", "ALERT", "SIEGE", "BREACH"], "DRILL": ["PEACE", "ALERT", "SIEGE"],
}
MODE_SETTERS = {"siege": "*", "drill": ["DRILL>PEACE", "PEACE>DRILL"]}
# READY_IN (BUG-029): every squad at the inner station; INTAKE (Gordon 2026-10-16): field and gallery during a wave;
# CORE (BUG-030): every squad at the core station in the deep defense
POSTURES = ["TRAIN", "STATION_B1", "READY_STATION", "B2_HOLD", "READY_IN", "INTAKE", "CORE"]
BRIDGE_STATES = ["up", "down", "moving", "unknown", "destroyed", "replaced"]   # BUG-030: destroyed = gone from its footprint;
# BUG-048: replaced = seal made it a wall and a door (no gate, no open way)
ORDER_LIBS = ["library/basic", "library/furnace", "library/smelting", "library/military",
              "library/rockstock", "library/glassstock"]
SNAP_LEGEND = "?_.#SCF<>Xrv+=H^Bw~%T "     # BUG-043: " " = not exported (outside every part of a union export)
TRAP_TYPES = ["W", "S", "C", "P", "X"]
BY = ["llm", "gordon", "cli", "follow", "supervise", "test"]

# name, wp, critical, every (contract.MODULES, dispatch order)
MODULES = [
    ("sense", "WP5", True, {"ticks": 10}), ("threat", "WP5", True, {"ticks": 25}),
    ("siege", "WP5", True, {"ticks": 25}), ("gate", "WP5", True, {"ticks": 25}),
    ("reflex", "WP5", True, {"ticks": 10}),
    ("military", "WP6", False, {"ticks": 3600}), ("drill", "WP6", False, {"ticks": 600}),
    ("readiness", "WP6", False, {"ticks": 33600}), ("arbiter", "WP1", True, {"ms": 500}),
    ("runner", "WP7", False, {"ticks": 600}), ("snapshot", "WP7", False, {"ticks": 100}),
    ("seal", "WP7", False, {"ticks": 50}),
    ("economy", "WP8", False, {"ticks": 1200}), ("care", "WP8", False, {"ticks": 1200}),
    ("water", "WP8", False, {"ticks": 1200}),
    ("trade", "WP9", False, {"ticks": 100}), ("baseline", "WP8", False, {"ticks": 33600}),
    ("perf", "WP1", False, {"ms": 1000}), ("selftest", "WP1", False, {"ms": 60000}),
]

DECISIONS = {
    "D-01": "A", "D-02": "unchanged", "D-03": "rule", "D-04": "off", "D-05": "off", "D-06": "off",
    "D-07": "unchanged", "D-08": "dropped", "D-09": "no", "D-10": "off", "D-11": "accepted",
    "D-12": "15/20", "D-13": "no", "D-14": "down",
}

ACT = {
    "set_paused": ["arbiter"], "timestream": ["arbiter"], "setting": ["arbiter"], "overlay": ["arbiter"],
    "dismiss_popup": ["arbiter"], "civ_alert": ["siege"], "alert_burrows": ["siege"],
    "squad_create": ["military"], "squad_leader": ["military"], "squad_add": ["military"],
    "squad_remove": ["military"],
    "squad_routine": ["military"], "squad_order": ["military"], "squad_uniform": ["military"],
    "squad_unequip": ["military"], "squad_release": ["military"], "animal_slaughter": ["economy"], "zone_remove": ["runner"], "manager_office": ["economy"], "pond_remove": ["water"],
    "hospital_remove": ["water"],                  # BUG-034: the zones of a dry hospital while a patient is thirsty
    "sand_zone": ["economy"], "fish_zone": ["economy"], "zone_place": ["runner"],
    "tool_pile": ["economy"],                      # BUG-053: a weapons stockpile for the miners' picks near the mines
    "pull": ["gate"], "cancel_own_lever_job": ["gate"], "link_lever": ["gate"], "burrow_units": ["gate"],
    "door_forbid": ["reflex"],
    "burrow_tiles": ["seal"],
    "popcap": ["readiness"],
    "quickfort": ["runner"], "order_top": ["runner"],     # Run 11 siege 8: a seal's manager orders to the top
    "orders_import": ["economy"], "orders": ["economy"], "workorder": ["economy", "water", "care"],
    "order_suspend": ["economy"], "kitchen_exclude": ["economy"], "appoint": ["economy"],
    "work_detail": ["economy", "water"], "order_material": ["economy"], "order_remove": ["economy"],
    "job_resume": ["economy"], "farm_crop": ["economy"], "plant_gather": ["economy"], "plant_ungather": ["economy"],
    "work_detail_prune": ["economy"],
    "item_flag": ["care", "water", "economy", "military"],
    "zone_assign": ["care"], "tomb_zone": ["care"], "medic": ["care"], "hospital_post": ["care"],
    "trade": ["trade"],
    "run": ["baseline", "economy", "care", "military", "trade", "arbiter", "selftest", "runner"],
}

STATE_OWNERS = {
    "v": "kern", "seq": "kern", "ev": "kern", "t.*": "kern", "mode": "kern", "save": "kern", "k.*": "kern",
    "phase": "runner", "proj": "runner", "sched.*": "runner",
    "pop.cit": "sense", "pop.adults": "sense", "pop.soldiers": "sense",
    "pop.cap": "readiness", "pop.gate_cap": "readiness", "ready.*": "readiness",
    "stock.drink_d": "economy", "stock.food_d": "economy", "stock.meals": "economy",
    "stock.ore": "economy", "stock.bars": "economy", "stock.leather": "economy", "stock.metal": "economy",
    "stock.hungry": "economy", "stock.mood_miss": "economy", "stock.rock": "economy", "stock.rock_need": "economy",
    "stock.picks": "economy",
    "stock.pick_want": "economy", "stock.mshort": "economy", "stock.melt": "economy", "stock.dwhy": "economy",
    "stock.hosp_water": "care", "care.*": "care", "labor.*": "economy", "orders.*": "economy",
    "threat.*": "threat", "bridges": "gate", "owners.*": "arbiter", "mil.*": "military", "trade.*": "trade",
    "clock.*": "arbiter", "alarm.*": "reflex", "lever.*": "gate",
    "alert.*": "seal", "wave.*": "siege", "snap.*": "snapshot", "water.*": "water",
}

# kernel fault and slowness rules (CONTRACTS §3.3.5-3.3.6), mirrors contract.KERN
KERN = {
    "fault_n": 3, "fault_window_ms": 600000,
    "backoff_ms": {"critical": 30000, "other": 600000}, "backoff_max_ms": {"critical": 480000, "other": 3600000},
    "backoff_reset_ms": 3600000,
    "slow_ms": 5, "slow_n": 3, "slow_window_ms": 600000, "promote_ms": 600000, "max_factor": 8,
    "big_ms": 1000,
}

# blueprint size caps (CONTRACTS §9.8): the kernel decodes a bp in one call (~14 ms per 1,000 cells)
BP_MAX_CELLS = 1000
BP_MAX_BYTES = 24576

PERSIST = {
    "marker": ("dfllm", "kern"), "manifest": ("dfllm.manifest", "runner"),
    "projects": ("dfllm.projects", "runner"), "plan": ("dfllm.plan", "kern"),
    "phase": ("dfllm.phase", "runner"), "mode": ("dfllm.mode", "kern"),
    "drill": ("dfllm.drill", "drill"), "restore": ("dfllm.restore", "arbiter"),
    "kern": ("dfllm.kern", "kern"),
}


class SchemaError(ValueError):
    def __init__(self, kind: str, errors: list[str]):
        super().__init__(f"{kind}: " + "; ".join(errors[:10]))
        self.kind, self.errors = kind, errors


def _tname(v: Any) -> str:
    return {bool: "bool", int: "int", float: "float", str: "str", list: "array",
            dict: "object", type(None): "null"}.get(type(v), type(v).__name__)


# ---------------------------------------------------------------- spec primitives
class Spec:
    def errors(self, v: Any, path: str, out: list[str]) -> None:
        raise NotImplementedError

    def js(self, defs: dict) -> dict:
        raise NotImplementedError

    def ref(self, defs: dict) -> dict:
        """Inline schema, or a $ref into defs when the spec was named with named()."""
        name = getattr(self, "name", None)
        if name is None:
            return self.js(defs)
        if name not in defs:
            defs[name] = {}
            defs[name] = self.js(defs)
        return {"$ref": f"#/$defs/{name}"}


def named(name: str, spec: "Spec") -> "Spec":
    spec.name = name
    return spec


class Int(Spec):
    def __init__(self, lo: int | None = None, hi: int | None = None):
        self.lo, self.hi = lo, hi

    def errors(self, v, path, out):
        if isinstance(v, bool) or not isinstance(v, int):
            out.append(f"{path}: expected int, got {_tname(v)}")
        elif self.lo is not None and v < self.lo:
            out.append(f"{path}: {v} < {self.lo}")
        elif self.hi is not None and v > self.hi:
            out.append(f"{path}: {v} > {self.hi}")

    def js(self, defs):
        d: dict = {"type": "integer"}
        if self.lo is not None:
            d["minimum"] = self.lo
        if self.hi is not None:
            d["maximum"] = self.hi
        return d


class Str(Spec):
    def __init__(self, pattern: str | None = None, maxbytes: int | None = None, enum: list[str] | None = None):
        self.pattern, self.maxbytes, self.enum = pattern, maxbytes, enum
        self._re = re.compile(pattern) if pattern else None

    def errors(self, v, path, out):
        if not isinstance(v, str):
            out.append(f"{path}: expected str, got {_tname(v)}")
        elif self.enum is not None and v not in self.enum:
            out.append(f"{path}: {v!r} not in {self.enum}")
        elif self._re and not self._re.fullmatch(v):
            out.append(f"{path}: {v!r} does not match {self.pattern}")
        elif self.maxbytes is not None and len(v.encode("utf-8")) > self.maxbytes:
            out.append(f"{path}: longer than {self.maxbytes} bytes")

    def js(self, defs):
        d: dict = {"type": "string"}
        if self.enum is not None:
            d["enum"] = list(self.enum)
        if self.pattern:
            d["pattern"] = self.pattern
        if self.maxbytes is not None:
            d["maxLength"] = self.maxbytes
        return d


class Bool(Spec):
    def errors(self, v, path, out):
        if not isinstance(v, bool):
            out.append(f"{path}: expected bool, got {_tname(v)}")

    def js(self, defs):
        return {"type": "boolean"}


class Null(Spec):
    def errors(self, v, path, out):
        if v is not None:
            out.append(f"{path}: expected null, got {_tname(v)}")

    def js(self, defs):
        return {"type": "null"}


class Const(Spec):
    def __init__(self, value: Any):
        self.value = value

    def errors(self, v, path, out):
        if v != self.value or type(v) is not type(self.value):
            out.append(f"{path}: expected {self.value!r}, got {v!r}")

    def js(self, defs):
        return {"const": self.value}


class AnyV(Spec):
    def errors(self, v, path, out):
        pass

    def js(self, defs):
        return {}


class Arr(Spec):
    def __init__(self, items: Spec, lo: int = 0, hi: int | None = None):
        self.items, self.lo, self.hi = items, lo, hi

    def errors(self, v, path, out):
        if not isinstance(v, list):
            out.append(f"{path}: expected array, got {_tname(v)}")
            return
        if len(v) < self.lo:
            out.append(f"{path}: {len(v)} items < {self.lo}")
        if self.hi is not None and len(v) > self.hi:
            out.append(f"{path}: {len(v)} items > {self.hi}")
        for i, x in enumerate(v):
            self.items.errors(x, f"{path}[{i}]", out)

    def js(self, defs):
        d = {"type": "array", "items": self.items.ref(defs)}
        if self.lo:
            d["minItems"] = self.lo
        if self.hi is not None:
            d["maxItems"] = self.hi
        return d


class Tup(Spec):
    def __init__(self, items: list[Spec], optional_tail: int = 0):
        self.items, self.opt = items, optional_tail

    def errors(self, v, path, out):
        n = len(self.items)
        if not isinstance(v, list):
            out.append(f"{path}: expected array, got {_tname(v)}")
        elif not (n - self.opt <= len(v) <= n):
            out.append(f"{path}: expected {n - self.opt}..{n} items, got {len(v)}")
        else:
            for i, x in enumerate(v):
                self.items[i].errors(x, f"{path}[{i}]", out)

    def js(self, defs):
        n = len(self.items)
        return {"type": "array", "prefixItems": [s.ref(defs) for s in self.items], "items": False,
                "minItems": n - self.opt, "maxItems": n}


class Obj(Spec):
    """Closed object unless `extra` (spec for other values) is given."""

    def __init__(self, req: dict | None = None, opt: dict | None = None, extra: Spec | None = None,
                 keys: str | None = None):
        self.req, self.opt, self.extra = req or {}, opt or {}, extra
        self.keys = re.compile(keys) if keys else None
        self.keys_src = keys

    def errors(self, v, path, out):
        if not isinstance(v, dict):
            out.append(f"{path}: expected object, got {_tname(v)}")
            return
        for k, s in self.req.items():
            if k not in v:
                out.append(f"{path}.{k}: missing")
            else:
                s.errors(v[k], f"{path}.{k}", out)
        for k, x in v.items():
            if k in self.req:
                continue
            if k in self.opt:
                self.opt[k].errors(x, f"{path}.{k}", out)
            elif self.extra is None:
                out.append(f"{path}.{k}: unknown key")
            else:
                if self.keys and not self.keys.fullmatch(k):
                    out.append(f"{path}: key {k!r} does not match {self.keys_src}")
                self.extra.errors(x, f"{path}.{k}", out)

    def js(self, defs):
        props = {k: s.ref(defs) for k, s in {**self.req, **self.opt}.items()}
        d: dict = {"type": "object"}
        if props:
            d["properties"] = props
        if self.req:
            d["required"] = list(self.req)
        d["additionalProperties"] = False if self.extra is None else self.extra.ref(defs)
        if self.keys_src:
            d["propertyNames"] = {"pattern": self.keys_src}
        return d


class AnyOf(Spec):
    def __init__(self, *opts: Spec):
        self.opts = opts

    def errors(self, v, path, out):
        best, best_key = None, None
        for s in self.opts:
            e: list[str] = []
            s.errors(v, path, e)
            if not e:
                return
            # prefer the alternative whose type matched (its errors are about the value)
            key = (all(x.startswith(f"{path}: expected ") for x in e), len(e))
            if best_key is None or key < best_key:
                best, best_key = e, key
        out.extend(best or [f"{path}: no alternative matched"])

    def js(self, defs):
        return {"anyOf": [s.ref(defs) for s in self.opts]}


class Checked(Spec):
    """spec plus a semantic check fn(v) -> error message or None (run only if spec passes)."""

    def __init__(self, spec: Spec, fn: Callable[[Any], str | None], desc: str):
        self.spec, self.fn, self.desc = spec, fn, desc

    def errors(self, v, path, out):
        e: list[str] = []
        self.spec.errors(v, path, e)
        if not e:
            msg = self.fn(v)
            if msg:
                e.append(f"{path}: {msg}")
        out.extend(e)

    def js(self, defs):
        d = dict(self.spec.js(defs))
        d["description"] = self.desc
        return d


# ---------------------------------------------------------------- shared specs
INT = Int()
NAT = Int(0)
FLAG = Int(0, 1)
PCT = Int(0, 100)
TICK = Int(0)
ID = named("id", Str(ID_RE))
TPL = named("tpl", Str(TPL_RE))
BRIDGE = Str(BRIDGE_RE)
SQUAD = AnyOf(NAT, Str(enum=["A", "B", "C"]))                  # BUG-055: a squad key or the game's squad id
SQUAD_MODES = ["PEACE", "ALERT", "RECOVERY"]                   # the squads screen is not touched in a fight
ZONE_TYPES = ["pen", "pit", "pond", "sand", "clay", "fishing", "meeting"]    # FR-78: lua/dfllm/zonelib.lua Z.TYPES
MODULE = named("module", Str(MODULE_RE))
MODE = named("mode", Str(enum=MODES))
PHASE = named("phase", Str(PHASE_RE))
POS = named("pos", Tup([INT, INT, INT]))
SCALAR = named("scalar", AnyOf(INT, Str(maxbytes=200), Bool()))
# cloth/thread kinds (Run 10 y418): cloth:plant|silk|yarn and thread:plant|silk|yarn only; plain cloth/thread = any
FIBRE_SUBS = ("plant", "silk", "yarn")


def _fibre_sub(s):
    kind, _, sub = s.partition(":")
    return (f"{kind}:{sub}: the {kind} kinds are {', '.join(kind + ':' + x for x in FIBRE_SUBS)} (plain {kind} = any)"
            if kind in ("cloth", "thread") and sub and sub not in FIBRE_SUBS else None)


TOKEN = named("token", Checked(Str(TOKEN_RE), _fibre_sub, "kind[:sub]; cloth/thread subs plant, silk, yarn"))


def _bbox_order(b):
    return None if b[0] <= b[3] and b[1] <= b[4] and b[2] <= b[5] else "bbox needs x0<=x1, y0<=y1, z0<=z1"


BBOX = named("bbox", Checked(Tup([INT] * 6), _bbox_order, "[x0,y0,z0,x1,y1,z1] inclusive"))
OPEN = Obj(extra=AnyV())

# ---------------------------------------------------------------- events
_DT = {"i": INT, "s": Str(maxbytes=200), "f": FLAG, "ia": Arr(INT, hi=50), "sa": Arr(Str(maxbytes=60), hi=50),
       "p": POS}


def _d(req: str = "", opt: str = "") -> Obj:
    def parse(s):
        return {k: _DT[t] for k, t in (x.split(":") for x in s.split())}
    return Obj(req=parse(req), opt=parse(opt), extra=AnyV())


# FR-64 death clusters: cause (a death category or `mixed`), deaths, units, `unit:cause` tokens, deaths in the window
_CLUSTER = _d("cause:s n:i", "units:ia causes:sa total:i days:i patients:i pos:p job:s hint:s stock:i")

# type -> (cls, by, d spec)
EVENTS: dict[str, tuple[str, str, Obj]] = {
    # BUG-052: sol0/soldiers = soldiers at the start/end of the episode, on_station = the best count seen, on_t = ticks
    # until half of them stood at their stations (-1 never)
    "SIEGE_END": ("A", "siege", _d(opt="hostiles:i killed:i lost:i captures:i sealed_ticks:i sol0:i soldiers:i "
                                       "on_station:i on_t:i")),
    "GATE_FAIL": ("A", "gate", _d("bridge:s", "want:s why:s units:ia pos:p")),
    "BREACH": ("A", "siege", _d("why:s", "bridge:s")),
    "DEATHS_3PLUS": ("A", "care", _d(opt="n:i ids:ia causes:sa")),
    "DRILL_FAIL": ("A", "drill", _d(opt="streak:i fails:sa")),
    "KERN_FAULT": ("A", "any", _d("module:s", "err:s n:i backoff_s:i")),     # BUG-075: the runner too (backoff_s 0)
    "PERF_DEGRADED": ("A", "perf", _d(opt="tps:i base:i pct:i why:s")),
    # Run 11: food_low/famine add food (days), block (blocker ids: fishery, kitchen, cook, fish_zone, hunt, farms,
    # butcher, gather) and opts (the options, the blockers' first); BUG-038: auto (what the kernel does itself:
    # fishery = its fishery request is out or queued, gather = plant gatherers added); BUG-030 rebuild policy: id
    # bridge_rebuild names the bridge, its losses (n), those with building destroyers in sight (bd), rebuilds (reb), the
    # items of the lost bridges and their material, the lever links queued after a loss, the destroyer races, the loss
    # years, perimeter.stop_after
    # BUG-042: drink_low adds drink (days), block (still, brew, unvalidated, plants, barrels, brewer) and auto (brew,
    # office, barrels, gather); manager_office names why the manager validates nothing (orders older than unval_days)
    "DECISION_NEEDED": ("A", "any", _d("id:s", "q:s food:i drink:i block:sa opts:sa auto:sa bridge:s n:i bd:i reb:i "
                                               "items:i mat:s links:i races:sa years:ia stop:i")),
    "PLAN_EXHAUSTED": ("A", "runner", _d(opt="phase:s year:i")),
    # Run 11: mat = why economy cannot make a seal's missing pieces ('no material for door: no rock, no logs');
    # walled = the seal doors quickfort refused (no wall beside them) that the runner planned as walls ('x,y,z')
    # BUG-037: park = days a project blocked for good stood before it was parked (its cancel command is in msg)
    # BUG-046: parts = the parts of a stalled build stage that wait (<= 3, joined by '; ': 'MetalsmithsForge x,y,z: job
    # 22236 suspended by buildingplan: waits for building material x1'); walled also lists the doors replaced by walls
    # (BUG-044)
    "PROJECT_BLOCKED": ("A", "runner", _d("proj:s", "tpl:s stage:s why:s ticks:i missing:sa retry:i mat:s walled:sa "
                                                    "park:i parts:s")),
    "YEAR_REVIEW": ("A", "kern", _d(opt="year:i")),
    # BUG-062: far = of them, the bodies lying in another walk group than the citizens' (corpse_far: no coffin helps)
    "GHOSTS": ("A", "care", _d(opt="ghosts:i corpses:i old:i units:ia causes:sa far:i")),
    # BUG-062 (Run 14: 163, then 284 of 287 tomb zones closed to citizens): closed = zones found closed, free = of them
    # unassigned (usable: over a usable coffin), owned = held by a dead citizen, inactive = switched off; opened = what
    # care opened, left = usable ones still closed; again_free / again_owned = zones care opened that are closed again
    # (no owner: DF or a plugin closed them; an owner: by_entomb of them care's own entomb); unburied citizens
    # BUG-064 (Run 13/14: 19 "toppled by" reports): what = the building as the report names it, by = the culprit's name in
    # the report, unit = his id (only when one citizen, ghost or recorded dead matches the name), ghost, stress = his
    # personality.stress and cat its category (0 worst .. 6; >= 50000 is 0), tantrum = a tantrum report named him first,
    # n = further buildings toppled by him since the last event, pos = the report's position
    # FR-74: the share of stressed citizens (pct) stood at care.stress_high for `days` game days; src = the sources named
    # ("ghosts 12", "deaths 30", "no beds 8", "toppled buildings 3"), deaths of the last year, ghosts, citizens
    "STRESS_HIGH": ("B", "care", _d("pct:i days:i", "src:sa deaths:i ghosts:i cit:i")),
    "BUILDING_TOPPLED": ("B", "care", _d("what:s by:s", "unit:i ghost:f stress:i cat:i tantrum:f n:i pos:p")),
    # churn = zones care freed that DF gave to another body since (freed / bad / stale / elsewhere: this run's frees by reason)
    "TOMBS_LOCKED": ("B", "care", _d(opt="closed:i free:i usable:i owned:i inactive:i opened:i left:i again_free:i "
                                         "again_owned:i by_entomb:i unburied:i churn:i freed:i bad:i stale:i elsewhere:i")),
    # BUG-031: cistern = why the nearest cistern room does not serve the hospital (no well, its well over 0/7, too far)
    "HOSPITAL_DRY": ("A", "water", _d("why:s", "patients:i zone:i near:i recipe:s cistern:s")),
    # BUG-034: the zones of a hospital without accepted water went while a patient was over water.patient_thirst: zones,
    # their locations, the patients over it (units, n, the top thirst), all patients, GiveWater jobs running then (give),
    # refused removals, and the nearest accepted source (src, d tiles) if any
    "HOSPITAL_REMOVED": ("A", "water", _d("zones:ia", "locs:ia units:ia n:i thirst:i patients:i give:i failed:i near:i "
                                                      "d:i src:p")),
    # BUG-054 (Run 11 y497: 5 patients dead of thirst at once, 4 caregivers): patients at water.dying_thirst (60,000):
    # units (thirstiest first), n, the top thirst, the caregivers (carers, the want, idle ones, added this run), the
    # hospital (ok, dry, none), GiveWater/GiveFood jobs running (give: citizens giving now, run/open on the job list,
    # -1 unknown), free buckets, the cause
    "PATIENT_DYING": ("A", "water", _d("units:ia n:i thirst:i carers:i want:i hosp:s",
                                       "idle:i added:i give:i open:i run:i buckets:i why:s")),
    # BUG-036 (Run 11 siege 9: 7 patients killed in their hospital beds in the BREACH): in SIEGE/BREACH, once per fight,
    # n of the patients lie outside the burrow the civ alert confines to (burrow; Kern+/Tiefe+ while it is silent):
    # units, all patients, mode, hosp_out = hospital zones outside Kern+ and the refuge
    "PATIENTS_OUT": ("B", "water", _d("n:i burrow:s", "patients:i units:ia mode:s hosp_out:i")),
    # BUG-040 (Run 11 y453: the cisterns y450s0b0/y452s1b0 were done, their wells never wet): a manifest cistern whose
    # built well stood dry for water.cistern_dry_days, once per dry spell: room, project, well (id, pos), days, fill
    # (pond: bucket-fed with its pond zone; pond_removed: water removed that pond as a loop; pipe: its floodgate lever;
    # none), pond (zone id), src/d (the nearest accepted water to carry from, tiles)
    "CISTERN_DRY": ("B", "water", _d("room:s days:i fill:s", "proj:s well:i pos:p pond:i src:p d:i")),
    # BUG-063: ws = the workshop type the mood claimed (-> MOOD_CRITICAL: pos = its first tile, name = the dwarf, nook = the
    # drink stockpile the kernel queued beside it or why none)
    "MOOD_RISK": ("A", "care", _d("unit:i why:s", "kind:s missing:sa thirst:i hunger:i nosrc:sa route:s ws:s")),
    "MOOD_CRITICAL": ("A", "care", _d("unit:i why:s", "kind:s thirst:i hunger:i ws:s name:s pos:p missing:sa nook:s")),
    # class A since Run 9 (an army walked in while these were digest-only): they wake at once
    "SIEGE_START": ("A", "siege", _d(opt="vis:i inv:i great:i why:s")),
    "INVASION": ("A", "threat", _d(opt="id:i")),
    # reflex (FR-36/49/51-53): arrival announcements, interrupts (INTERRUPTS) and the lockdown it applied; Run 11:
    # recall = citizens outside the alert's burrows when the lockdown's alert sounded (called home at once), rc_left =
    # those of them still outside; BUG-035: rc_new = citizens out of those burrows since who were not out then
    "ARRIVAL": ("A", "any", _d("kind:s", "src:s text:s raised:i doors:i alert:s clock:i out:i eta:i recall:i "
                                         "rc_left:i rc_new:i")),
    # Run 11: dist = tiles from the nearest citizen outside Kern+ or entrance (-1 unknown), far = beyond lockdown_near
    "INTRUDER": ("A", "reflex", _d(opt="n:i id:i pos:p k:s dist:i far:f")),
    "PREDATOR": ("A", "reflex", _d(opt="n:i id:i pos:p")),
    "NO_DEPOT": ("A", "reflex", _d(opt="text:s")),
    "LOCKDOWN": ("A", "reflex", _d("why:s", "n:i type:s raised:i doors:i alert:s clock:i out:i recall:i rc_left:i "
                                            "rc_new:i")),
    "ORDER_BAD": ("A", "economy", _d("order:i job:s", "dropped:f")),
    "DEPOT_MISSING": ("A", "trade", _d(opt="civ:s planned:f proj:s stalled:f why:s mat:s")),
    # BUG-021: unit/upos/grp = a cut-off citizen and his walk group, at/agrp = a stock tile of the class and its group
    "CUTOFF": ("A", "seal", _d("cls:s n:i", "pos:p why:s grp:i main:i unit:i upos:p at:p agrp:i")),
    # BUG-030 rebuild policy: wait = lost bridges built again only in quiet PEACE; BUG-048: replaced = bridges the keeper
    # replaced by a wall and a door (stop_after losses to building destroyers, vanish_after without one, a rebuild nobody
    # built; no question), held = legacy (the old kernel's DECISION_NEEDED bridge_rebuild)
    "PERIMETER_BROKEN": ("A", "seal", _d("n:i", "pos:p kinds:sa requeued:i why:s wait:sa held:sa replaced:sa")),
    "SEAL_LEAK": ("A", "seal", _d("routes:i", "pos:p bld:s state:s why:s")),
    # BUG-018/019, FR-67: level of the fallback (SIEGE, SOFT, HOLD, BREACH, DEAD), flee (no separated burrow: no
    # confinement), open (the entrances that reach the refused burrow, "x,y,z kind"); BUG-031: open = the tiles they
    # lead in by (also beside a door that leaves them open), fix = the seal template's `at` that closes them, dry = a
    # burrow was refused because the citizens it held went thirsty or hungry there
    # BUG-049 (Run 13 y525: the citizens found the refuge occupied): hostile = how many hostiles stand in the refused
    # burrow, at = where the first one stands
    "REFUGE_FAIL": ("A", "seal", _d("burrow:s", "fallback:s why:s tiles:i inside:i mode:s level:s flee:f open:sa "
                                                "fix:s dry:f hostile:i at:p")),
    "AUTOLABOR_LEGACY": ("A", "baseline", _d("fixed:f", "why:s after:s")),
    # FR-64: >= 2 citizens died of dehydration or starvation within a month (the class-A twin of DEATH_CLUSTER)
    "DEATHS_PREVENTABLE": ("A", "care", _CLUSTER),
    # FR-65: readiness R0 in PEACE: R1 blockers, the audit's own fails, ways in (seal), those without door or bridge;
    # Run 11: rdry = the refuge without drink and what to build (blocker refuge_dry)
    # BUG-036: hout = the hospital outside Kern+ and the refuge and what to do (blocker hospital_out)
    # FR-70: pd = game days the perimeter has been open (open_perimeter), pw = what is open; from escalate_days on the
    # wake repeats every escalate_every days. BUG-055: office = a vacant office (or squads without a leader) that blocks
    # (R0 `office`), with its fix
    "SIEGE_UNREADY": ("A", "readiness", _d(opt="fails:sa afails:sa routes:i open:i ents:sa traps:i age:i rdry:s "
                                               "hout:s pd:i pw:s office:s")),
    # BUG-015: an entrance door the lockdown forbade lost its forbidden flag before the next pass (refused)
    "LOCKDOWN_PARTIAL": ("A", "reflex", _d("doors:i", "refused:ia pos:p retry:f items:i units:i")),
    # BUG-023 / Run 10: tool detail members without their pick or axe while its jobs wait and free tools exist; Run 11:
    # forb = forbidden tools (no free one needed), blk/bk = the blockers' texts/keys of economy's diagnosis (labor,
    # tool2, alert, burrow, walk, jobs, pair, flag, pool, upair, fetch, pending, none), picks/units = compact records, civ =
    # the civ alert's burrows, ww = DF's work tool pairs
    # BUG-053: forbidden / off_group / owned (population level) join the keys; pile = the tool pile's state
    "TOOL_BLOCKED": ("A", "economy", _d("detail:s tool:s n:i", "members:ia jobs:i days:i free:i bins:i reserved:i "
                                                               "why:s who:s hint:s pos:p eq:i eq_days:i forb:i blk:s "
                                                               "bk:s picks:sa units:sa civ:i ww:i pile:s")),
    # BUG-027: a SIEGE/BREACH raise went ahead onto units on or next to the footprint (a hostile within force_near)
    "GATE_FORCED": ("A", "gate", _d("bridge:s", "units:ia hostile:i pos:p job:i")),
    # BUG-027: a unit died on or next to a bridge just pulled or moving (gate's move records, dfllm.deaths.bridge)
    "BRIDGE_CRUSH": ("A", "gate", _d("bridge:s unit:i", "bid:i pull:i t:i to:s how:s k:s pos:p")),
    # BUG-028: citizens cut off from drink/food by our raised gates; phase hold (a raise waits), forced (raised: a
    # hostile at the gate), rescue (inner/core bridges lowered), refused (no rescue: why), done, abort; BUG-031:
    # relax (the civ alert's burrow kept them from drink/food on their own walk group: seal refuses it now; burrow)
    "STRANDED": ("A", "siege", _d("phase:s", "n:i units:ia grp:i thirst:i hunger:i bridges:sa why:s need:s pos:p "
                                             "left:i hostile:i burrow:s")),
    # BUG-028: the main part of a drink or food stock lies outside Kern+ and the refuge; days = what lies inside
    "SUPPLY_OUTSIDE": ("A", "seal", _d("cls:s", "inside:i total:i pct:i days:i want:i hint:s also:s")),
    # Gordon 2026-10-16: an intake wave (kind intake) or a sortie through O1 (kind sortie) went wrong: why losses,
    # past_b1 (a hostile past B1), stuck (the field not clear in time), left_outside (O1 raised with members outside)
    "WAVE_FAIL": ("A", "siege", _d("kind:s why:s", "wave:i squad:s lost:i units:ia n:i pos:p ticks:i")),
    # BUG-030: a manifest bridge gate saw complete is gone from its footprint (destroyed or removed): no pulls for it
    # rebuild policy: n = its losses so far, bd = those with building destroyers in sight, destroyers = this one, races
    # BUG-064: tby = the citizen or ghost the reports "X toppled by <name>" named near its footprint (care.toppled), tunit
    # his id, tcat his stress category (0 worst), tghost a ghost
    "BRIDGE_DESTROYED": ("A", "gate", _d("bridge:s", "bid:i role:s last:s mode:s pos:p n:i bd:i destroyers:f "
                                                     "races:sa tby:s tunit:i tcat:i tghost:f")),
    # Run 11: a dig broke into a cavern: phase queued (the explore shaft's plug project), done (the wall stands), failed
    # (refused, cancelled, blocked), none (no automatic plug: by hand); shaft = its top tile, z1 its bottom z, walls
    # 'x,y,z' (the lower one first), n = water tiles of a cavern lake, hint = why failed / none; state = the explore's
    # state when the daily shaft check found the opening (running, stalled, blocked:<why>, breach:<why>, cancel, done,
    # cancelled; Run 11 c1a14676)
    "CAVERN_PLUG": ("A", "runner", _d("phase:s proj:s", "plug:s why:s pos:p shaft:p z1:i walls:sa n:i hint:s state:s")),
    # Run 11 siege 8 (seal first): an open seal or plug built nothing for runner seal_first.stuck_days: it stops pausing
    # the other projects; pieces = the first 6 open ones ('door x,y,z'), n = all open, mat = why economy cannot make
    # them, blocked = the project's block (build_lost ...); BUG-041: wait = why the first open piece waits, as far as the
    # kernel can tell ('FellTree at x,y,z: Wood cutting enabled for 0 of 26 citizens: nobody takes it', 'no citizen
    # reaches wall x,y,z or a tile beside it (walk groups 5018; citizens 7827)')
    "SEAL_STUCK": ("A", "runner", _d("proj:s", "tpl:s stage:s days:i n:i pieces:sa mat:s blocked:s wait:s")),
    # BUG-044 (Run 11 y483-y497, the seal door 115,73,143): a seal door still not built seal_first.wall_days after
    # SEAL_STUCK was replaced by a constructed wall on its tile (PEACE; the citizens keep another way: seal.opening_ways):
    # at = 'x,y,z', was = the piece (door), days = days it stood stuck, why = the SEAL_STUCK wait (the job and who
    # suspends it)
    "SEAL_WALLED": ("B", "runner", _d("proj:s at:s", "was:s days:i why:s")),
    # BUG-030: the siege's deep defense: why = destroyers (building destroyers in sight), army (> stations.core_ratio x
    # soldiers), weak (worn or iron/steel below stations.worn/metal); civilians to the separated refuge, squads at the core
    "SIEGE_DEEP": ("A", "siege", _d("why:sa", "bd:i races:sa units:ia vis:i soldiers:i worn:i metal:i refuge:s "
                                              "pos:p")),
    "ALERT_START": ("B", "siege", _d(opt="vis:i")),
    "ALERT_END": ("B", "siege", _d(opt="vis:i")),
    # Run 11: cause far (ended with hostiles in sight beyond reflex.lockdown_near; far names <= 3, nfar) or quiet
    "LOCKDOWN_END": ("B", "reflex", _d(opt="why:s ticks:i doors:i refused:i cause:s far:sa nfar:i")),
    # Run 10: a roofed wild danger on the citizens' group but beyond reflex.predator_near of every citizen (no lockdown)
    "PREDATOR_FAR": ("B", "reflex", _d("n:i id:i", "pos:p dc:i")),
    # Run 11 (siege 8: 16 citizens outside Kern+ at the arrival): the lockdown's recall; why done (all came in), late
    # (reflex.RECALL_MAX passed: the doors stop waiting), end (the lockdown ended first); n = outside at the alert,
    # left = still outside, ticks since the alert, units = those still out (<= 20), called = the alert really confined
    # (a burrow listed), burrow, eta = ticks of the nearest invader to an entrance then (-1 unknown). BUG-035 (Run 11
    # siege 9: 'recall: 9 of 5 still outside', two never came): burrow = the burrows it measures arrival in (the alert's,
    # 'Kern+/Tiefe+'), why stuck (once per lockdown: some of them cannot come; they hold no door), reasons =
    # 'id:key@x,y,z[/dN][/res]' per citizen still out, then per newcomer (reflex.NOHOLD keys: gone caged chained carried
    # mood down patient sleep puller:<room> burrow:<name> locked:<door> group path; others walk job:<type> away idle
    # door:<door> (opened again for him)), stuck = how many cannot come, pull = gate's lever pullers among them (never
    # counted as still out), nnew/newu = citizens out since who were not out at the alert (<= 20 ids)
    "RECALL": ("B", "reflex", _d("why:s n:i left:i ticks:i", "units:ia called:f burrow:s eta:i reasons:sa stuck:i "
                                                             "pull:i nnew:i newu:ia")),
    # Run 11 (siege 8: the refuge switched Tiefe+/Kern+ during the fight): the civ alert's burrow changed in SIEGE or
    # BREACH; why = breached (a hostile in it), unseparated (an opening reaches it), gone, dry (seal.dry: thirsty or
    # hungry there), window (a refuge without drink after refuge.breach_days), unreachable, deeper (to the refuge, away
    # from the entrances: BREACH or the deep defense); to '' = the alert off (no usable burrow)
    "REFUGE_SWITCH": ("B", "seal", _d("from:s to:s why:s mode:s", "level:s")),
    "MOOD_START": ("B", "care", _d(opt="unit:i kind:s need:s ok:f")),
    "MOOD_NEED": ("B", "care", _d(opt="unit:i kind:s need:s ok:f")),
    "MOOD_END": ("B", "care", _d(opt="unit:i kind:s need:s ok:f")),
    # BUG-016/026: why (failure reason), focus (blocked), ph/ph_ms/ph_act/ph_runs (the phase that ended the attempt: real
    # ms, ms on the module's own clock, runs), left (ticks the caravan still stays, -1 unknown)
    "CARAVAN": ("B", "trade", _d(opt="phase:s ratio:i civ:s why:s focus:s ph:s ph_ms:i ph_act:i ph_runs:i left:i")),
    "MIGRANTS": ("B", "economy", _d(opt="n:i")),
    "PETITION": ("B", "care", _d(opt="kind:s")),
    "STOCK_LOW": ("B", "economy", _d("key:s", "days:i min:i")),
    "CANCEL_LOOP": ("B", "economy", _d(opt="order:i job:s n:i")),
    "LABOR_STARVED": ("B", "economy", _d("labor:s", "cycles:i to:s")),
    "WORK_DETAIL": ("B", "economy", _d("detail:s unit:i on:i", "n:i why:s")),
    "CAPTURE": ("B", "care", _d(opt="unit:i race:s")),
    # Run 11: why damp|warm|water|cavern|cavern_lake; was = the reported why a look at the revealed tiles raised, n =
    # the connected water tiles counted; src report|tile|cancel|recheck|check (the daily shaft check stopped an explore
    # that was still digging; state = its state then: running, stalled, blocked:<why>)
    "BREACH_STOP": ("B", "runner", _d(opt="proj:s why:s pos:p src:s was:s n:i state:s")),
    "KERNEL_SLOW": ("B", "kern", _d("module:s", "ms:i factor:i task:s")),
    "WEALTH": ("B", "siege", _d(opt="created:i exported:i imported:i")),
    "DRILL_RESULT": ("B", "drill", _d(opt="pass:f raised:i worn:i outside:i dbl:i")),
    "READY_CHANGE": ("B", "readiness", _d(opt="from:i to:i fail:sa")),
    "POPCAP": ("B", "readiness", _d("cap:i", "why:s")),
    "AUDIT": ("B", "readiness", _d(opt="ok:f fails:sa min_traps:i")),
    "PROJECT_DONE": ("B", "runner", _d("proj:s", "tpl:s walled:sa")),       # Run 11: walled as PROJECT_BLOCKED
    "PROJECT_REQUEST": ("B", "any", _d("tpl:s", "n:i why:s bars:i short:i")),
    "PHASE": ("B", "runner", _d(opt="from:s to:s")),
    "PAUSE": ("B", "arbiter", _d("on:f", "by:s ttl:i")),
    "DEATH": ("B", "care", _d(opt="unit:i citizen:f cause:s src:s why:s found:f dtype:s by:s killer:i mood:s "
                                  "thirst:i hunger:i patient:f pos:p job:s revised:f bridge:s")),
    "DEATH_CLUSTER": ("B", "care", _CLUSTER),
    "ACT_FAIL": ("B", "kern", _d("fn:s", "err:s module:s")),
    # BUG-059: kind = workshop (a mandatory workshop is missing), worker (nobody holds the labor), input
    "ORDER_STUCK": ("B", "economy", _d("order:i job:s why:s", "n:i days:i dropped:f kind:s")),
    "JOBS_SUSPENDED": ("B", "economy", _d(opt="suspended:i released:i kept:i planned:i why:s resuspended:i "
                                              "forbidden:i other:i unforbidden:i missing:s blocked:i")),
    "TRADE_LEDGER": ("B", "trade", _d(opt="civ:s ok:f ratio:i sold:i sold_v:i bought:i bought_v:i unmet:sa")),
    "SEAL": ("B", "seal", _d(opt="routes:i pos:p why:s sealed:f")),
    "REACH": ("B", "seal", _d(opt="flags:sa cut:i stairs:i")),
    # Gordon 2026-10-16: intake waves (phase muster, open, close, clear, back, abort, refused) and the sortie through
    # O1 (phase gather, open, out, recall, close, done, abort, refused); why = the trigger or the refusal
    "INTAKE": ("B", "siege", _d("phase:s", "wave:i why:s inside:i size:i soldiers:i on_station:i worn:i lost:i "
                                           "killed:i traps:i armed:i ticks:i")),
    "SORTIE": ("B", "siege", _d("phase:s", "squad:s why:s units:ia n:i cv:i foes:i est:i worn:i lost:i pos:p "
                                           "ticks:i")),
    # BUG-032 (Run 11: a squad stationed next to B2 held its BREACH raise): military moved a squad station off a bridge
    # footprint and its ring (gate margin + stations.spread): why bridge (to the nearest revealed floor on the inner
    # side), chain (the next station of the posture's chain), none (nothing clear: kept), hold (soldiers at their
    # station held a raise: the squad re-stationed at once); station/first = chain entries, from/to positions, bridge
    # and d = the footprint that held it and its distance, squad/key/units for hold
    "STATION_MOVED": ("B", "military", _d("why:s", "station:s first:s from:p to:p bridge:s d:i squad:i key:s units:ia")),
    # Run 11: economy's glass chain for strange moods is blocked: why = no_sand (no revealed sand floor), no_bags (no
    # spare cloth/leather or shop for ConstructBag), no_fuel (no charcoal and no wood furnace or wood, no magma glass
    # furnace); raw/cut = the raw and cut glass wanted; once per set of blockers (util/cadence)
    "GLASS_BLOCKED": ("B", "economy", _d("why:sa", "raw:i cut:i")),
    # Run 11 (Kilrudrabed y432: 1 boulder, ~110 orders 'no rock'): pieces planned buildings wait for that nothing in the
    # fort can make (pieces 'door x1, wall x2'; why = the reasons 'no rock, no logs'; rock = free stone, logs, n = the
    # pieces); once per set of kinds and reasons (util/cadence)
    "MATERIAL_SHORT": ("B", "economy", _d("pieces:s why:sa", "n:i rock:i logs:i boulders:i")),
    # BUG-042: the manager's office zone without its chair/table (he validates no work order): what economy placed
    # (`placed` 'chair at x,y,z, table at x,y,z', the repair project) or why it could not
    "MANAGER_OFFICE": ("B", "economy", _d("zone:i why:s", "chair:i table:i placed:s proj:s")),
    # BUG-052: off = why soldiers are off their station ('equip 5, far 2': equip, hurt, level, far, nost)
    "SIEGE_STATUS": ("C", "siege", _d(opt="vis:i worn:i on_station:i deaths:i captures:i off:s")),
    "SEASON": ("C", "kern", _d(opt="year:i season:i")),
    "PROJECT_STAGE": ("C", "runner", _d("proj:s", "stage:s pct:i")),
    "MODE": ("C", "kern", _d("from:s to:s", "why:s")),
    "GATE": ("C", "gate", _d("bridge:s", "state:s units:ia")),
    "LEVER": ("C", "gate", _d("bridge:s", "lever:i job:i")),
    # BUG-043: margin = a default box's margin when it shrank ('8,8,1'), cols = its explore shaft columns, out/first =
    # the fort pieces an explicit audit box left out (readiness fails such an audit: `coverage: ...`)
    "SNAPSHOT_READY": ("C", "snapshot", _d("id:s path:s", "purpose:s margin:s cols:i out:i first:s")),
    "CMD": ("C", "kern", _d("id:s verb:s ok:f")),
    "BOOT": ("C", "kern", _d(opt="save:s v:i boots:i")),
    "UNLOAD": ("C", "kern", _d()),
}

# FR-53 interrupt types: a class-A subset written to <save>/alarm.txt at once; `dfllm wait --until-interrupt` returns
# on them and `dfllm ack` acknowledges them (unacked for reflex ack_timeout_s -> the kernel's lockdown default)
INTERRUPTS = ["ARRIVAL", "INTRUDER", "PREDATOR", "DEATHS_3PLUS", "NO_DEPOT"]

EVENT = Obj(req={"n": NAT, "tick": TICK, "type": Str(TYPE_RE), "cls": Str(enum=["A", "B", "C"]),
                 "msg": Str(maxbytes=200), "d": OPEN})

# ---------------------------------------------------------------- verbs
# FR-39: make-item jobs whose manager order must name the item def (lua/dfllm/orderlib.lua O.SUBTYPE_JOBS)
SUBTYPE_JOBS = frozenset({"MakeArmor", "MakePants", "MakeShoes", "MakeGloves", "MakeHelm", "MakeWeapon", "MakeAmmo",
                          "MakeShield", "MakeTrapComponent", "MakeTool", "MakeToy"})
VERB_ARGS: dict[str, Obj] = {
    "plan.reload": Obj(opt={"phases": Bool()}),
    "bp.place": Obj(req={"tpl": TPL, "site": Str(ID_RE)},
                    opt={"p": Obj(extra=SCALAR), "prio": Int(1, 7)}, extra=SCALAR),
    "bp.cancel": Obj(req={"proj": ID}, opt={"undo": Bool()}),
    "drill": Obj(opt={"why": Str(maxbytes=200)}),
    "snapshot": Obj(opt={"bbox": BBOX, "purpose": Str(enum=["audit", "sites", "debug"])}),
    "audit": Obj(req={"snap": ID, "ok": Bool(), "fails": Arr(Str(maxbytes=80), hi=50), "min_traps": NAT,
                      "bypass": Bool(), "refuge_sep": Bool(), "civ_sep": Bool(), "caverns": Bool()}),
    "popcap.lower": Obj(req={"cap": Int(0, 250)}),
    "tempo.lower": Obj(req={"fps": Int(10, 1000), "ttl_s": Int(1, 3600)}),
    "pause": Obj(req={"ttl_s": Int(1, 600)}, opt={"why": Str(maxbytes=200)}),
    "unpause": Obj(),
    "trade.want": Obj(opt={"want": Arr(TOKEN, hi=40), "sell": Arr(TOKEN, hi=40)}),
    "trade.retry": Obj(opt={"civ": Str(maxbytes=40), "want": Arr(TOKEN, hi=40), "sell": Arr(TOKEN, hi=40)}),
    # gate (Gordon 2026-10-16): a sortie through that outer bridge (siege: gather in the bailey, open, kill, recall)
    "squad.sortie": Obj(req={"squad": Str(enum=["A", "B", "C"]), "target": AnyOf(ID, POS),
                             "approve": Const(True)}, opt={"gate": BRIDGE}),
    "lever": Obj(req={"bridge": BRIDGE, "want": Str(enum=["up", "down"])}),
    "inspect": Obj(req={"what": Str(enum=["state", "modules", "census", "manifest", "projects", "persist",
                                          "perf", "mode", "plan", "tombs", "water_sources", "orders", "workload",
                                          "trade", "reach", "entrances", "defense", "perimeter", "refuge",
                                          "offices"])},
                   opt={"key": Str(maxbytes=80), "field": Str(r"^[A-Za-z0-9_]{1,40}$")}),
    "selftest": Obj(opt={"suite": Str(enum=["quick", "full"])}),
    "module.enable": Obj(req={"module": MODULE}),
    "tombs.repair": Obj(),
    "ack": Obj(opt={"n": NAT}),
    "order.add": Checked(Obj(req={"job": Str(r"^[A-Za-z]{2,40}$"), "amount": Int(1, 999)},
                             opt={"item_subtype": Str(r"^ITEM_[A-Z0-9_]{1,60}$"), "material": Str(r"^[A-Z0-9_:]{1,80}$"),
                                  "material_category": Arr(Str(r"^[a-z0-9_]{1,20}$"), lo=1, hi=8),
                                  "reaction": Str(r"^[A-Z0-9_]{1,60}$"),
                                  "frequency": Str(enum=["OneTime", "Daily", "Monthly", "Seasonally", "Yearly"])}),
                         lambda a: (f"{a['job']} needs item_subtype (ITEM_...): DF 53.16 crashes without one (FR-39)"
                                    if a["job"] in SUBTYPE_JOBS and "item_subtype" not in a else None),
                         "item-definition jobs need item_subtype (FR-39)"),
    "jobs.release": Obj(opt={"all": Bool(), "preventblocking": Bool()}),
    "perimeter.record": Obj(),
    # BUG-030 rebuild policy: the player's answer to DECISION_NEEDED bridge_rebuild: rebuild that bridge anyway
    "bridge.rebuild": Obj(req={"bridge": BRIDGE}),
    # BUG-055 (Run 11 note 25, Run 14 notes 61/64): the nobles screen (appoint) and the squads screen (create a squad,
    # choose its leader, add a soldier, give the kind's uniform) as verbs; a squad is a key A/B/C or the game's squad id
    "appoint": Obj(req={"code": Str(r"^[A-Z_]{3,40}$"), "unit": NAT}),
    "squad.create": Obj(req={"name": Str(r"^[A-Za-z0-9 _-]{1,30}$")}, opt={"leader": NAT, "assignment": NAT}),
    "squad.leader": Obj(req={"squad": SQUAD, "unit": NAT}),
    "squad.add": Obj(req={"squad": SQUAD, "unit": NAT}),
    "squad.uniform": Obj(req={"squad": Str(enum=["A", "B", "C"])}, opt={"kind": Str(enum=["melee", "xbow"])}),
    # FR-78 (Run 14 note 65): a civzone of `type` in `bbox` (one z level) through quickfort's zone mode
    "zone.place": Obj(req={"type": Str(enum=ZONE_TYPES), "bbox": BBOX}, opt={"name": Str(r"^[A-Za-z0-9_-]{1,24}$")}),
}
# verb -> (handler module, allowed modes or None, needs approve)
VERBS: dict[str, tuple[str, list[str] | None, bool]] = {
    "plan.reload": ("kern", None, False), "bp.place": ("runner", None, False),
    "bp.cancel": ("runner", None, False), "drill": ("drill", ["PEACE"], False),
    "snapshot": ("snapshot", None, False), "audit": ("readiness", None, False),
    "popcap.lower": ("readiness", None, False), "tempo.lower": ("arbiter", None, False),
    "pause": ("arbiter", None, False), "unpause": ("arbiter", None, False),
    "trade.want": ("trade", None, False), "trade.retry": ("trade", ["PEACE"], False),
    "squad.sortie": ("military", ["ALERT", "SIEGE", "BREACH", "RECOVERY"], True),
    "lever": ("gate", ["PEACE"], False), "inspect": ("kern", None, False),
    "selftest": ("selftest", None, False), "module.enable": ("kern", None, False),
    "tombs.repair": ("care", None, False),
    "ack": ("reflex", None, False),
    "order.add": ("economy", None, False), "jobs.release": ("economy", None, False),
    "perimeter.record": ("seal", None, False), "bridge.rebuild": ("seal", None, False),
    # BUG-055: office appointments any time; the squads screen only outside a fight
    "appoint": ("economy", None, False),
    "squad.create": ("military", SQUAD_MODES, False), "squad.leader": ("military", SQUAD_MODES, False),
    "squad.add": ("military", SQUAD_MODES, False), "squad.uniform": ("military", SQUAD_MODES, False),
    "zone.place": ("runner", SQUAD_MODES, False),
}
# verbs accepted only from these `by` origins (CONTRACTS §9.5; `by` is a label, the hook is the guard)
VERB_BY: dict[str, list[str]] = {"audit": ["follow", "test"]}

INBOX = Obj(req={"id": ID, "verb": Str(enum=list(VERBS)), "args": OPEN, "by": Str(enum=BY)},
            opt={"ts": NAT})
OUTBOX = Obj(req={"id": ID, "ok": Bool(), "msg": Str(maxbytes=300)},
             opt={"verb": Str(maxbytes=40), "tick": TICK, "data": OPEN})

# ---------------------------------------------------------------- state, heartbeat
STATE = Obj(
    req={"v": Const(V), "seq": NAT,
         "t": Obj(req={"y": NAT, "tick": Int(0, 403199), "season": Int(0, 3), "tps": NAT, "paused": Bool()},
                  opt={"abs": TICK, "wall": NAT, "frame": NAT}),
         "mode": MODE,
         # BUG-033: top = the top cost owner of the last minute, 'runner 35 (snapshot 20)'
         "k": Obj(req={"ms_s": NAT, "gap_max_ms": NAT, "slow": Arr(MODULE), "faults": NAT},
                  opt={"disabled": Arr(MODULE), "ms_max": NAT, "top": Str(maxbytes=40)}),
         "ev": NAT},
    opt={"save": Str(maxbytes=120), "phase": PHASE,
         "pop": Obj(opt={"cit": NAT, "adults": NAT, "soldiers": NAT, "cap": NAT, "gate_cap": NAT}),
         "ready": Obj(req={"lvl": Int(0, 3), "worn": PCT, "cv": NAT, "drill_age": Int(-1),
                           # BUG-043: why readiness' last audit request was refused; what the last audit covered
                           "audit": Obj(req={"ok": FLAG, "age": Int(-1), "min_traps": NAT},
                                        opt={"why": Str(maxbytes=80), "cov": Str(maxbytes=40)}),
                           "fail": Arr(Str(maxbytes=24), hi=8)},
                      # FR-65: ways in without door or bridge (-1 unknown), the first of them, why no auto drill;
                      # route: the last audit's first attacker-route finding (bypass / refuge on the attack path)
                      # FR-70: pd = game days the perimeter has been open in PEACE (open_perimeter), pw = what is open
                      opt={"open": Int(-1), "ents": Arr(Str(maxbytes=24), hi=3), "dhold": Str(maxbytes=24),
                           "route": Str(maxbytes=60), "pd": NAT, "pw": Str(maxbytes=60),
                           # BUG-055: the vacant office (or squad leader post) R0 `office` names, with its fix
                           "office": Str(maxbytes=200)}),
         # Run 10: ore/bars/leather stock, the metal route ('explore' = no ore, metal wanted), the classes strange
         # moods missed within a year (plan propose/check supply goals)
         # Run 11: free stone and what the open rock orders, walls and needs want (rock_need); picks in the fort and the
         # Miners' demand (pick_want): plan propose/check draft a stone dig and picks in trade.want
         "stock": Obj(opt={"drink_d": NAT, "food_d": NAT, "meals": NAT, "hosp_water": FLAG, "ore": NAT, "bars": NAT,
                           "leather": NAT, "metal": Str(maxbytes=24), "mood_miss": Arr(Str(maxbytes=12), hi=8),
                           "rock": NAT, "rock_need": NAT, "picks": NAT, "pick_want": NAT,
                           # Run 11: metal short for the soldiers (economy.metal: plan check's metal route gate) and the
                           # metal items marked for melting (the invaders' gear in the melt pile)
                           "mshort": FLAG, "melt": NAT,
                           # BUG-042: why the stills do not brew while drink is below the plan's target
                           "dwhy": Str(maxbytes=80),
                           # BUG-059: citizens past DF's "hungry" line (hunger_timer >= starve.hunger)
                           "hungry": NAT}),
         "care": Obj(req={"stressed_pct": PCT, "naked": NAT, "ghosts": NAT, "corpses_old": NAT,
                          "tombs_free": NAT, "moods": NAT},
                     # FR-61 coffin provisioner: wanted free coffins, missing slots, coffin items, open orders, project
                     opt={"coffins": Obj(req={"want": NAT, "short": NAT, "stock": NAT, "order": NAT,
                                              "proj": Str(maxbytes=40)}),
                          # FR-64: citizen deaths of the last season (100,800 ticks) by cause
                          "died": Obj(extra=NAT),
                          # BUG-062: tomb zones left closed to citizens by the last run (none counted as free tombs)
                          "tombs_locked": NAT,
                          # FR-74: stressed citizens by source, deaths of the last year by cause, the population split
                          # and record (kids: children and babies; res: residents; waves/mig/dy: the last year; lastw:
                          # days since the last migrant wave, -1 none seen)
                          "src": Obj(extra=NAT), "died_y": Obj(extra=NAT),
                          "pop": Obj(req={"kids": NAT, "res": NAT, "peak": NAT, "dy": NAT, "waves": NAT, "mig": NAT,
                                          "lastw": Int(-1)})}),
         "labor": Obj(req={"starving": NAT, "idle": PCT}),
         # BUG-042: unvalidated live orders, the days the oldest waits, why the manager validates nothing
         "orders": Obj(req={"n": NAT, "bad": NAT, "stuck": NAT},
                       # BUG-059: of the stuck orders, how many miss a workshop (which, most missed first), a worker
                       opt={"unval": NAT, "uval_d": NAT, "mgr": Str(maxbytes=80), "stuck_ws": NAT, "stuck_lab": NAT,
                            "ws": Str(maxbytes=60), "jam": Str(maxbytes=80)}),
         "threat": Obj(req={"vis": NAT, "armed": FLAG}),
         "proj": Arr(Tup([ID, Str(maxbytes=24), PCT, Str(maxbytes=40)]), hi=8),
         # Run 11 siege 8: seal first (the leading open seal or plug: pieces open, projects it pauses, other open seals,
         # stuck 1 = it built nothing for stuck_days, days) and the rebuild policy (citizens, its bounds, projects paused)
         "sched": Obj(opt={"seal": Obj(req={"proj": ID, "n": NAT, "paused": NAT},
                                       opt={"more": NAT, "stuck": FLAG, "days": NAT}),
                           "rb": Obj(req={"pop": NAT, "lo": NAT, "paused": NAT}, opt={"hi": NAT}),
                           # BUG-037: projects waiting for a slot and the slot holders (id, template, days without own
                           # progress); no run ended for d days (the run in hand: task i of n, its label, slices, age
                           # in days); parked projects (blocked for good past runner queue.park_days)
                           "q": Obj(req={"n": NAT, "by": Arr(Tup([ID, Str(maxbytes=16), NAT]), hi=8)}),
                           "run": Obj(req={"d": NAT}, opt={"i": NAT, "n": NAT, "task": Str(maxbytes=40), "sl": NAT,
                                                           "age": NAT}),
                           "pk": NAT}),
         "bridges": Obj(extra=Str(enum=BRIDGE_STATES), keys=BRIDGE_RE),
         "owners": Obj(req={"pause": AnyOf(Null(), Str(enum=["inbox", "gordon", "popup", "df"])),
                            "tempo": Str(enum=["mode", "inbox", "brake", "clock"])}),
         "mil": Obj(req={"squads": NAT, "soldiers": NAT, "worn": PCT, "cv": NAT, "metal_pct": PCT,
                         "on_station": NAT},
                    opt={"free": Obj(opt={k: NAT for k in ("weapon", "body", "head", "pants", "gloves", "shoes",
                                                           "shield", "ammo")}),
                         # Run 11: the melee squads follow the gear (military.gear_fill): sets, melee filled to, melee
                         # wanted, crossbow positions added while metal is short
                         "cap": Obj(req={"sets": NAT, "melee": NAT, "want": NAT, "xbow": NAT})}),
         "trade": Obj(req={"caravan": FLAG, "ratio": NAT, "done": NAT}),
         # FR-51 clock governor (arbiter): the vanilla FPS cap it drives, the captured original, timestream fps
         "clock": Obj(req={"cap": NAT, "orig": NAT, "ts": Int(-1, 1000), "held": FLAG, "why": Str(maxbytes=24)}),
         # FR-53 interrupt channel (reflex): DEFCON 1 (worst) .. 5, unacked interrupts, last/acked event n
         "alarm": Obj(req={"defcon": Int(1, 5), "unacked": NAT, "last": NAT, "ack": NAT, "lock": FLAG,
                           "why": Str(maxbytes=24)}, opt={"eta": Int(-1), "doors": NAT, "dwait": NAT, "dout": NAT,
                                                       # Run 11: hostiles whose lockdown expired far
                                                       "dref": NAT, "far": NAT,
                                                       # BUG-035: the open recall (called, still out of rto,
                                                       # left since, cannot come)
                                                       "rn": NAT, "rleft": NAT, "rnew": NAT, "rstuck": NAT,
                                                       "rto": Str(maxbytes=24)}),
         # FR-55 lever latency (gate): last pull -> wanted state, in s and ticks (-1 never); pending own pulls
         "lever": Obj(req={"lat_s": Int(-1), "lat_t": Int(-1), "pend": NAT, "wait_s": NAT}),
         "alert": Obj(req={"want": Str(maxbytes=24), "burrow": Str(maxbytes=24), "tiles": NAT, "inside": NAT,
                           "ok": FLAG}, opt={"why": Str(maxbytes=40), "core_d": NAT, "core_f": NAT,
                                             # Run 10: the refuge burrow (Tiefe+): exists, separated (1, 0 an
                                             # opening reaches it, -1 not known yet), beds, beds wanted (bed_pct)
                                             "ref": Obj(req={"ex": FLAG, "sep": Int(-1, 1), "beds": NAT,
                                                             "need": NAT},
                                                        # BUG-040: where it lies (bbox of its tiles) and how far its
                                                        # nearest tile is from the nearest accepted source ws (-1:
                                                        # none)
                                                        opt={"box": Tup([INT] * 6), "wd": Int(-1),
                                                             "ws": Tup([NAT, NAT, NAT]),
                                                             # FR-69: drink units on its tiles, drink wanted
                                                             # (citizens x drink_per_cit), tiles of its drink store
                                                             # (stockpiles dfllm-drink on it; 0 none)
                                                             "dr": NAT, "dn": NAT, "st": NAT,
                                                             # BUG-049: trusted (1) or not (0) and the first reason
                                                             # (separation fresh, hatch stands, nobody inside)
                                                             "tr": FLAG, "trw": Str(maxbytes=40)})}),
         # intake waves (siege, Gordon 2026-10-16): phase, waves so far, the last refusal, the sortie (squad phase)
         # BUG-030: deep = the deep defense's reasons ("destroyers,army,weak")
         "wave": Obj(req={"ph": Str(maxbytes=8), "n": NAT}, opt={"why": Str(maxbytes=40), "so": Str(maxbytes=24),
                                                                 "deep": Str(maxbytes=24)}),
         # BUG-033: the snapshot export queue: requests waiting (the running one included), the oldest one's age (s),
         # exports written and requests dropped this boot; the running (else the first waiting) export: id, purpose,
         # who asked, progress, why it waits ('busy trade', 'paced 3 min', 'not started 2 min')
         "snap": Obj(req={"q": NAT, "old_s": NAT, "done": NAT, "drop": NAT},
                     opt={"run": ID, "p": Str(enum=["audit", "sites", "debug"]), "by": Str(maxbytes=24), "pct": PCT,
                          "wait": Str(maxbytes=24)}),
         # water (BUG-034): patients, their max thirst, the hospital served (flag) and its zones (hosp), the refuge's
         # well, free buckets, the accepted sources (a well over water, a Water Source zone on water >= 4/7) nearest
         # to the hospital (else the citizens) first: plan propose/check allow a hospital only within `near` of one
         "water": Obj(req={"patients": NAT, "thirst_max": NAT, "hosp_ok": FLAG, "refuge_ok": FLAG,
                           "buckets_free": NAT, "hosp": NAT, "src": Arr(Tup([NAT, NAT, NAT]), hi=8)},
                      # BUG-036: hospital zones with tiles outside Kern+ and the refuge (readiness R0 hospital_out);
                      # BUG-040: src_l = a label per src ('well 19098 in Kern+': kind, id, the burrow it is on)
                      opt={"hosp_out": NAT, "src_l": Arr(Str(maxbytes=32), hi=8)})})

HEARTBEAT = Obj(req={"v": Const(V), "wall": NAT, "frame": NAT, "tick": TICK, "paused": Bool(), "mode": MODE,
                     "seq": NAT})

# ---------------------------------------------------------------- plan, phases
BUILD = Obj(req={"tpl": TPL, "site": Str(ID_RE)}, opt={"p": Obj(extra=SCALAR), "prio": Int(1, 7)})
LIBS = Arr(Str(enum=ORDER_LIBS), hi=len(ORDER_LIBS))
PLAN = named("plan", Obj(
    req={"v": Const(V), "year": NAT,
         "policy": Obj(req={"option": Str(enum=["A", "B"]), "pop_ceiling": Int(0, 250),
                            "beauty": Str(enum=["none", "used_rooms"])}),
         "phase_target": PHASE,
         "seasons": Arr(Obj(req={"build": Arr(BUILD, hi=20)},
                            opt={"orders": Obj(req={"import": LIBS}), "notes": Str(maxbytes=500)}), 4, 4)},
    opt={"military": Obj(req={"pct": Int(0, 50), "squads": Obj(req={"melee": Int(0, 4), "xbow": Int(0, 2)}),
                              "cv_min": Int(0, 200)}),
         "supply": Obj(req={"drink_d": NAT, "food_d": NAT, "mood_stock": NAT}),
         "orders": Obj(req={"import": LIBS}),
         "trade": Obj(req={"want": Arr(TOKEN, hi=40), "sell": Arr(TOKEN, hi=40)}),
         "notes": Str(maxbytes=2000)}))
PLAN_DEFAULTS = {"military": {"pct": 15, "squads": {"melee": 2, "xbow": 1}, "cv_min": 12},
                 "supply": {"drink_d": 170, "food_d": 60, "mood_stock": 10},
                 "orders": {"import": []}, "trade": {"want": [], "sell": []}, "notes": ""}

DELIVER_KEYS = {"baseline": [], "proj": ["tpl"], "squads": ["n"], "drill": [], "workshops": ["types"],
                "stock": ["key", "min"], "orders": ["lib"], "trade": ["n"], "ready": ["lvl"],
                "metal": ["pct"], "bolts": ["n"]}


def _deliver_check(d):
    missing = [k for k in DELIVER_KEYS[d["k"]] if k not in d]
    return f"deliverable {d['k']} needs {missing}" if missing else None


DELIVERABLE = Checked(Obj(req={"k": Str(enum=list(DELIVER_KEYS))},
                          opt={"tpl": TPL, "stage": NAT, "n": NAT, "types": Arr(Str(maxbytes=40), lo=1, hi=20),
                               "key": Str(maxbytes=40), "min": NAT, "lib": Str(enum=ORDER_LIBS),
                               "lvl": Int(0, 3), "pct": PCT}),
                      _deliver_check, "per-kind required keys: see CONTRACTS §9.9")
PHASES = named("phases", Obj(req={"v": Const(V), "kind": Const("phases"),
                                  "phases": Arr(Obj(req={"id": PHASE, "title": Str(maxbytes=80), "approve": Bool(),
                                                         "deliver": Arr(DELIVERABLE, hi=32)}), 1, 16)}))

# ---------------------------------------------------------------- manifest
MANIFEST = named("manifest", Obj(
    req={"v": Const(V)},
    opt={"bridges": Obj(extra=Checked(Obj(req={"role": Str(enum=["outer", "inner", "core"]), "fp": BBOX,
                                              "levers": Arr(POS, 1, 4)}),
                                      lambda b: None if b["fp"][2] == b["fp"][5] else "bridge fp must be one z level",
                                      "bridge footprint on one z"), keys=BRIDGE_RE),
         # field (killing field station of a wave, else the first killbox's centre), bailey (sortie gathering point,
         # else the centre of the first Z1 box): Gordon 2026-10-16; core (BUG-030: the deep defense's station on the
         # core level next to the civilians' stair, else b2)
         "stations": Obj(opt={"melee": POS, "gallery": POS, "b2": POS, "field": POS, "bailey": POS, "core": POS}),
         "killboxes": Arr(Obj(req={"id": ID, "bbox": BBOX}), hi=20),
         "burrows": Obj(extra=Obj(req={"role": Str(enum=["kern", "refuge", "other"])}), keys=r"^.{1,40}$"),
         "edge": Arr(POS, hi=200),
         "refuge": Obj(req={"anchor": POS, "burrow": Str(maxbytes=40)}),
         "stairs": Obj(opt={"civ": Arr(Tup([INT] * 4), hi=8), "mil": Arr(Tup([INT] * 4), hi=8)}),
         "zones": Obj(opt={z: Arr(BBOX, hi=50) for z in ("Z1", "Z2", "Z3", "Z4")}),
         "rooms": Arr(Obj(req={"id": ID, "tpl": TPL, "use": Str(enum=["used", "utility"]), "bbox": BBOX,
                              "tier": NAT}), hi=200),
         "workshops": Arr(Obj(req={"type": Str(maxbytes=40), "pos": POS}), hi=100),
         # Run 11: tiles where a dig broke into a cavern (the runner's BREACH_STOP cavern/cavern_lake and shaft check):
         # the explore ranking keeps every shaft above their levels
         "caverns": Arr(POS, hi=32),
         "pit": POS, "depot": POS}))

# ---------------------------------------------------------------- blueprint project
CHUNK = Obj(req={"pos": POS, "cells": Arr(Tup([INT, INT, INT, Str(maxbytes=64)]), 1, 40)})
STAGE = Obj(req={"label": Str(r"^[a-z0-9][a-z0-9_.-]{0,23}$"),
                 "mode": Str(enum=["dig", "build", "place", "zone", "burrow"]),
                 "orders": FLAG, "defense": FLAG, "chunks": Arr(CHUNK, 1, 500)})


def _bp_check(b):
    labels = [s["label"] for s in b["stages"]]
    if len(set(labels)) != len(labels):
        return "stage labels must be unique"
    cells = sum(len(c["cells"]) for s in b["stages"] for c in s["chunks"])
    if cells > BP_MAX_CELLS:
        return f"{cells} cells > {BP_MAX_CELLS} (split the template into several projects)"
    size = len(json.dumps(b, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    if size > BP_MAX_BYTES:
        return f"{size} bytes of compact JSON > {BP_MAX_BYTES} (split the template into several projects)"
    return None


BP = Checked(Obj(req={"v": Const(V), "id": ID, "tpl": TPL, "site": Str(ID_RE),
                      "class": Str(enum=["defense", "infra", "living", "beauty"]),
                      "params": Obj(extra=SCALAR), "anchor": POS, "rot": Int(0, 3),
                      "stages": Arr(STAGE, 1, 64), "manifest": MANIFEST,
                      "materials": Obj(extra=NAT)}),
             _bp_check, f"unique stage labels; <= {BP_MAX_CELLS} cells, <= {BP_MAX_BYTES} bytes compact")

# ---------------------------------------------------------------- snapshot
TRAP = Tup([INT, INT, INT, Str(enum=TRAP_TYPES), NAT, FLAG], optional_tail=1)
_LEGEND_CLASS = "".join("\\" + c if c in "\\]^-" else c for c in SNAP_LEGEND)  # ECMA-262 safe
SNAPSHOT = Obj(req={"v": Const(V), "id": ID, "tick": TICK, "purpose": Str(enum=["audit", "sites", "debug"]),
                    "bbox": BBOX, "rows": Obj(extra=Arr(Str("^[" + _LEGEND_CLASS + "]*$")),
                                              keys=r"^z-?\d+$"),
                    "bridges": Obj(extra=Str(enum=BRIDGE_STATES), keys=BRIDGE_RE),
                    "traps": Arr(TRAP)},
               # BUG-043: a union export lists its parts (the main box first; tiles outside every part are " "), a
               # default box its margin (x, y, z)
               opt={"marks": Obj(extra=Arr(POS, hi=500), keys=r"^[a-z_]{1,20}$"),
                    "parts": Arr(BBOX, 1, 24), "margin": Tup([NAT, NAT, NAT])})


def _snapshot_post(doc: dict, out: list[str]) -> None:
    x0, y0, z0, x1, y1, z1 = doc["bbox"]
    w, h = x1 - x0 + 1, y1 - y0 + 1
    want = {f"z{z}" for z in range(z0, z1 + 1)}
    got = set(doc["rows"])
    for k in sorted(want - got):
        out.append(f"$.rows.{k}: missing")
    for k in sorted(got - want):
        out.append(f"$.rows.{k}: outside bbox")
    for k in sorted(got & want):
        rows = doc["rows"][k]
        if len(rows) != h:
            out.append(f"$.rows.{k}: {len(rows)} rows, expected {h}")
        for i, r in enumerate(rows):
            if len(r) != w:
                out.append(f"$.rows.{k}[{i}]: width {len(r)}, expected {w}")

# ---------------------------------------------------------------- misc files
RESTORE = Obj(req={"v": Const(V), "save": Str(maxbytes=120), "wall": NAT, "active": FLAG,
                   "orig": Obj(opt={"gfps": NAT, "autosave": Str(maxbytes=40), "visitor_cap": NAT,
                                    "population_cap": NAT, "timestream_fps": Int(-1), "weather": Bool(), "fps_cap": NAT,
                                    "overlays": Obj(extra=Bool())})})
LOCK = Obj(req={"holder": Str(maxbytes=40), "purpose": Str(maxbytes=200), "expires": NAT})
# <save>/quicksave.json (Python only, `dfllm save`, Run 10): the last quicksave attempt, verified by the save folder
QUICKSAVE = Obj(req={"v": Const(V), "wall": NAT, "ok": FLAG, "by": Str(enum=BY), "why": Str(maxbytes=200)},
                opt={"folder": Str(maxbytes=120), "secs": NAT, "last": Str(maxbytes=120), "last_age": Int(-1),
                     "fails": NAT, "paused": FLAG})
ALLOWLIST = Obj(req={"v": Const(V),
                     "commands": Obj(extra=Obj(req={"rw": Str(enum=["r", "w"]),
                                                    "args": Arr(Str(maxbytes=200), hi=50)}),
                                     keys=r"^[a-z0-9][a-z0-9/_-]{0,40}$"),
                     "blocked": Arr(Str(maxbytes=60)), "armok_exceptions": Arr(Str(maxbytes=60))})

PERSIST_MARKER = Obj(req={"v": Const(V), "adopted": TICK, "save": Str(maxbytes=120), "fort": Str(maxbytes=120),
                          "acceptance": FLAG, "baseline": FLAG, "boots": NAT})
PERSIST_PROJECTS = Obj(req={"v": Const(V), "list": Arr(Obj(req={
    "id": ID, "tpl": TPL, "site": Str(ID_RE), "class": Str(enum=["defense", "infra", "living", "beauty"]),
    "prio": Int(1, 7), "stage": NAT, "chunk": NAT, "pct": PCT, "blocked": Str(maxbytes=40), "since": TICK,
    "created": TICK, "done": FLAG, "orders_done": FLAG}), hi=64)})
PERSIST_PLAN = Obj(req={"v": Const(V), "plan": AnyOf(Null(), PLAN), "phases": AnyOf(Null(), PHASES),
                        "loaded": TICK})
PERSIST_PHASE = Obj(req={"v": Const(V), "phase": PHASE, "since": TICK, "done": Arr(PHASE, hi=8)})
PERSIST_MODE = Obj(req={"v": Const(V), "mode": MODE, "since": TICK, "why": Str(maxbytes=200), "prev": MODE})
PERSIST_DRILL = Obj(req={"v": Const(V), "streak_fail": NAT, "last": Arr(Obj(req={
    "tick": TICK, "pass": FLAG, "raised": Int(-1), "worn": PCT, "outside": NAT, "dbl": NAT,
    "fails": Arr(Str(maxbytes=40), hi=20)}), hi=5)})
PERSIST_KERN = Obj(req={"v": Const(V), "ev": NAT, "seq": NAT, "boots": NAT, "disabled": Arr(MODULE)})

SCHEMAS: dict[str, Spec] = {
    "state": STATE, "heartbeat": HEARTBEAT, "event": EVENT, "inbox": INBOX, "outbox": OUTBOX,
    "plan": PLAN, "phases": PHASES, "bp": BP, "manifest": MANIFEST, "snapshot": SNAPSHOT,
    "restore": RESTORE, "lock": LOCK, "allowlist": ALLOWLIST, "quicksave": QUICKSAVE,
    "persist.marker": PERSIST_MARKER, "persist.projects": PERSIST_PROJECTS, "persist.plan": PERSIST_PLAN,
    "persist.phase": PERSIST_PHASE, "persist.mode": PERSIST_MODE, "persist.drill": PERSIST_DRILL,
    "persist.kern": PERSIST_KERN,
}
KINDS = list(SCHEMAS)


# ---------------------------------------------------------------- public API
def validate_args(verb: str, args: Any) -> list[str]:
    if verb not in VERB_ARGS:
        return [f"$.verb: unknown verb {verb!r}"]
    out: list[str] = []
    VERB_ARGS[verb].errors(args, "$.args", out)
    return out


def validate_event_d(etype: str, d: Any) -> list[str]:
    out: list[str] = []
    EVENTS[etype][2].errors(d, "$.d", out)
    return out


def validate(kind: str, doc: Any, strict: bool = True) -> list[str]:
    """Errors for doc as `kind` ([] = valid). strict=False tolerates unknown event types."""
    if kind not in SCHEMAS:
        raise KeyError(f"unknown kind {kind!r}; kinds: {KINDS}")
    out: list[str] = []
    SCHEMAS[kind].errors(doc, "$", out)
    if out:
        return out
    if kind == "event":
        et = EVENTS.get(doc["type"])
        if et is None:
            if strict:
                out.append(f"$.type: unknown event type {doc['type']!r}")
        else:
            if doc["cls"] != et[0]:
                out.append(f"$.cls: {doc['type']} is class {et[0]}, got {doc['cls']}")
            out.extend(validate_event_d(doc["type"], doc["d"]))
    elif kind == "inbox":
        if doc["verb"] in VERB_BY and doc["by"] not in VERB_BY[doc["verb"]]:
            out.append(f"$.by: {doc['verb']} is accepted only from {VERB_BY[doc['verb']]}")
        out.extend(validate_args(doc["verb"], doc["args"]))
    elif kind == "snapshot":
        _snapshot_post(doc, out)
    return out


def prune_state(doc: Any) -> tuple[dict | None, list[str]]:
    """Reader rule of CONTRACTS §9.3: drop optional top-level keys that have errors.
    Returns (doc without them, all errors), or (None, errors) when a required key is invalid."""
    errs = validate("state", doc)
    if not errs:
        return doc, errs
    if not isinstance(doc, dict):
        return None, errs
    bad = set()
    for e in errs:
        m = re.match(r"^\$\.([^.\[:]+)", e)
        if not m or m.group(1) in STATE.req:
            return None, errs
        bad.add(m.group(1))
    return {k: v for k, v in doc.items() if k not in bad}, errs


def check(kind: str, doc: Any, strict: bool = True) -> Any:
    errs = validate(kind, doc, strict)
    if errs:
        raise SchemaError(kind, errs)
    return doc


def json_schema(kind: str) -> dict:
    """JSON Schema (2020-12) for a kind or for 'inbox.args.<verb>'."""
    if kind.startswith("inbox.args."):
        spec = VERB_ARGS[kind[len("inbox.args."):]]
    else:
        spec = SCHEMAS[kind]
    defs: dict = {}
    d = {"$schema": "https://json-schema.org/draft/2020-12/schema", "title": kind}
    d.update(spec.js(defs))
    if defs:
        d["$defs"] = defs
    return d


def inbox_name(cmd_id: str, ts_ms: int) -> str:
    if not re.fullmatch(ID_RE, cmd_id):
        raise ValueError(f"bad command id {cmd_id!r}")
    return f"{int(ts_ms):013d}-{cmd_id}.json"


_DECISION_LINE = re.compile(r"^(D-[0-9][0-9])[ \t]*:[ \t]*([^#]*?)[ \t]*(#.*)?$")


def parse_decisions(text: str) -> dict[str, str]:
    """Flat `D-NN: value  # comment` lines (CONTRACTS §9.16), exactly like contract.parse_decisions:
    strip a BOM, split on LF, strip spaces/tabs/CR at both ends, match; empty values are skipped,
    a later line wins. Other lines are ignored."""
    if text.startswith("﻿"):
        text = text[1:]
    out: dict[str, str] = {}
    for line in text.split("\n"):
        m = _DECISION_LINE.match(line.strip(" \t\r"))
        if m and m.group(2):
            out[m.group(1)] = m.group(2)
    return out


def decision(did: str, decisions: dict[str, str] | None = None) -> str:
    if did not in DECISIONS:
        raise KeyError(f"unknown decision {did!r}")
    return (decisions or {}).get(did, DECISIONS[did])


APPENDIX_KINDS = ["state", "event", "inbox", "outbox", "plan", "manifest", "snapshot"]


def digest() -> str:
    """sha256 over every schema and registry; CONTRACTS.md records it (freeze guard)."""
    import hashlib
    blob = {"schemas": {k: json_schema(k) for k in KINDS + [f"inbox.args.{v}" for v in VERB_ARGS]},
            "events": {k: [c, b, v.js({})] for k, (c, b, v) in EVENTS.items()},
            "verbs": VERBS, "verb_by": VERB_BY, "kern": KERN, "bp_max": [BP_MAX_CELLS, BP_MAX_BYTES], "act": ACT, "modules": MODULES, "modes": MODES, "transitions": TRANSITIONS,
            "decisions": DECISIONS, "legend": SNAP_LEGEND, "state_owners": STATE_OWNERS, "persist": PERSIST,
            "postures": POSTURES, "mode_setters": MODE_SETTERS, "interrupts": INTERRUPTS}
    return hashlib.sha256(json.dumps(blob, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def appendix() -> str:
    """Markdown block for CONTRACTS.md Appendix A (deterministic)."""
    parts = [f"Contract digest: `{digest()}`",
             "",
             "DESIGN §6 formats and the inbox verb args. Other kinds: `python -m dfpilot.schema "
             f"--json-schema <kind>` with kind in {', '.join(k for k in KINDS if k not in APPENDIX_KINDS)}. "
             "Per-type event `d` (§12) and per-verb `args` are checked by `validate()`; the envelopes leave "
             "them open. Compact JSON, keys sorted."]
    for kind in APPENDIX_KINDS + [f"inbox.args.{v}" for v in VERB_ARGS]:
        parts.append(f"\n**{kind}**\n```json\n{json.dumps(json_schema(kind), sort_keys=True, separators=(',', ':'))}"
                     "\n```")
    return "\n".join(parts) + "\n"


def write_appendix(path: str) -> bool:
    """Replace the block between the GENERATED SCHEMAS markers in CONTRACTS.md. True if changed."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    begin, end = "<!-- BEGIN GENERATED SCHEMAS -->\n", "<!-- END GENERATED SCHEMAS -->"
    i, j = text.index(begin) + len(begin), text.index(end)
    new = text[:i] + appendix() + text[j:]
    if new != text:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
    return new != text


def _main(argv: list[str]) -> int:
    if argv[:1] == ["--appendix"]:
        sys.stdout.write(appendix())
        return 0
    if argv[:1] == ["--write-appendix"] and len(argv) == 2:
        print("updated" if write_appendix(argv[1]) else "unchanged")
        return 0
    if argv[:1] == ["--json-schema"] and len(argv) == 2:
        print(json.dumps(json_schema(argv[1]), indent=1, sort_keys=True))
        return 0
    if len(argv) == 3 and argv[0] == "validate":
        kind, path = argv[1], argv[2]
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
        docs = [json.loads(x) for x in text.splitlines() if x.strip()] if path.endswith(".jsonl") else [json.loads(text)]
        bad = 0
        for i, d in enumerate(docs):
            for e in validate(kind, d):
                bad += 1
                print(f"{path}:{i + 1}: {e}")
        print(f"{len(docs)} document(s), {bad} error(s)")
        return 1 if bad else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
