"""v2 file-format validators (stdlib only). Normative spec: docs/v2/CONTRACTS.md.

    validate(kind, doc) -> list[str]      # [] = valid
    check(kind, doc) -> doc               # raises SchemaError
    validate_args(verb, args) -> list[str]
    prune_state(doc) -> (doc | None, errs) # reader rule: drop invalid optional top-level keys
    json_schema(kind) -> dict             # JSON Schema (draft 2020-12) of the envelope

CLI: python -m df_llm_helper.schema validate <kind> <file>   (events.jsonl: every line)
     python -m df_llm_helper.schema --appendix | --json-schema <kind> | --write-appendix docs/v2/CONTRACTS.md
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
    "SIEGE": ["BREACH", "RECOVERY"], "BREACH": ["RECOVERY"],
    "RECOVERY": ["PEACE", "ALERT", "SIEGE", "BREACH"], "DRILL": ["PEACE", "ALERT", "SIEGE"],
}
MODE_SETTERS = {"siege": "*", "drill": ["DRILL>PEACE", "PEACE>DRILL"]}
POSTURES = ["TRAIN", "STATION_B1", "READY_STATION", "B2_HOLD"]
BRIDGE_STATES = ["up", "down", "moving", "unknown"]
ORDER_LIBS = ["library/basic", "library/furnace", "library/smelting", "library/military",
              "library/rockstock", "library/glassstock"]
SNAP_LEGEND = "?_.#SCF<>Xrv+=H^Bw~%T"
TRAP_TYPES = ["W", "S", "C", "P", "X"]
BY = ["llm", "gordon", "cli", "follow", "supervise", "test"]

# name, wp, critical, every (contract.MODULES, dispatch order)
MODULES = [
    ("sense", "WP5", True, {"ticks": 10}), ("threat", "WP5", True, {"ticks": 25}),
    ("siege", "WP5", True, {"ticks": 25}), ("gate", "WP5", True, {"ticks": 25}),
    ("military", "WP6", False, {"ticks": 3600}), ("drill", "WP6", False, {"ticks": 600}),
    ("readiness", "WP6", False, {"ticks": 33600}), ("arbiter", "WP1", True, {"ms": 500}),
    ("runner", "WP7", False, {"ticks": 600}), ("snapshot", "WP7", False, {"ticks": 100}),
    ("economy", "WP8", False, {"ticks": 1200}), ("care", "WP8", False, {"ticks": 1200}),
    ("trade", "WP9", False, {"ticks": 100}), ("baseline", "WP8", False, {"ticks": 33600}),
    ("perf", "WP1", False, {"ms": 1000}), ("selftest", "WP1", False, {"ms": 60000}),
]

DECISIONS = {
    "D-01": "A", "D-02": "unchanged", "D-03": "rule", "D-04": "off", "D-05": "off", "D-06": "off",
    "D-07": "unchanged", "D-08": "dropped", "D-09": "no", "D-10": "off", "D-11": "accepted",
    "D-12": "15/20", "D-13": "no",
}

ACT = {
    "set_paused": ["arbiter"], "timestream": ["arbiter"], "setting": ["arbiter"], "overlay": ["arbiter"],
    "dismiss_popup": ["arbiter"], "civ_alert": ["siege"], "alert_burrows": ["siege"],
    "squad_create": ["military"], "squad_leader": ["military"], "squad_add": ["military"],
    "squad_remove": ["military"],
    "squad_routine": ["military"], "squad_order": ["military"], "squad_uniform": ["military"],
    "pull": ["gate"], "cancel_own_lever_job": ["gate"], "popcap": ["readiness"], "quickfort": ["runner"],
    "orders_import": ["economy"], "orders": ["economy"], "workorder": ["economy"],
    "order_suspend": ["economy"], "kitchen_exclude": ["economy"], "item_flag": ["care"],
    "zone_assign": ["care"], "trade": ["trade"],
    "run": ["baseline", "economy", "care", "military", "trade", "arbiter", "selftest", "runner"],
}

STATE_OWNERS = {
    "v": "kern", "seq": "kern", "ev": "kern", "t.*": "kern", "mode": "kern", "save": "kern", "k.*": "kern",
    "phase": "runner", "proj": "runner",
    "pop.cit": "sense", "pop.adults": "sense", "pop.soldiers": "sense",
    "pop.cap": "readiness", "pop.gate_cap": "readiness", "ready.*": "readiness",
    "stock.drink_d": "economy", "stock.food_d": "economy", "stock.meals": "economy",
    "stock.hosp_water": "care", "care.*": "care", "labor.*": "economy",
    "threat.*": "threat", "bridges": "gate", "owners.*": "arbiter", "mil.*": "military", "trade.*": "trade",
}

# kernel fault and slowness rules (CONTRACTS §3.3.5-3.3.6), mirrors contract.KERN
KERN = {
    "fault_n": 3, "fault_window_ms": 600000,
    "backoff_ms": {"critical": 30000, "other": 600000}, "backoff_max_ms": {"critical": 480000, "other": 3600000},
    "backoff_reset_ms": 3600000,
    "slow_ms": 5, "slow_n": 3, "slow_window_ms": 600000, "promote_ms": 600000, "max_factor": 8,
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
MODULE = named("module", Str(MODULE_RE))
MODE = named("mode", Str(enum=MODES))
PHASE = named("phase", Str(PHASE_RE))
POS = named("pos", Tup([INT, INT, INT]))
SCALAR = named("scalar", AnyOf(INT, Str(maxbytes=200), Bool()))
TOKEN = named("token", Str(TOKEN_RE))


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


# type -> (cls, by, d spec)
EVENTS: dict[str, tuple[str, str, Obj]] = {
    "SIEGE_END": ("A", "siege", _d(opt="hostiles:i killed:i lost:i captures:i sealed_ticks:i")),
    "GATE_FAIL": ("A", "gate", _d("bridge:s", "want:s why:s")),
    "BREACH": ("A", "siege", _d("why:s", "bridge:s")),
    "DEATHS_3PLUS": ("A", "care", _d(opt="n:i ids:ia")),
    "DRILL_FAIL": ("A", "drill", _d(opt="streak:i fails:sa")),
    "KERN_FAULT": ("A", "kern", _d("module:s", "err:s n:i backoff_s:i")),
    "PERF_DEGRADED": ("A", "perf", _d(opt="tps:i base:i pct:i why:s")),
    "DECISION_NEEDED": ("A", "any", _d("id:s", "q:s")),
    "PLAN_EXHAUSTED": ("A", "runner", _d(opt="phase:s year:i")),
    "PROJECT_BLOCKED": ("A", "runner", _d("proj:s", "tpl:s stage:s why:s ticks:i")),
    "YEAR_REVIEW": ("A", "kern", _d(opt="year:i")),
    "SIEGE_START": ("B", "siege", _d(opt="vis:i inv:i great:i why:s")),
    "ALERT_START": ("B", "siege", _d(opt="vis:i")),
    "ALERT_END": ("B", "siege", _d(opt="vis:i")),
    "INVASION": ("B", "threat", _d(opt="id:i")),
    "MOOD_START": ("B", "care", _d(opt="unit:i kind:s need:s ok:f")),
    "MOOD_NEED": ("B", "care", _d(opt="unit:i kind:s need:s ok:f")),
    "MOOD_END": ("B", "care", _d(opt="unit:i kind:s need:s ok:f")),
    "CARAVAN": ("B", "trade", _d(opt="phase:s ratio:i civ:s")),
    "MIGRANTS": ("B", "economy", _d(opt="n:i")),
    "PETITION": ("B", "care", _d(opt="kind:s")),
    "STOCK_LOW": ("B", "economy", _d("key:s", "days:i min:i")),
    "CANCEL_LOOP": ("B", "economy", _d(opt="order:i job:s n:i")),
    "CAPTURE": ("B", "care", _d(opt="unit:i race:s")),
    "BREACH_STOP": ("B", "runner", _d(opt="proj:s why:s pos:p")),
    "KERNEL_SLOW": ("B", "kern", _d("module:s", "ms:i factor:i")),
    "WEALTH": ("B", "siege", _d(opt="created:i exported:i imported:i")),
    "DRILL_RESULT": ("B", "drill", _d(opt="pass:f raised:i worn:i outside:i dbl:i")),
    "READY_CHANGE": ("B", "readiness", _d(opt="from:i to:i fail:sa")),
    "POPCAP": ("B", "readiness", _d("cap:i", "why:s")),
    "AUDIT": ("B", "readiness", _d(opt="ok:f fails:sa min_traps:i")),
    "PROJECT_DONE": ("B", "runner", _d("proj:s", "tpl:s")),
    "PROJECT_REQUEST": ("B", "any", _d("tpl:s", "n:i why:s")),
    "PHASE": ("B", "runner", _d(opt="from:s to:s")),
    "PAUSE": ("B", "arbiter", _d("on:f", "by:s ttl:i")),
    "DEATH": ("B", "care", _d(opt="unit:i citizen:f cause:s")),
    "ACT_FAIL": ("B", "kern", _d("fn:s", "err:s module:s")),
    "SIEGE_STATUS": ("C", "siege", _d(opt="vis:i worn:i on_station:i deaths:i captures:i")),
    "SEASON": ("C", "kern", _d(opt="year:i season:i")),
    "PROJECT_STAGE": ("C", "runner", _d("proj:s", "stage:s pct:i")),
    "MODE": ("C", "kern", _d("from:s to:s", "why:s")),
    "GATE": ("C", "gate", _d("bridge:s", "state:s")),
    "LEVER": ("C", "gate", _d("bridge:s", "lever:i job:i")),
    "SNAPSHOT_READY": ("C", "snapshot", _d("id:s path:s", "purpose:s")),
    "CMD": ("C", "kern", _d("id:s verb:s ok:f")),
    "BOOT": ("C", "kern", _d(opt="save:s v:i boots:i")),
    "UNLOAD": ("C", "kern", _d()),
}

EVENT = Obj(req={"n": NAT, "tick": TICK, "type": Str(TYPE_RE), "cls": Str(enum=["A", "B", "C"]),
                 "msg": Str(maxbytes=200), "d": OPEN})

# ---------------------------------------------------------------- verbs
VERB_ARGS: dict[str, Obj] = {
    "plan.reload": Obj(),
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
    "squad.sortie": Obj(req={"squad": Str(enum=["A", "B", "C"]), "target": AnyOf(ID, POS),
                             "approve": Const(True)}),
    "lever": Obj(req={"bridge": BRIDGE, "want": Str(enum=["up", "down"])}),
    "inspect": Obj(req={"what": Str(enum=["state", "modules", "census", "manifest", "projects", "persist",
                                          "perf", "mode", "plan"])}, opt={"key": Str(maxbytes=80)}),
    "selftest": Obj(opt={"suite": Str(enum=["quick", "full"])}),
    "module.enable": Obj(req={"module": MODULE}),
}
# verb -> (handler module, allowed modes or None, needs approve)
VERBS: dict[str, tuple[str, list[str] | None, bool]] = {
    "plan.reload": ("kern", None, False), "bp.place": ("runner", None, False),
    "bp.cancel": ("runner", None, False), "drill": ("drill", ["PEACE"], False),
    "snapshot": ("snapshot", None, False), "audit": ("readiness", None, False),
    "popcap.lower": ("readiness", None, False), "tempo.lower": ("arbiter", None, False),
    "pause": ("arbiter", None, False), "unpause": ("arbiter", None, False),
    "trade.want": ("trade", None, False),
    "squad.sortie": ("military", ["ALERT", "SIEGE", "BREACH", "RECOVERY"], True),
    "lever": ("gate", ["PEACE"], False), "inspect": ("kern", None, False),
    "selftest": ("selftest", None, False), "module.enable": ("kern", None, False),
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
         "k": Obj(req={"ms_s": NAT, "gap_max_ms": NAT, "slow": Arr(MODULE), "faults": NAT},
                  opt={"disabled": Arr(MODULE), "ms_max": NAT}),
         "ev": NAT},
    opt={"save": Str(maxbytes=120), "phase": PHASE,
         "pop": Obj(opt={"cit": NAT, "adults": NAT, "soldiers": NAT, "cap": NAT, "gate_cap": NAT}),
         "ready": Obj(req={"lvl": Int(0, 3), "worn": PCT, "cv": NAT, "drill_age": Int(-1),
                           "audit": Obj(req={"ok": FLAG, "age": Int(-1), "min_traps": NAT}),
                           "fail": Arr(Str(maxbytes=24), hi=8)}),
         "stock": Obj(opt={"drink_d": NAT, "food_d": NAT, "meals": NAT, "hosp_water": FLAG}),
         "care": Obj(req={"stressed_pct": PCT, "naked": NAT, "ghosts": NAT, "corpses_old": NAT,
                          "tombs_free": NAT, "moods": NAT}),
         "labor": Obj(req={"starving": NAT, "idle": PCT}),
         "threat": Obj(req={"vis": NAT, "armed": FLAG}),
         "proj": Arr(Tup([ID, Str(maxbytes=24), PCT, Str(maxbytes=40)]), hi=8),
         "bridges": Obj(extra=Str(enum=BRIDGE_STATES), keys=BRIDGE_RE),
         "owners": Obj(req={"pause": AnyOf(Null(), Str(enum=["inbox", "gordon", "popup", "df"])),
                            "tempo": Str(enum=["mode", "inbox"])}),
         "mil": Obj(req={"squads": NAT, "soldiers": NAT, "worn": PCT, "cv": NAT, "metal_pct": PCT,
                         "on_station": NAT}),
         "trade": Obj(req={"caravan": FLAG, "ratio": NAT, "done": NAT})})

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
         "stations": Obj(opt={"melee": POS, "gallery": POS, "b2": POS}),
         "killboxes": Arr(Obj(req={"id": ID, "bbox": BBOX}), hi=20),
         "burrows": Obj(extra=Obj(req={"role": Str(enum=["kern", "refuge", "other"])}), keys=r"^.{1,40}$"),
         "edge": Arr(POS, hi=200),
         "refuge": Obj(req={"anchor": POS, "burrow": Str(maxbytes=40)}),
         "stairs": Obj(opt={"civ": Arr(Tup([INT] * 4), hi=8), "mil": Arr(Tup([INT] * 4), hi=8)}),
         "zones": Obj(opt={z: Arr(BBOX, hi=50) for z in ("Z1", "Z2", "Z3", "Z4")}),
         "rooms": Arr(Obj(req={"id": ID, "tpl": TPL, "use": Str(enum=["used", "utility"]), "bbox": BBOX,
                              "tier": NAT}), hi=200),
         "workshops": Arr(Obj(req={"type": Str(maxbytes=40), "pos": POS}), hi=100),
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
               opt={"marks": Obj(extra=Arr(POS, hi=500), keys=r"^[a-z_]{1,20}$")})


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
                                    "population_cap": NAT, "timestream_fps": Int(-1), "weather": Bool(),
                                    "overlays": Obj(extra=Bool())})})
LOCK = Obj(req={"holder": Str(maxbytes=40), "purpose": Str(maxbytes=200), "expires": NAT})
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
    "restore": RESTORE, "lock": LOCK, "allowlist": ALLOWLIST,
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
            "postures": POSTURES, "mode_setters": MODE_SETTERS}
    return hashlib.sha256(json.dumps(blob, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def appendix() -> str:
    """Markdown block for CONTRACTS.md Appendix A (deterministic)."""
    parts = [f"Contract digest: `{digest()}`",
             "",
             "DESIGN §6 formats and the inbox verb args. Other kinds: `python -m df_llm_helper.schema "
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
