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
                     "sortie", "predator_near", "lockdown_near", "stations", "perimeter", "inner") and k not in REFLEX_EXTRA:
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
            lim = {"bed_pct": (0, 100), "breach_days": (0, 60), "floor_pct": (0, 300), "floor_pop": (0, 1000),
                   "supply_switch": (0, 100)}.get(k)
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
    # BUG-108: the interrupt types whose unacked default is skipped at threat 0 (an inner cause); [] = the old rule
    inner = doc.get("inner", [])
    if not isinstance(inner, list) or any(t not in schema.INTERRUPTS for t in inner):
        errs.append(f"{name}: inner: a list of interrupt types ({', '.join(schema.INTERRUPTS)}) expected")
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
            elif k == "noeffect_max":              # BUG-068: pulls in a row without effect before a lever is parked
                if not is_int(v, 1, 20):
                    errs.append(f"{name}: gate.noeffect_max: int 1..20 expected, got {v!r}")
            elif k == "noeffect_wait":             # BUG-068: ticks of the first parking (doubled per further parking)
                if not is_int(v, 100, 24000):
                    errs.append(f"{name}: gate.noeffect_wait: int 100..24000 expected, got {v!r}")
            elif k == "pull_cap":                  # M3 (BUG-114): pulls without effect in a mode before gate gives up
                if not is_int(v, 3, 100):
                    errs.append(f"{name}: gate.pull_cap: int 3..100 expected, got {v!r}")
            elif k == "giveup_wait":               # M3 (BUG-114): ticks without a pull after the give-up (doubled per give-up)
                if not is_int(v, 600, 100800):
                    errs.append(f"{name}: gate.giveup_wait: int 600..100800 expected, got {v!r}")
            elif k == "lever_hold_days":           # BUG-236: game days a player's `lever` down holds the bridge down
                if not is_int(v, 0, 28):
                    errs.append(f"{name}: gate.lever_hold_days: int 0..28 expected, got {v!r}")
            elif k == "manual":
                if not isinstance(v, list) or len(v) > 32 or any(
                        not (is_int(x, 0, 2**31 - 1) or (isinstance(x, str) and re.match(schema.BRIDGE_RE, x)))
                        for x in v):
                    errs.append(f"{name}: gate.manual: a list of bridge names (O1, B1) or building ids expected")
            else:
                errs.append(f"{name}: gate.{k}: unknown key")
    # intake waves and the sortie through O1 (Gordon 2026-10-16; lua/dfllm/siege.lua M.IK_LIM / M.SO_LIM)
    for blk, lims in (("intake", INTAKE_LIM), ("sortie", SORTIE_LIM), ("stations", STATIONS_LIM),
                      ("perimeter", PERIMETER_LIM), ("confine", CONFINE_LIM), ("popups", POPUPS_LIM),
                      ("breach", BREACH_LIM), ("resume", RESUME_LIM)):
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
                     "need_thirst": (10000, 75000), "need_hunger": (10000, 100000), "ask_days": (0, 365),
                     "kill_hours": (0, 720), "siege_release": "bool"}
POPUPS_LIM: dict = {"other": "bool", "other_s": (5, 600), "log_s": (60, 86400)}
# M3 (BUG-114): siege.lua breach_stuck: ticks of a BREACH whose failed bridges stay down before it falls back to SIEGE (0 = off)
BREACH_LIM: dict = {"stuck_ticks": (0, 4032000)}
# FR-94 (Run 14 note 100): arbiter.lua resume_cfg: real minutes a pause by DF may stand before the wake PAUSED_BY_DF (0 = no wake)
RESUME_LIM: dict = {"wake_min": (0, 240)}
REFLEX_EXTRA = ("confine", "popups", "breach", "resume")


# the kernel's limits for config/reflex.json intake / sortie (siege.lua M.IK_LIM, M.SO_LIM; a bad value = the default)
INTAKE_LIM: dict = {"on": "bool", "wave": (1, 40), "min_soldiers": (1, 30), "worn": (0, 100), "army_ratio": (1, 50),
                    "cooldown": (0, 33600), "danger_dist": (0, 200), "stable": (0, 33600), "losses": (1, 30),
                    "muster": (100, 33600), "fight": (300, 100800)}
SORTIE_LIM: dict = {"worn": (0, 100), "losses": (1, 30), "max_ticks": (300, 33600), "gather": (100, 33600),
                    "foe_cv": (0, 100), "near": (1, 50), "kill_near": (0, 50), "idle_ticks": (300, 33600),
                    "hold_ticks": (300, 100800)}
# BUG-030: the deep defense (siege.lua M.ST / M.ST_LIM): an army over core_ratio x soldiers, worn % or the iron/steel
# share below worn / metal; BUG-032: spread = tiles around its station point a squad stands on (military.lua M.SPREAD:
# a station lies more than gate's margin + spread tiles from every bridge footprint)
STATIONS_LIM: dict = {"core_ratio": (1, 50), "worn": (0, 100), "metal": (0, 100), "spread": (0, 5)}
# BUG-030 rebuild policy (seal.lua CFG.stop_after): a manifest bridge destroyed stop_after times by building destroyers
# since the player's last answer (verb bridge.rebuild) is replaced by a wall and a door (BUG-048; it used to ask a
# question nobody answered); 0 = always rebuilt. vanish_after: the same for losses with no destroyer in sight (the loop
# breaker). FR-70 (readiness.lua M.PERIM / M.PERIM_LIM): escalate_days = days of an open perimeter in PEACE before the
# wake repeats every escalate_every days and max-pop freezes at the population (hold_pop citizens or more; 0 = never)
PERIMETER_LIM: dict = {"stop_after": (0, 20), "vanish_after": (0, 20), "escalate_days": (0, 30),
                       "escalate_every": (1, 30), "hold_pop": (0, 250)}

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
    # BUG-054: caregivers (Orderlies) per patient, the bounds, the urgent extra, the additions a run, the hold in days;
    # the death-risk line of PATIENT_DYING and its cadence
    "carers_per_patient": (0, 10), "carers_min": (0, 20), "carers_max": (0, 40), "carers_urgent": (0, 20),
    "carers_per_run": (0, 20), "carers_hold_days": (0, 400), "dying_thirst": _THIRST, "dying_every": _TICKS,
    # BUG-104: a GiveWater job open (no worker) this many game days is 'stuck' in the patient_thirst / PATIENT_DYING cause
    "give_stuck_days": (1, 400),
    # BUG-288/289: the scan's read budget and slices, the boxes round citizens and remembered bodies, the surface survey
    # (levels per column, lattice, budget) and the boxes round its hits; BUG-290: a pit as a well spot
    "ws_read_max": (1000, 400000), "ws_slices": (1, 200), "ws_body_slices": (1, 50), "ws_cit": (0, 60), "ws_mem": (0, 32),
    "ws_mem_r": (0, 60), "ws_survey_levels": (0, 6), "ws_lattice": (2, 8), "ws_survey_max": (0, 200000),
    "ws_seed_r": (0, 60), "ws_seed_max": (0, 100000), "pit_well": "bool",
    # BUG-325: walk origins of the scan; BUG-324: the kernel's Water Source zone on found water (on/off, cadence, spots)
    "ws_from": (1, 10), "wz": "bool", "wz_every": _TICKS, "wz_max": (0, 32), "wz_forget": _TICKS,
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
# BUG-044: seal_first.wall / wall_days = a seal door still not built wall_days (0-60, default 2) after SEAL_STUCK becomes a
# constructed wall when the citizens keep another way (wall false = never)
RUNNER_LIM: dict = {"seal_first": {"on": "bool", "stuck_days": (1, 60), "food_d": (0, 400), "drink_d": (0, 400),
                                   "wall": "bool", "wall_days": (0, 60)},
                    "rebuild": {"pop": (0, 250), "off": (0, 250)},
                    # BUG-116: care first (runner.lua Q.care_lead): the hospital project leads while hospital_out is set or
                    # `patients` patients lie in the fort; stuck_days without progress lifts the pause
                    "care_first": {"on": "bool", "stuck_days": (1, 60), "patients": (1, 250)},
                    "queue": {"yield_days": (1, 60), "park_days": (1, 400)},
                    # BUG-066 / FR-76: the manifest follows the standing workshops (runner.lua Q.sync)
                    "reclaim": {"on": "bool", "gone_scans": (1, 10), "min_ws": (1, 50), "ask_days": (1, 60)}}


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


# package B3 (lua/dfllm/care.lua M.DEFAULTS): the care knobs of the tomb zone lock (BUG-062) and the moods (BUG-063) and
# the stress response (FR-74): "bool", else an int range. care.conf takes the file's part as it is, so a bad value here
# would reach the kernel: lint --config refuses it. The other care keys are checked by the mirror test
# (tests/lua/test_care.lua: config/baseline.json == care.DEFAULTS).
CARE_LIM: dict = {
    "tomb_open_per_run": (0, 1000), "far_check": (0, 500),
    # BUG-133: assignments a run on their own budget (before removals and frees); memorial slabs placed a run (0 = none)
    "tomb_assign_per_run": (0, 1000), "memorials": (0, 50),
    "mood_hunger": _THIRST, "mood_act": _THIRST, "mood_crit": _THIRST, "mood_crit_hunger": _THIRST, "mood_fast": (0, 3600),
    "mood_nook": "bool", "mood_take": "pile", "mood_nook_retry": _TICKS,
    "mood_nook_r": (1, 12), "mood_nook_rmax": (0, 12), "mood_nook_step": (1, 6), "mood_nook_probes": (1, 200),
    "mood_nook_tries": (1, 12),
    # BUG-282..284: MOOD_CRITICAL without a workshop after mood_crit_nows ticks, still waiting after mood_crit_wait days, within
    # mood_crit_left days of insanity (mood_timer ticks from the claim when DF's timer is unreadable), repeats at least
    # mood_crit_every ticks and mood_crit_wall_s s apart; the kernel's shop request / webs task every mood_act_every ticks
    "mood_crit_nows": _TICKS, "mood_crit_wait": (1, 60), "mood_crit_left": (1, 60), "mood_timer": (1200, 200000),
    "mood_crit_every": _TICKS, "mood_crit_wall_s": (0, 3600), "mood_act_every": _TICKS,
    "topple_every": _TICKS, "topple_win": _TICKS, "topple_r": (0, 50),
    "stress_high": (1, 100), "stress_days": (1, 400), "stress_every": _TICKS,
    # BUG-115 / FR-83: curses and transformations (lua/dfllm/curse.lua)
    "curse": "bool", "curse_every": _TICKS, "curse_keep": (1, 200), "curse_ids": (1, 8), "curse_moon_cycles": (1, 40),
    "curse_moon_lead": (0, 30), "curse_trig_win": _TICKS, "s0_ids": (0, 6)}


def care_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the package B3 knobs in the "care" part of config/baseline.json: values of another type or out of range.
    A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("care", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: care must be an object"]
    errs = []
    for k, lim in CARE_LIM.items():
        if k not in sec:
            continue
        v = sec[k]
        if lim == "bool":
            if not isinstance(v, bool):
                errs.append(f"{name}: care.{k}: true or false expected, got {v!r}")
        elif lim == "pile":                    # a stockpile name for take_from (runner.mooddrink: <= 20 characters)
            if not (isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,20}", v)):
                errs.append(f"{name}: care.{k}: a stockpile name (1-20 letters, digits, _ or -) expected, got {v!r}")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: care.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
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


# BUG-050 / FR-71 / BUG-051 / BUG-052 / FR-79 (lua/dfllm/military.lua M.conf): config/baseline.json "military". unstick = the monthly
# uniform-unstick (on; drop = the opt-in for --drop; every = ticks between two runs; below = it runs only while the worn %
# is below this; drop_after = plain runs with a proven conflict before --drop), militia = squad key (A, B, C) -> the
# months (0-11) it is on duty, free_months = the months the elite is free (default: the union of the militia windows),
# early_pop = citizens from which a fort with a barracks staffs its squads before P2 (0 = off), station_r = the base
# radius of "on station". military.lua keeps its default for a value of another type or out of range (a bad militia
# table is dropped as a whole); lint --config refuses it.
MILITARY_UNSTICK_LIM: dict = {"on": "bool", "drop": "bool", "every": (1200, 403200), "below": (1, 100),
                              "drop_after": (0, 12)}
MILITARY_LIM: dict = {"early_pop": (0, 250), "station_r": (1, 10)}
MILITARY_KEYS = ("A", "B", "C")
# FR-79 (military.lua M.ROT_DEF / M.ROT_LIM): military.rotation = the kernel swaps the members of the militia squads (the
# keys of `militia`) for the next cohort at the close of their window. on = false keeps the members as before, per_day = the
# most members one game day changes (batches are a day apart), worn_min = no turnover of members who wear kit while the
# army's worn % is below it (0 = never held)
MILITARY_ROTATION_LIM: dict = {"on": "bool", "per_day": (1, 10), "worn_min": (0, 100)}
# FR-100/101 (lua/dfllm/kit.lua KIT.DEF / KIT.REFIT_LIM, G18): military.training. on = every melee squad spars with wooden
# training weapons (real ones in any alert; the plan's military.training wins), fallback = the training class of a weapon
# class without a training raw (hammer, mace, whip, none; 'none' = it keeps its weapon), refit_days = days between two
# material refits of a squad's empty armor slots (0 = never)
MILITARY_TRAIN_LIM: dict = {"on": "bool", "fallback": ("AXE", "SWORD", "SPEAR", "none"), "refit_days": (0, 56)}


def military_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "military" part of config/baseline.json (BUG-050, FR-71, BUG-051, BUG-052): unknown keys
    and values the kernel ignores. A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("military", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: military must be an object"]
    errs = []

    def is_int(v, lo, hi):
        return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi

    def months(v):
        return isinstance(v, list) and all(is_int(m, 0, 11) for m in v)
    for k, v in sec.items():
        if k == "unstick":
            if not isinstance(v, dict):
                errs.append(f"{name}: military.unstick must be an object")
                continue
            for uk, uv in v.items():
                lim = MILITARY_UNSTICK_LIM.get(uk)
                if lim is None:
                    errs.append(f"{name}: military.unstick.{uk}: unknown key")
                elif lim == "bool":
                    if not isinstance(uv, bool):
                        errs.append(f"{name}: military.unstick.{uk}: true or false expected, got {uv!r}")
                elif not is_int(uv, *lim):
                    errs.append(f"{name}: military.unstick.{uk}: int {lim[0]}..{lim[1]} expected, got {uv!r}")
        elif k == "militia":
            if not isinstance(v, dict):
                errs.append(f"{name}: military.militia must be an object (squad key -> months)")
                continue
            for mk, mv in v.items():
                if mk not in MILITARY_KEYS:
                    errs.append(f"{name}: military.militia.{mk}: not a squad key ({', '.join(MILITARY_KEYS)})")
                elif not months(mv):
                    errs.append(f"{name}: military.militia.{mk}: a list of months 0..11 expected, got {mv!r}")
        elif k == "free_months":
            if not months(v):
                errs.append(f"{name}: military.free_months: a list of months 0..11 expected, got {v!r}")
        elif k == "rotation":
            if not isinstance(v, dict):
                errs.append(f"{name}: military.rotation must be an object")
                continue
            for rk, rv in v.items():
                lim = MILITARY_ROTATION_LIM.get(rk)
                if lim is None:
                    errs.append(f"{name}: military.rotation.{rk}: unknown key")
                elif lim == "bool":
                    if not isinstance(rv, bool):
                        errs.append(f"{name}: military.rotation.{rk}: true or false expected, got {rv!r}")
                elif not is_int(rv, *lim):
                    errs.append(f"{name}: military.rotation.{rk}: int {lim[0]}..{lim[1]} expected, got {rv!r}")
        elif k == "training":                                       # FR-100/101
            if not isinstance(v, dict):
                errs.append(f"{name}: military.training must be an object")
                continue
            for tk, tv in v.items():
                lim = MILITARY_TRAIN_LIM.get(tk)
                if lim is None:
                    errs.append(f"{name}: military.training.{tk}: unknown key")
                elif lim == "bool":
                    if not isinstance(tv, bool):
                        errs.append(f"{name}: military.training.{tk}: true or false expected, got {tv!r}")
                elif isinstance(lim[0], str):
                    if tv not in lim:
                        errs.append(f"{name}: military.training.{tk}: one of {', '.join(lim)} expected, got {tv!r}")
                elif not is_int(tv, *lim):
                    errs.append(f"{name}: military.training.{tk}: int {lim[0]}..{lim[1]} expected, got {tv!r}")
        elif k in MILITARY_LIM:
            if not is_int(v, *MILITARY_LIM[k]):
                lo, hi = MILITARY_LIM[k]
                errs.append(f"{name}: military.{k}: int {lo}..{hi} expected, got {v!r}")
        else:
            errs.append(f"{name}: military.{k}: unknown key")
    return errs


# BUG-055 (lua/dfllm/readiness.lua M.OFFICES): config/baseline.json "offices": blocker_days = the days a vacant office
# (manager, chief medical dwarf) or squads without a leader may stand before readiness R0 `office` names them (0 = never).
# BUG-117 (readiness.lua M.MWS): mood_ws_days = the days a moodable workshop type may be missing before R0 `mood_ws` names
# it (0 = never), mood_ws_pop = the citizens from which it counts
OFFICES_LIM: dict = {"blocker_days": (0, 400), "mood_ws_days": (0, 400), "mood_ws_pop": (0, 250)}


def offices_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "offices" part of config/baseline.json (BUG-055): unknown keys and values the kernel
    ignores (another type, out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("offices", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: offices must be an object"]
    errs = []
    for k, v in sec.items():
        lim = OFFICES_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: offices.{k}: unknown key")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: offices.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# FR-78 (lua/dfllm/zonelib.lua Z.MAX_TILES): config/baseline.json "zones": max_tiles = the tiles one zone.place box may
# cover (a bad value keeps the default 400); FR-90 dump_path_gap = the tiles a dump zone keeps from a stair, ramp, door, bridge
# (a bad value keeps the default 2)
ZONES_LIM: dict = {"max_tiles": (1, 10000), "dump_path_gap": (0, 8)}


def zones_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "zones" part of config/baseline.json (FR-78): unknown keys and values the kernel ignores
    (another type, out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("zones", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: zones must be an object"]
    errs = []
    for k, v in sec.items():
        lim = ZONES_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: zones.{k}: unknown key")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: zones.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# FR-86 (dfpilot/plan.py stale_years): config/baseline.json "plan": stale_apply_years = the years without a `plan apply` after
# which `follow` applies a minimal plan itself (0 = never). plan.py keeps its default for a value of another type or out of
# range; lint --config refuses it.
PLAN_LIM: dict = {"stale_apply_years": (0, 20)}


def plan_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "plan" part of config/baseline.json (FR-86): unknown keys and values plan.py ignores
    (another type, out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("plan", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: plan must be an object"]
    errs = []
    for k, v in sec.items():
        lim = PLAN_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: plan.{k}: unknown key")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: plan.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# FR-88 (lua/dfllm/viewlib.lua V.cfg): config/baseline.json "view": on = the verb `view` works (false refuses it),
# default_ttl_s / max_ttl_s = the follow time when ttl_s is left out / its ceiling. viewlib keeps its default for a value of
# another type or out of range; lint --config refuses it.
VIEW_LIM: dict = {"on": "bool", "default_ttl_s": (1, 3600), "max_ttl_s": (1, 3600)}


def view_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "view" part of config/baseline.json (FR-88): unknown keys, values viewlib ignores (another
    type, out of range), a default_ttl_s above max_ttl_s. A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("view", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: view must be an object"]
    errs = []
    for k, v in sec.items():
        lim = VIEW_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: view.{k}: unknown key")
        elif lim == "bool":
            if not isinstance(v, bool):
                errs.append(f"{name}: view.{k}: true or false expected, got {v!r}")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: view.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    d, m = sec.get("default_ttl_s"), sec.get("max_ttl_s")
    if all(isinstance(x, int) and not isinstance(x, bool) for x in (d, m)) and d > m:
        errs.append(f"{name}: view.default_ttl_s {d} > max_ttl_s {m} (the default is cut to the maximum)")
    return errs


# BUG-069 (dfpilot/save.py limits()): config/baseline.json "save": the wait for a quicksave folder when DF shows no sign of
# writing, the longest wait while it writes save/current, and the age below which a verified autosave counts as the save.
# save.py keeps its default for a value of another type or out of range; lint --config refuses it.
SAVE_LIM: dict = {"wait_s": (30, 900), "max_wait_s": (60, 1800), "autosave_fresh_s": (0, 3600)}


def save_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "save" part of config/baseline.json (BUG-069): unknown keys, values dfllm save ignores,
    a max_wait_s below wait_s. A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("save", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: save must be an object"]
    errs = []
    for k, v in sec.items():
        lim = SAVE_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: save.{k}: unknown key")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: save.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    w, m = sec.get("wait_s"), sec.get("max_wait_s")
    if all(isinstance(x, int) and not isinstance(x, bool) for x in (w, m)) and m < w:
        errs.append(f"{name}: save.max_wait_s {m} < wait_s {w} (dfllm save uses wait_s)")
    return errs


# BUG-070/071 (lua/dfllm/kern.lua M.PERF): config/baseline.json "perf": quiet_s = how long heavy background work waits after a
# new year or a frame gap a DF save explains (0 = never), carry_days = how long a status key whose module gave nothing is
# published from its last known value (0 = never). kern.lua keeps its default for a value of another type or out of range;
# lint --config refuses it (tests/test_status_keep.py compares the numbers with kern.lua).
PERF_LIM: dict = {"quiet_s": (0, 600), "carry_days": (0, 400)}


def perf_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "perf" part of config/baseline.json (BUG-070/071): unknown keys, values the kernel
    ignores (another type, out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("perf", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: perf must be an object"]
    errs = []
    for k, v in sec.items():
        lim = PERF_LIM.get(k)
        if lim is None:
            errs.append(f"{name}: perf.{k}: unknown key")
        elif not (isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]):
            errs.append(f"{name}: perf.{k}: int {lim[0]}..{lim[1]} expected, got {v!r}")
    return errs


# BUG-096/BUG-097/FR-80 (lua/dfllm/burrowkeep.lua M.DEF / M.LIM): config/baseline.json "burrow": {"guard": {...}} = seal's burrow
# guard (Kern+ and the refuge are read once a game day and at a load). on = false switches it off (no reading, no record),
# shrink_pct = the share of its tiles a burrow may lose between two readings before BURROW_SHRUNK (a burrow that is gone always
# counts), repair_per_day = the tiles painted again a game day (0 = a sensor only, nothing is painted), settle_days = days
# without progress after which a loss is taken as the new baseline, every_s = the fewest real seconds between two readings (a
# game day lasts 2-12 s at the speeds of the runs; a big burrow costs a quarter of a second to read). burrowkeep.conf keeps its default for a value of another
# type or out of range; lint --config refuses it.
BURROW_GUARD_LIM: dict = {"on": "bool", "shrink_pct": (5, 95), "repair_per_day": (0, 20000), "settle_days": (1, 365),
                          "every_s": (10, 3600)}


def burrow_errors(path: str | Path | None = None) -> list[str]:
    """Problems of the optional "burrow" part of config/baseline.json (BUG-096): unknown keys, values the kernel ignores
    (another type, out of range). A missing file or part is fine."""
    p = Path(path or BASELINE_PATH)
    if not p.exists():
        return []
    name = "config/baseline.json"
    try:
        doc = json.loads(_read(p))
    except ValueError as e:
        return [f"{name}: not JSON ({e})"]
    sec = doc.get("burrow", {}) if isinstance(doc, dict) else {}
    if not isinstance(sec, dict):
        return [f"{name}: burrow must be an object"]
    errs = []
    for k, v in sec.items():
        if k != "guard":
            errs.append(f"{name}: burrow.{k}: unknown key")
        elif not isinstance(v, dict):
            errs.append(f"{name}: burrow.guard must be an object")
        else:
            for gk, gv in v.items():
                lim = BURROW_GUARD_LIM.get(gk)
                if lim is None:
                    errs.append(f"{name}: burrow.guard.{gk}: unknown key")
                elif lim == "bool":
                    if not isinstance(gv, bool):
                        errs.append(f"{name}: burrow.guard.{gk}: true or false expected, got {gv!r}")
                elif not (isinstance(gv, int) and not isinstance(gv, bool) and lim[0] <= gv <= lim[1]):
                    errs.append(f"{name}: burrow.guard.{gk}: int {lim[0]}..{lim[1]} expected, got {gv!r}")
    return errs


# BUG-042 (lua/dfllm/economy.lua M.DEFAULTS): the economy knobs of the drink line, the unvalidated-order watch, the
# manager's office and the drink gatherers ("bool", else an int range); economy.conf takes the file's part as it is,
# so a bad value here would reach the kernel: lint --config refuses it. Other economy keys are checked by the mirror
# test (tests/lua/test_economy.lua: config/baseline.json == economy.DEFAULTS).
ECONOMY_LIM: dict = {"drink": {"low_d": (0, 400)},
                     # BUG-231: bypass_days 0 = the kernel never adds the held items as workshop tasks
                     "orders": {"unval_days": (1, 60), "bypass_days": (0, 112), "bypass_max": (0, 20),
                                "bypass_open": (0, 40),
                                # BUG-315: cap 0 = no cap (duplicates still go); prune_per_day 0 = the prune is off
                                "cap": (0, 2000), "prune_days": (1, 1000), "prune_per_day": (0, 200)},
                     # BUG-232: zone = an Office zone over a lone chair when the fort has none
                     "office": {"table": "bool", "retry_days": (1, 112), "max_tiles": (1, 10000), "zone": "bool"},
                     # B2: BUG-061 slab pass, BUG-060 stale orders, FR-73 standing orders (list, frequency: checked below)
                     "slabs": {"max_orders": (0, 20), "restock_cap": (0, 30), "drop_per_day": (0, 500),
                               "trigger_ticks": (100, 33600), "scan_max": (100, 20000), "jam_min": (2, 50),
                               "engrave_days": (0, 112)},
                     "stale": {"days": (1, 112), "wait_days": (1, 112), "per_day": (0, 50), "jobs_max": (100, 20000),
                               "redo_max": (0, 20)},
                     # J3: from_phase = the phase the standing orders start in ("P0".."P7"; a number made the daily task raise)
                     "standing": {"amount": (1, 200), "request_days": (1, 112), "from_phase": "phase"},
                     "gather": {"drink_d": (0, 400), "drink_off": (0, 400)},
                     "barrels": {"brew_wait": (0, 200)},
                     # BUG-117: free cloth the kernel keeps itself (0 = off); the part's other keys: the mirror test
                     "cloth": {"floor": (0, 500)},
                     # FR-89: training weapons for the squads on the training policy (the part's other keys: the mirror test)
                     "training": {"on": "bool", "spare": (0, 50), "max_jobs": (1, 20), "from_phase": "phase"},
                     # BUG-058: the running season's slots at once, autofarm 'auto' | 'off' | 'keep' and its food-day lines
                     "farms": {"per_day": (1, 200), "now_max": (1, 200), "autofarm": ["auto", "off", "keep"],
                               "af_off_days": (0, 400), "af_on_days": (0, 400), "af_hold_days": (1, 112),
                               "fiber_slots": (0, 50)},
                     # BUG-057/FR-72: the work details follow the unclaimed jobs ("labors": job type -> labor name)
                     "cover": {"on": "bool", "min_jobs": (1, 1000), "gather_jobs": (1, 1000), "farm_per": (1, 100),
                               "farm_min": (1, 50), "farm_max": (1, 50), "gather_per": (1, 100), "gather_min": (1, 50),
                               "gather_max": (1, 50), "other_per": (1, 100), "other_max": (1, 20), "share": (5, 100),
                               "step": (1, 20), "idle_days": (1, 112), "stale_days": (1, 365), "unmark_max": (1, 400),
                               "labors": "labors"},
                     # BUG-053: stale tools, the tool pile (the part's other keys are checked by the mirror test)
                     "tools": {"stale_days": (1, 400), "keep_days": (0, 400), "pile": "bool", "pile_days": (1, 400), "pile_w": (1, 5),
                               "pile_h": (1, 5), "pile_r": (2, 40), "pile_reads": (20, 2000), "pile_every": (1, 400)},
                     # FR-76: a forbidden stock (>= burst_min drink + food units) is unforbidden burst_per_day a day
                     "forbid": {"per_day": (0, 5000), "burst_per_day": (0, 5000), "burst_min": (0, 100000)}}
ECONOMY_OWN = ("drink", "office", "farms", "cover", "slabs", "stale")   # parts whose every key is listed above
_PHASE_RE = re.compile(r"^P[0-7]$")
_LABOR_RE = re.compile(r"^[A-Z][A-Z0-9_]{1,40}$")
_JOB_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]{1,40}$")
STANDING_FREQ = ("OneTime", "Daily", "Monthly", "Seasonally", "Yearly")


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
            elif lim == "phase":
                if not (isinstance(x, str) and _PHASE_RE.match(x)):
                    errs.append(f"{name}: economy.{part}.{k}: a phase P0..P7 expected, got {x!r}")
            elif lim == "labors":
                ok = isinstance(x, dict) and len(x) <= 40 and all(
                    isinstance(a, str) and _JOB_RE.match(a) and isinstance(b, str) and _LABOR_RE.match(b)
                    for a, b in x.items())
                if not ok:
                    errs.append(f"{name}: economy.{part}.{k}: an object of job type -> LABOR names expected, got {x!r}")
            elif isinstance(lim, list):
                if x not in lim:
                    errs.append(f"{name}: economy.{part}.{k}: one of {lim} expected, got {x!r}")
            elif not (isinstance(x, int) and not isinstance(x, bool) and lim[0] <= x <= lim[1]):
                errs.append(f"{name}: economy.{part}.{k}: int {lim[0]}..{lim[1]} expected, got {x!r}")
    # FR-73: the standing orders are work orders (act.workorder: a dfllm: tag, a job type name), nothing else
    st = sec.get("standing")
    if isinstance(st, dict):
        if st.get("frequency", "Monthly") not in STANDING_FREQ:
            errs.append(f"{name}: economy.standing.frequency: one of {', '.join(STANDING_FREQ)} expected")
        lst = st.get("list", [])
        if not isinstance(lst, list):
            errs.append(f"{name}: economy.standing.list must be a list")
        else:
            for i, e in enumerate(lst):
                spec = e.get("spec") if isinstance(e, dict) else None
                if not (isinstance(e, dict) and isinstance(e.get("tag"), str) and e["tag"].startswith("dfllm:stand_")
                        and isinstance(spec, dict) and isinstance(spec.get("job"), str)
                        and re.fullmatch(r"[A-Za-z]+", spec["job"])):
                    errs.append(f"{name}: economy.standing.list[{i}]: needs a dfllm:stand_ tag and a spec with a job name")
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
OWNED_EXEMPT = frozenset({"pop-control set max-pop 100"})
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
