"""Fair-play rules (v2, WP4): Gordon's decisions and the act.run command allowlist.

    get_decision('D-07') -> 'unchanged'        # config/decisions.yaml, defaults from schema.DECISIONS
    decisions.get(id) / decisions.all() / decisions.pending()
    allowlist() -> dict                         # config/allowlist.json (CONTRACTS §9.14)
    check_run(cmd, args) -> (ok, reason)        # exactly the act.run gate kern implements in Lua
    blocked_match(tokens) -> entry | None
    owned_match(tokens) -> (entry, owner) | None  # commands that only a dedicated act function may run

Normative: docs/v2/CONTRACTS.md §9.14 (allowlist), §9.16 (decisions), docs/v2/DECISIONS.md.
The v1 exception register (ExceptionRegistry, check_command, ...) is retired; it lives in tag v1-final.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from . import schema

REPO = Path(__file__).resolve().parent.parent
DECISIONS_PATH = REPO / "config" / "decisions.yaml"
ALLOWLIST_PATH = REPO / "config" / "allowlist.json"

# Allowed answers per decision (DESIGN §15, docs/v2/DECISIONS.md). A str is a regex.
CHOICES: dict[str, list[str] | str] = {
    "D-01": ["A", "B"],
    "D-02": r"^[a-z0-9_.:/-]{1,40}$",          # free answer; kernel applies only values it knows
    "D-03": ["rule", "immediate", "off"],
    "D-04": ["off", "on"],
    "D-05": ["off", "on"],
    "D-06": ["off", "on"],
    "D-07": ["unchanged", "visitor30", "visitor30_noweather"],
    "D-08": ["dropped"],                        # the flags1.left edit is never offered again
    "D-09": ["no", "yes"],
    "D-10": ["off", "on"],
    "D-11": ["accepted", "rejected"],
    "D-12": r"^\d{1,2}/\d{1,2}$",
    "D-13": ["no", "yes"],
    "D-14": ["down", "up"],                     # peace_gates: PEACE state of the gate bridges (FR-55)
}

_DECISION_LINE = re.compile(r"^(D-\d\d)\s*:\s*([^#]*?)\s*(#.*)?$")   # CONTRACTS §9.16


def _valid(did: str, value: str) -> bool:
    c = CHOICES[did]
    return value in c if isinstance(c, list) else re.fullmatch(c, value) is not None


def _read(path: Path) -> str:
    try:
        return path.read_bytes().decode("utf-8-sig", errors="replace")
    except OSError:
        return ""


def parse_decision_lines(text: str) -> dict[str, tuple[str, str]]:
    """{id: (value, comment)} for every `D-NN: value  # comment` line."""
    out: dict[str, tuple[str, str]] = {}
    for line in text.splitlines():
        m = _DECISION_LINE.match(line.strip())
        if m and m.group(2):
            out[m.group(1)] = (m.group(2), (m.group(3) or "").lstrip("#").strip())
    return out


def decision_errors(path: str | Path | None = None) -> list[str]:
    errs = []
    for did, (val, _) in parse_decision_lines(_read(Path(path or DECISIONS_PATH))).items():
        if did not in schema.DECISIONS:
            errs.append(f"{did}: unknown decision id")
        elif not _valid(did, val):
            errs.append(f"{did}: invalid value {val!r} (default {schema.DECISIONS[did]!r} applies)")
    return errs


def load_decisions(path: str | Path | None = None) -> dict[str, str]:
    """All decisions (D-01 .. D-14); missing or invalid values fall back to the default (off/unchanged)."""
    raw = schema.parse_decisions(_read(Path(path or DECISIONS_PATH)))
    return {did: (raw[did] if did in raw and _valid(did, raw[did]) else dflt)
            for did, dflt in schema.DECISIONS.items()}


def get_decision(did: str, path: str | Path | None = None) -> str:
    if did not in schema.DECISIONS:
        raise KeyError(f"unknown decision {did!r}")
    return load_decisions(path)[did]


def pending(path: str | Path | None = None) -> list[str]:
    """Decisions Gordon has not answered yet: line missing or its comment starts with 'default'."""
    lines = parse_decision_lines(_read(Path(path or DECISIONS_PATH)))
    return [d for d in schema.DECISIONS
            if d not in lines or lines[d][1].lower().startswith("default")]


class _Decisions:
    """`decisions.get(id)` with defaults (DESIGN §12 WP4 interface)."""

    def __init__(self, path: str | Path | None = None):
        self.path = path

    def get(self, did: str) -> str:
        return get_decision(did, self.path)

    def all(self) -> dict[str, str]:
        return load_decisions(self.path)

    def pending(self) -> list[str]:
        return pending(self.path)


decisions = _Decisions()


# ---------------------------------------------------------------- reflex knobs (CONTRACTS §9.18, FR-51/52/53)
REFLEX_PATH = REPO / "config" / "reflex.json"
REFLEX_ACTIONS = ("clock", "gates", "doors", "alert")


def reflex_errors(path: str | Path | None = None) -> list[str]:
    """Problems of config/reflex.json; the kernel falls back to its built-in default for each bad key (fail-open),
    so these are warnings for `python -m dfpilot.lint --config`. A missing file is fine (all defaults)."""
    p = Path(path or REFLEX_PATH)
    if not p.exists():
        return []
    name = "config/reflex.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    if not isinstance(doc, dict) or doc.get("v") != 2:
        return [f"{name}: needs an object with v: 2"]
    errs = []

    def is_int(v, lo, hi):
        return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi
    for k in doc:
        if k not in ("v", "about", "clock", "hold_quiet_days", "ack_timeout_s", "defaults", "refuge", "gate", "intake",
                     "sortie", "predator_near", "lockdown_near", "stations", "perimeter") and k not in REFLEX_EXTRA:
            errs.append(f"{name}: unknown key {k!r}")
    clock = doc.get("clock", {})
    if not isinstance(clock, dict):
        errs.append(f"{name}: clock must be an object")
    else:
        for k, v in clock.items():
            if k not in ("siege_cap", "alert_cap", "trade_cap"):
                errs.append(f"{name}: clock.{k}: unknown key")
            elif not is_int(v, 10, 1000):
                errs.append(f"{name}: clock.{k}: int 10..1000 expected, got {v!r}")
    if "hold_quiet_days" in doc and not is_int(doc["hold_quiet_days"], 0, 30):
        errs.append(f"{name}: hold_quiet_days: int 0..30 expected")
    if "predator_near" in doc and not is_int(doc["predator_near"], 0, 400):
        errs.append(f"{name}: predator_near: int 0..400 expected")
    if "lockdown_near" in doc and not is_int(doc["lockdown_near"], 0, 400):
        errs.append(f"{name}: lockdown_near: int 0..400 expected")
    if "ack_timeout_s" in doc and not is_int(doc["ack_timeout_s"], 5, 3600):
        errs.append(f"{name}: ack_timeout_s: int 5..3600 expected")
    # seal's refuge knobs (refuge beds, BUG-019): beds >= ceil(citizens x bed_pct / 100); BREACH level days
    ref = doc.get("refuge", {})
    if not isinstance(ref, dict):
        errs.append(f"{name}: refuge must be an object")
    else:
        for k, v in ref.items():
            lim = {"bed_pct": (0, 100), "breach_days": (0, 60)}.get(k)
            if lim is None:
                errs.append(f"{name}: refuge.{k}: unknown key")
            elif not is_int(v, *lim):
                errs.append(f"{name}: refuge.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    dflt = doc.get("defaults", {})
    if not isinstance(dflt, dict):
        errs.append(f"{name}: defaults must be an object")
    else:
        for t, acts in dflt.items():
            if t not in schema.INTERRUPTS:
                errs.append(f"{name}: defaults.{t}: not an interrupt type ({', '.join(schema.INTERRUPTS)})")
            elif not isinstance(acts, list) or any(a not in REFLEX_ACTIONS for a in acts):
                errs.append(f"{name}: defaults.{t}: a list of {', '.join(REFLEX_ACTIONS)} expected")
    # BUG-027: gate.force_near (tiles; 0 = never raise onto a unit), gate.manual (bridge names or building ids that
    # get no automatic pull)
    gate = doc.get("gate", {})
    if not isinstance(gate, dict):
        errs.append(f"{name}: gate must be an object")
    else:
        for k, v in gate.items():
            if k == "force_near":
                if not is_int(v, 0, 30):
                    errs.append(f"{name}: gate.force_near: int 0..30 expected, got {v!r}")
            elif k == "manual":
                if not isinstance(v, list) or len(v) > 32 or any(
                        not (is_int(x, 0, 2**31 - 1) or (isinstance(x, str) and re.match(schema.BRIDGE_RE, x)))
                        for x in v):
                    errs.append(f"{name}: gate.manual: a list of bridge names (O1, B1) or building ids expected")
            else:
                errs.append(f"{name}: gate.{k}: unknown key")
    # intake waves and the sortie through O1 (Gordon 2026-10-16; lua/dfllm/siege.lua M.IK_LIM / M.SO_LIM)
    for blk, lims in (("intake", INTAKE_LIM), ("sortie", SORTIE_LIM), ("stations", STATIONS_LIM),
                      ("perimeter", PERIMETER_LIM), ("confine", CONFINE_LIM), ("popups", POPUPS_LIM)):
        sec = doc.get(blk, {})
        if not isinstance(sec, dict):
            errs.append(f"{name}: {blk} must be an object")
            continue
        for k, v in sec.items():
            lim = lims.get(k)
            if blk == "confine" and k == "harmless_races":      # BUG-065: creature tokens (reflex.lua `harmless`)
                if not isinstance(v, list) or len(v) > 16 or any(
                        not (isinstance(x, str) and re.fullmatch(r"[A-Z][A-Z0-9_]{0,39}", x)) for x in v):
                    errs.append(f"{name}: confine.harmless_races: a list of at most 16 creature tokens (GREMLIN) expected")
                continue
            if lim is None:
                errs.append(f"{name}: {blk}.{k}: unknown key")
            elif lim == "bool":
                if not isinstance(v, bool):
                    errs.append(f"{name}: {blk}.{k}: true or false expected, got {v!r}")
            elif not is_int(v, *lim):
                errs.append(f"{name}: {blk}.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# BUG-065 / FR-75: the confinement limit and the popup knobs of config/reflex.json (lua/dfllm/reflex.lua `cfg`,
# lua/dfllm/arbiter.lua `popup_cfg`; a bad value = the default)
CONFINE_LIM: dict = {"max_days": (0, 365), "harmless_size": (0, 5000000), "lone_max": (1, 10), "offer_days": (0, 365),
                     "need_thirst": (10000, 75000), "need_hunger": (10000, 100000)}
POPUPS_LIM: dict = {"other": "bool", "other_s": (5, 600), "log_s": (60, 86400)}
REFLEX_EXTRA = ("confine", "popups")


# the kernel's limits for config/reflex.json intake / sortie (siege.lua M.IK_LIM, M.SO_LIM; a bad value = the default)
INTAKE_LIM: dict = {"on": "bool", "wave": (1, 40), "min_soldiers": (1, 30), "worn": (0, 100), "army_ratio": (1, 50),
                    "cooldown": (0, 33600), "danger_dist": (0, 200), "stable": (0, 33600), "losses": (1, 30),
                    "muster": (100, 33600), "fight": (300, 100800)}
SORTIE_LIM: dict = {"worn": (0, 100), "losses": (1, 30), "max_ticks": (300, 33600), "gather": (100, 33600),
                    "foe_cv": (0, 100), "near": (1, 50)}
# BUG-030: the deep defense (siege.lua M.ST / M.ST_LIM): an army over core_ratio x soldiers, worn % or the iron/steel
# share below worn / metal; BUG-032: spread = tiles around its station point a squad stands on (military.lua M.SPREAD:
# a station lies more than gate's margin + spread tiles from every bridge footprint)
STATIONS_LIM: dict = {"core_ratio": (1, 50), "worn": (0, 100), "metal": (0, 100), "spread": (0, 5)}
# BUG-030 rebuild policy (seal.lua CFG.stop_after): a manifest bridge destroyed stop_after times by building destroyers
# since the player's last answer (verb bridge.rebuild) is not rebuilt automatically any more; 0 = always rebuilt
PERIMETER_LIM: dict = {"stop_after": (0, 20)}

BASELINE_PATH = REPO / "config" / "baseline.json"
_THIRST = (1000, 75000)                   # DF's thirst timer: "thirsty" ~25,000-50,000, dehydration kills ~75,000
_TICKS = (1, 4032000)                     # a cadence in game ticks (at most ten years)
# lua/dfllm/water.lua M.DEFAULTS: the knobs config/baseline.json "water" may tune ("bool", else an int range).
# water.conf ignores a value of another type; tests/test_hospital_water.py checks the key set against water.lua.
WATER_LIM: dict = {
    "thirst_alarm": _THIRST, "thirst_watch": _THIRST, "near": (1, 200), "shaft": (1, 60), "pond_near": (0, 20),
    "pond_per_run": (0, 20), "buckets_min": (0, 50), "bucket_per_patient": (0, 10), "buckets_max": (0, 100),
    "unforbid_per_run": (0, 100), "alarm_every": _TICKS, "hosp_every": _TICKS, "request_every": _TICKS,
    "flood_every": _TICKS, "flood_tiles": (1, 100), "units_per_slice": (1, 1000), "items_per_slice": (1, 10000),
    "zone_tiles": (1, 10000), "order_backoff": _TICKS, "deep": (1, 7), "zone_below": "bool", "gate_every": _TICKS,
    "wake_wall_s": (0, 86400), "ws_dz": (0, 20), "ws_tiles": (1, 100000), "ws_every": _TICKS, "ws_bodies": (1, 100),
    "ws_dig": (0, 50), "ws_reach": (0, 100), "ws_reads": (1, 10000),
    # BUG-034: the zones of a dry hospital go once a patient's thirst is over patient_thirst (hosp_remove false: never)
    "patient_thirst": _THIRST, "hosp_remove": "bool", "remove_per_run": (0, 32),
    # BUG-040: a done cistern whose well stays dry this many days is reported once (CISTERN_DRY, B)
    "cistern_dry_days": (1, 400),
}


def water_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "water" part of config/baseline.json (BUG-034): unknown keys and values the kernel
    ignores (another type than its default) or should not get (out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("water", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: water must be an object"]
    errs = []
    for k, v in sec.items():
        lim = WATER_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: water.{k}: unknown key")
        elif lim == "bool":
            if not isinstance(v, bool):
                errs.append(f"{name}: water.{k}: true or false expected, got {v!r}")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: water.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# Run 11 siege 8 (lua/dfllm/runner.lua conf): config/baseline.json "runner": seal first (an open seal or plug runs
# first and pauses the housing/work projects in PEACE until done or stuck for stuck_days; food_d/drink_d below which the
# food/drink projects go on) and the rebuild policy (below pop citizens only seal/tombs/food/beds/depot, until off;
# pop 0 = off). runner.conf keeps the default for a value of another type or out of range.
# BUG-037: queue = the slot rules (a slot holder without own progress for yield_days yields its slot; a project blocked
# for good is parked after park_days: out of the pause, the keepers and PLAN_EXHAUSTED, announced once with bp.cancel)
RUNNER_LIM: dict = {"seal_first": {"on": "bool", "stuck_days": (1, 60), "food_d": (0, 400), "drink_d": (0, 400)},
                    "rebuild": {"pop": (0, 250), "off": (0, 250)},
                    "queue": {"yield_days": (1, 60), "park_days": (1, 400)}}


def runner_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "runner" part of config/baseline.json (Run 11 siege 8): unknown keys, values the kernel
    ignores (another type, out of range) and rebuild.off below rebuild.pop. A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("runner", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: runner must be an object"]
    errs = []
    for part, v in sec.items():
        lims = RUNNER_LIM.get(part)
        if lims is None:
            errs.append(f"{name}: runner.{part}: unknown key")
            continue
        if not isinstance(v, dict):
            errs.append(f"{name}: runner.{part} must be an object")
            continue
        for k, x in v.items():
            lim = lims.get(k)
            if lim is None:
                errs.append(f"{name}: runner.{part}.{k}: unknown key")
            elif lim == "bool":
                if not isinstance(x, bool):
                    errs.append(f"{name}: runner.{part}.{k}: true or false expected, got {x!r}")
            elif not (isinstance(x, int) and not isinstance(x, bool) and lim[0] <= x <= lim[1]):
                errs.append(f"{name}: runner.{part}.{k}: int {lim[0]}..{lim[1]} expected, got {x!r}")
    rb = sec.get("rebuild") if isinstance(sec.get("rebuild"), dict) else {}
    lo, hi = rb.get("pop"), rb.get("off")
    if all(isinstance(x, int) and not isinstance(x, bool) for x in (lo, hi)) and hi < lo:
        errs.append(f"{name}: runner.rebuild.off {hi} < pop {lo} (the policy would end at once; the kernel uses pop)")
    return errs


# BUG-043 (lua/dfllm/snapshot.lua M.CAP_LIM, CFG.max_tiles): config/baseline.json "snapshot": max_tiles = the tiles
# one export reads at most (sliced, CFG.slice 1000 a frame: 400,000 = 400 slices). snapshot.lua keeps its default for
# a value of another type or out of range; lint --config refuses it.
SNAPSHOT_LIM: dict = {"max_tiles": (10000, 1000000)}


def snapshot_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "snapshot" part of config/baseline.json (BUG-043): unknown keys, values the kernel
    ignores (another type, out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("snapshot", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: snapshot must be an object"]
    errs = []
    for k, v in sec.items():
        lim = SNAPSHOT_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: snapshot.{k}: unknown key")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: snapshot.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# BUG-042 (lua/dfllm/economy.lua M.DEFAULTS): the economy knobs of the drink line, the unvalidated-order watch, the
# manager's office and the drink gatherers ("bool", else an int range); economy.conf takes the file's part as it is,
# so a bad value here would reach the kernel: lint --config refuses it. Other economy keys are checked by the mirror
# test (tests/lua/test_economy.lua: config/baseline.json == economy.DEFAULTS).
ECONOMY_LIM: dict = {"drink": {"low_d": (0, 400)},
                     "orders": {"unval_days": (1, 60)},
                     "office": {"table": "bool", "retry_days": (1, 112), "max_tiles": (1, 10000)},
                     "gather": {"drink_d": (0, 400), "drink_off": (0, 400)},
                     "barrels": {"brew_wait": (0, 200)}}
ECONOMY_OWN = ("drink", "office")             # parts whose every key is listed above


def economy_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the BUG-042 knobs in the "economy" part of config/baseline.json: values of another type or out of
    range, unknown keys of the parts BUG-042 added (drink, office). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("economy", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: economy must be an object"]
    errs = []
    for part, lims in ECONOMY_LIM.items():
        v = sec.get(part, {})
        if not isinstance(v, dict):
            errs.append(f"{name}: economy.{part} must be an object")
            continue
        for k, x in v.items():
            lim = lims.get(k)
            if lim is None:
                if part in ECONOMY_OWN:
                    errs.append(f"{name}: economy.{part}.{k}: unknown key")
            elif lim == "bool":
                if not isinstance(x, bool):
                    errs.append(f"{name}: economy.{part}.{k}: true or false expected, got {x!r}")
            elif not (isinstance(x, int) and not isinstance(x, bool) and lim[0] <= x <= lim[1]):
                errs.append(f"{name}: economy.{part}.{k}: int {lim[0]}..{lim[1]} expected, got {x!r}")
    return errs


# ---------------------------------------------------------------- allowlist (CONTRACTS §9.14)
_AL_CACHE: dict[str, tuple[float, dict]] = {}


def allowlist(path: str | Path | None = None) -> dict:
    """Parsed and schema-checked config/allowlist.json (cached by mtime). Raises on an invalid file:
    a broken allowlist must never turn into 'allow everything'."""
    p = Path(path or ALLOWLIST_PATH)
    mt = p.stat().st_mtime
    hit = _AL_CACHE.get(str(p))
    if hit and hit[0] == mt:
        return hit[1]
    doc = json.loads(_read(p))
    schema.check("allowlist", doc)
    _AL_CACHE[str(p)] = (mt, doc)
    return doc


def _toks(s: str) -> list[str]:
    return s.split()


# blocked entries are also checked behind these wrappers: `enable fastdwarf` = fastdwarf
_ENABLERS = (["enable"], ["control-panel", "enable"], ["control-panel", "autostart"])


def blocked_match(tokens: list[str], al: dict | None = None) -> str | None:
    """The blocked entry hit by a command line (as tokens), or None. An entry that is a single flag
    (`--instant`) is blocked anywhere in the line (also as `--instant=x`); any other entry is a
    token prefix of the line, also after an enabling wrapper (`enable X`, `control-panel enable X`)."""
    al = al or allowlist()
    heads = [tokens]
    for w in _ENABLERS:
        if tokens[:len(w)] == w:                     # every listed name: `enable a fastdwarf`
            heads += [tokens[k:] for k in range(len(w), len(tokens))]
    for entry in al["blocked"]:
        et = _toks(entry)
        if not et:
            continue
        if len(et) == 1 and et[0].startswith("-"):
            if any(t == et[0] or t.startswith(et[0] + "=") for t in tokens):
                return entry
            continue
        if any(h[:len(et)] == et for h in heads):
            return entry
    return None


# Actuators with a dedicated act function and a sole owner (DESIGN §3, CONTRACTS §5). act.lua runs these
# commands itself (cmd_run, no allowlist), so they are not in config/allowlist.json, and the lint rule
# `owned-actuator` flags them in K.act.run literals. Token prefixes, also behind enable/disable wrappers.
OWNED = {
    "timestream": "act.timestream (arbiter)",
    "overlay enable": "act.overlay (arbiter)",
    "overlay disable": "act.overlay (arbiter)",
    "enable overlay": "act.overlay (arbiter)",
    "disable overlay": "act.overlay (arbiter)",
    "disable timestream": "act.timestream (arbiter)",
    "disable pop-control": "act.popcap (readiness)",
    "pop-control set max-pop": "act.popcap (readiness)",
    "quickfort": "act.quickfort (runner)",
    "orders": "act.orders_import / act.orders (economy)",
    "workorder": "act.workorder (economy, dfllm: tag)",
    "zone": "act.zone_assign (care)",
    "burrow": "act.quickfort burrow mode (runner) / act.alert_burrows (siege)",
    "gui/civ-alert": "act.civ_alert / act.alert_burrows (siege)",
}
# the R0 cap: baseline sets it only while readiness is not loaded (lua/dfllm/baseline.lua:198)
OWNED_EXEMPT = frozenset({"pop-control set max-pop 55"})
_WRAPPERS = (["enable"], ["disable"], ["control-panel", "enable"], ["control-panel", "disable"])


def owned_match(tokens: list[str]) -> tuple[str, str] | None:
    """(OWNED entry, owner) when a command line belongs to a dedicated act function, else None.
    `control-panel disable a timestream` counts like `disable timestream`."""
    if " ".join(tokens) in OWNED_EXEMPT:
        return None
    heads = [tokens]
    for w in _WRAPPERS:
        if tokens[:len(w)] == w:
            heads += [[w[-1], t] for t in tokens[len(w):]]
    for h in heads:
        for entry, owner in OWNED.items():
            et = entry.split()
            if h[:len(et)] == et:
                return entry, owner
    return None


def match_args(pattern: str, args: list[str]) -> bool:
    """One allowlist pattern against argument tokens: `*` = exactly one token, `**` = any rest
    (also none, last position only), `""` = no arguments, anything else = the literal token."""
    pt = _toks(pattern)
    for i, p in enumerate(pt):
        if p == "**":
            return True
        if i >= len(args) or (p != "*" and p != args[i]):
            return False
    return len(args) == len(pt)


def check_run(cmd: str, args: list[str] | tuple = (), al: dict | None = None) -> tuple[bool, str]:
    """The act.run gate: allowed iff cmd is in `commands`, no `blocked` entry matches and the joined
    args match one pattern (an empty pattern list allows only the bare command)."""
    al = al or allowlist()
    line = _toks(cmd) + _toks(" ".join(str(a) for a in args))
    if not line:
        return False, "empty command"
    b = blocked_match(line, al)
    if b:
        return False, f"blocked: {b}"
    entry = al["commands"].get(line[0])
    if entry is None:
        return False, f"{line[0]}: not in config/allowlist.json"
    rest = line[1:]
    pats = entry["args"] or [""]
    if any(match_args(p, rest) for p in pats):
        return True, "ok"
    return False, f"{line[0]}: arguments not allowed: {' '.join(rest) or '(none)'}"


def is_read_only(cmd: str, al: dict | None = None) -> bool:
    e = (al or allowlist())["commands"].get(cmd)
    return bool(e) and e["rw"] == "r"


def armok_problems(armok_cmds: set[str], al: dict | None = None) -> list[str]:
    """The boot cross-check (DESIGN §11.4) offline: allowlisted commands carrying the armok tag
    that are not listed in armok_exceptions."""
    al = al or allowlist()
    return sorted(c for c in al["commands"] if c in armok_cmds and c not in al["armok_exceptions"])
