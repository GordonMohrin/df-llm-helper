"""Where things live (CONTRACTS §8). Pure path logic, no DF calls.

Overrides (in this order): function args, CLI (--runtime/--save via set_overrides), env
DFLLM_DF, DFLLM_RUNTIME, DFLLM_SAVE, DFLLM_CONFIG (config/ folder, e.g. for tests).
"""
from __future__ import annotations

import os
from pathlib import Path

DEFAULT_DF = r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress"
_over: dict[str, str | None] = {"df": None, "runtime": None, "save": None}


class NoSave(LookupError):
    """No save folder could be resolved (no ACTIVE file and no save folder with state)."""


def set_overrides(df: str | None = None, runtime: str | None = None, save: str | None = None) -> None:
    _over.update(df=df, runtime=runtime, save=save)


def repo_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def df_dir() -> Path:
    return Path(_over["df"] or os.environ.get("DFLLM_DF") or DEFAULT_DF)


def runtime_root() -> Path:
    r = _over["runtime"] or os.environ.get("DFLLM_RUNTIME")
    return Path(r) if r else df_dir() / "dfllm-runtime"


def active_save() -> str | None:
    """Save folder name from <runtime>/ACTIVE (written by kern at boot, deleted at unload)."""
    try:
        line = (runtime_root() / "ACTIVE").read_text(encoding="utf-8-sig").strip().splitlines()
    except OSError:
        return None
    name = line[0].strip() if line else ""
    return name if name and "/" not in name and "\\" not in name and name not in (".", "..") else None


def _last_save() -> str | None:
    """Most recently written save folder (state or heartbeat), for when DF is not running."""
    best, best_t = None, -1.0
    try:
        dirs = [d for d in runtime_root().iterdir() if d.is_dir() and not d.name.startswith(".")]
    except OSError:
        return None
    for d in dirs:
        for f in ("heartbeat", "state.a.json", "state.b.json", "events.jsonl"):
            try:
                t = (d / f).stat().st_mtime
            except OSError:
                continue
            if t > best_t:
                best, best_t = d.name, t
    return best


def save_name(save: str | None = None) -> str:
    name = save or _over["save"] or os.environ.get("DFLLM_SAVE") or active_save() or _last_save()
    if not name:
        raise NoSave(f"no save: {runtime_root()}/ACTIVE missing and no save folder found")
    return name


def save_dir(save: str | None = None) -> Path:
    return runtime_root() / save_name(save)


def config_dir() -> Path:
    c = os.environ.get("DFLLM_CONFIG")
    return Path(c) if c else repo_dir() / "config"


def plans_dir() -> Path:
    return repo_dir() / "plans"
