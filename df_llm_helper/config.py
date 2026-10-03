"""Configuration: defaults + config.yaml (mini YAML) + paths."""
from __future__ import annotations

import copy
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import yamlmini

PKG_DIR = Path(__file__).resolve().parent          # .../df-llm-helper/df_llm_helper
HOME = PKG_DIR.parent                               # .../df-llm-helper (project folder)
REPO = HOME.parent                                  # parent folder (unused in the public version)
# Shared runtime folder: env DF_LLM_HELPER_HOME (also read by lua/claude/util.lua home()), else <df-llm-helper>/runtime
RUNTIME = Path(os.environ.get("DF_LLM_HELPER_HOME") or os.environ.get("DFPILOT_HOME") or (HOME / "runtime"))

DEFAULTS: dict[str, Any] = {
    "run": 5,
    "dfhack_run": r"C:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\hack\dfhack-run.exe",
    "paths": {
        "tools": str(RUNTIME / "tools"),              # Flags, events.log, out/ (shared with the Lua companion scripts)
        "scopes": str(RUNTIME / "tools" / "scopes"),  # agent memory/inbox
        "state_db": str(HOME / "data" / "state.db"),
        "exceptions": str(HOME / "data" / "exceptions.jsonl"),
        "data": str(HOME / "data"),
        "gamelog": r"C:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\gamelog.txt",
    },
    "collect": {
        "commands": ["claude/status", "claude/report", "claude/units", "claude/mil tabelle", "claude/config",
                     "claude/tempo status", "claude/gefahr status", "claude/mood status", "claude/handel status",
                     "claude/workdetail list", "claude/orders status"],
        "timeout_s": 40,
    },
    "transport": {"batch": False, "max_bytes": 20000},   # batch=true only after a live test of pilot_batch.lua
    "thresholds": {
        "drink_days_crit": 30, "food_days_crit": 30,
        "drink_days_warn": 50, "food_days_warn": 50,
        "hunger_crit": 40000, "thirst_crit": 40000,
        "idle_pct_warn": 40, "idle_pct_delta": 10,
        "jobs_open_delta_pct": 25, "dig_jobs_delta": 20,
        "stress_high_warn": 1,
        "meals_food_flag_clear": 25, "drinks_food_flag_clear": 40,
    },
    "digest": {"max_tokens": 600, "inbox_max_lines": 6, "inbox_line_chars": 110, "inbox_scope": "orchestrator"},
    "flags": {"stale_min": 30, "names": ["alert", "caravan", "food", "siege", "mood", "migranten", "wirtschaft",
                                          "wasser", "notfall", "dig"]},
    "guard": {
        "heartbeat_slow_min": 20, "heartbeat_ok_min": 10,     # hysteresis: slow from 20 min, normal only below 10 min
        "slow_fps": 30, "normal_fps": 100,
        "report_lag_crit": 50,                                  # reports the guard has not read
        "events_stale_min": 30,
        "guard_process": "df_llm_helper waechter",              # fallback process check (otherwise out/waechter.alive)
        "agents_active_min": 15,                                # heartbeat younger than this = agent supervision active
        "tempo_supply_days": 100, "tempo_supply_hyst": 10,      # timestream only from 100 days of supplies (+10 hysteresis)
        "pop_gates": [60, 80],
        "waechter_interval_s": 2, "waechter_dead_min": 2,
    },
    # pause.hold owners/expiry (BUG-224): limits per reason, watcher release, Squads window close (holds.py)
    "holds": {"max_age_min": {"alarm": 15, "gefahr": 20, "karawane": 10, "caravan": 10, "trade": 30}, "default_max_age_min": 30,
              "alert_active_min": 5, "trade_active_max_min": 60, "auto_release": True, "squads_close_s": 30},
    "autopilot": {"max_same_action_per_hour": 6, "allow_classes": ["maintenance", "safety"], "loop_interval_s": 60},
    "kb": {"max_tokens": 400, "stale_before_run": 4},
    "anomaly": {"cancel_min": 20, "cancel_top": 3},
    "brief": {"budget": 1500},
    "metrics": {"daily_token_budget": 0},          # 0 = no daily budget
    "overlay": {"max_chars": 120, "max_lines": 3, "dedupe_min": 10},
    # Spec 01 siege autopilot; rally = [x, y, z] rally point for retreat (barracks), None = report only
    "siege": {"alert_radius": 40, "kill_radius": 45, "flee_dist": 70, "step_far": 300, "step_mid": 120, "step_near": 60,
              "min_blood_pct": 60, "max_losses": 2, "squad_alias": "Wache", "max_steps": 60, "rally": None,
              "poll_s": 3.0, "max_wait_s": 120.0},
    # Spec 02 caravan autopilot
    "caravan": {"min_ratio": 2.0, "skip_if_offer_empty": True, "stuck_ticks": 2000, "release_stuck": True,
                "wants_file": "data/trade/wants.yaml"},
    # Spec 03 mood manager (reserves from pop >= min_pop_reserve; surcharge per failed mood)
    "mood": {"reserves": {"wood": 14, "cut_gems": 10, "rough_gems": 12, "bone": 5, "leather": 3, "metal": 3,
                          "cloth": 3, "stone": 5, "silk": 2},
             "release_cutgems": True, "warn_timeout_ticks": 8000, "ticks_per_tile": 12, "work_ticks": 3000,
             "min_pop_reserve": 20, "max_releases_per_hour": 2, "fail_reserve_bump": 2},
    # Spec 04 hunger/hospital guard
    "care": {"min_doctors": 3, "pick_count": 5, "crit_hunger": 50000, "crit_thirst": 50000,
             "labors": ["DIAGNOSE", "SURGERY", "BONE_SETTING", "SUTURING", "DRESSING_WOUNDS", "FEED_WATER_CIVILIANS",
                        "RECOVER_WOUNDED"],
             "doctor_labors": ["DIAGNOSE", "SURGERY", "BONE_SETTING"], "water_cancel_hint": 50,
             "min_meals_per_head": 0.2, "max_labor_runs_per_hour": 1},
    # Spec 05 famine forecast (read only)
    "forecast": {"warn_days": 30, "crit_days": 10, "window": 5, "include_raw_plants": True, "max_points": 50,
                 "min_dt_days": 0.25},
    # Spec 06 workload control
    "workload": {"idle_warn": 40, "idle_crit": 60, "min_dig_queue": 100, "measure_after_s": 300,
                 "repeat_block_s": 600, "open_high": 50, "effect_min_pct": 5, "max_auto_per_run": 2},
    # Spec 07 bottleneck guard (read only + shopping list)
    "bottleneck": {"graph": "data/graphs/produktion.yaml", "wood_reserve": 12, "fuel_reserve": 2, "coal_reserve": 20,
                   "escalate_days": 20},
    # Spec 08 water/flood guard (boxes [x1,y1,z1,x2,y2,z2]; example values from one run)
    "water": {"watch_box": [60, 40, 126, 190, 130, 131], "fort_box": [60, 40, 126, 127, 130, 133],
              "forbid_dig": [[127, 97, 127, 181, 101, 129], [180, 40, 127, 180, 99, 128], [181, 42, 127, 189, 49, 128]],
              "notwand_blueprint": "claude/r5_notwand.csv", "chokepoints": [[128, 99, 128]], "fort_center": None,
              "rise_min": 1, "watch_in_check": True},
    # Spec 09 reboot (auto_load = title-menu load helper, only on the player's request)
    "reboot": {"services_file": "data/services.yaml", "auto_load": False, "wait_s": 20, "poll_s": 2,
               "auto_in_check": True, "findclick": "tools/embark/findclick.lua",
               "load_texts": ["Continue active game", "autosave 1"]},
    # Spec 10 subagents (transcript_dir: Claude Code project folder containing **/subagents/*.jsonl)
    "agents": {"transcript_dir": "~/.claude/projects", "max_report_lines": 12, "warn_calls": 60, "warn_output_k": 40,
               "prompt_budget": 1500, "dedupe_s": 600, "archive_dir": "out/berichte"},
    # Spec 11 dashboard (out relative to paths.tools; buildplan: list of {name, kind, min}, else dashboard.BUILDPLAN)
    "dashboard": {"out": "out/dashboard.html", "history_h": 6, "events": 20, "in_check": True, "buildplan": None},
    # Spec 12 journal (paths relative to df-llm-helper/; writes ONLY to these files and below df-llm-helper/)
    "journal": {"chronik": str(RUNTIME / "chronik.md"), "metrics": str(RUNTIME / "metrics.csv"),
                "postmortem": str(RUNTIME / "POSTMORTEM.md"),
                "append": False, "suggest_after_repeats": 2, "cluster_min": 30, "events_log": str(RUNTIME / "tools" / "events.log"),
                "kb_out": "data/kb/journal.jsonl"},
}


def _merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


@dataclass
class Config:
    data: dict

    def __getitem__(self, k: str) -> Any:
        return self.data[k]

    def get(self, dotted: str, default: Any = None) -> Any:
        cur: Any = self.data
        for part in dotted.split("."):
            if not isinstance(cur, dict) or part not in cur:
                return default
            cur = cur[part]
        return cur

    def path(self, key: str) -> Path:
        return Path(self.data["paths"][key])

    @property
    def th(self) -> dict:
        return self.data["thresholds"]


def _feature_defaults() -> dict:
    """Defaults of the feature plug-ins (df_llm_helper/features/*.py: KEY + DEFAULTS)."""
    from .features import modules
    return {m.KEY: m.DEFAULTS for m in modules() if hasattr(m, "KEY") and hasattr(m, "DEFAULTS")}


_FORCED: dict = {}      # set by the CLI for --mock/--replay-file (see force_overrides)


def force_overrides(over: dict | None) -> None:
    """Overrides that win over config.yaml (the CLI isolates --mock runs from the live state with this)."""
    _FORCED.clear()
    _FORCED.update(over or {})


_ISOLATED = (("paths", "state_db"), ("paths", "tools"), ("paths", "scopes"), ("paths", "gamelog"),
             ("journal", "events_log"))


def _same_path(a: Any, b: Any) -> bool:
    if not a or not b:
        return False
    try:
        return Path(str(a)).expanduser().resolve() == Path(str(b)).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return str(a) == str(b)


def mock_overrides(explicit_config: str | Path | None = None) -> dict:
    """--mock/--replay-file: own state.db/tools folder, so fixture warnings, flags and snapshots never leak into the
    live state (and live flags never leak into a mock run).

    BUG-104: with an explicit --config the isolation still applies to every path that equals the live one (the paths of
    the default config.yaml or the built-in defaults); only paths the explicit config points ELSEWHERE are kept."""
    base = RUNTIME / "mock"
    over = {"paths": {"state_db": str(base / "state.db"), "tools": str(base / "tools"),
                      "scopes": str(base / "tools" / "scopes"),
                      "gamelog": str(base / "gamelog.txt")},
            "journal": {"events_log": str(base / "tools" / "events.log")}}
    if not explicit_config:
        return over
    saved = dict(_FORCED)
    _FORCED.clear()
    try:
        mine = load_config(explicit_config)
        refs = [Config(_merge(copy.deepcopy(DEFAULTS), _feature_defaults()))]
        try:
            refs.append(load_config(None))
        except (ValueError, OSError):
            pass
    finally:
        _FORCED.update(saved)
    for sec, key in _ISOLATED:
        val = mine.get(f"{sec}.{key}")
        if val and not any(_same_path(val, r.get(f"{sec}.{key}")) for r in refs):
            over[sec].pop(key, None)        # the explicit config chose its own, non-live path
    return over


def _check_types(defaults: dict, loaded: dict, where: str = "") -> None:
    """BUG-113: wrong types in config.yaml give a clear error instead of a traceback deep in the code
    (a section must stay a mapping, a number must stay a number)."""
    for k, v in loaded.items():
        if k not in defaults or v is None:
            continue
        d = defaults[k]
        name = f"{where}{k}"
        if isinstance(d, dict):
            if not isinstance(v, dict):
                raise ValueError(f"config: '{name}' must be a mapping (section), got {type(v).__name__} {v!r}"[:200])
            _check_types(d, v, name + ".")
        elif isinstance(d, (int, float)) and not isinstance(d, bool):
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise ValueError(f"config: '{name}' must be a number, got {v!r}"[:200])
        elif isinstance(d, list) and not isinstance(v, list):
            raise ValueError(f"config: '{name}' must be a list, got {v!r}"[:200])


def load_config(path: str | Path | None = None, overrides: dict | None = None) -> Config:
    data = _merge(copy.deepcopy(DEFAULTS), _feature_defaults())
    p = Path(path) if path else HOME / "config.yaml"
    if p.is_file():
        loaded = yamlmini.load_file(p) or {}
        if not isinstance(loaded, dict):
            raise ValueError(f"{p}: top level must be a mapping")
        _check_types(data, loaded)
        data = _merge(data, loaded)
    if overrides:
        data = _merge(data, overrides)
    if _FORCED:
        data = _merge(data, _FORCED)
    return Config(data)
