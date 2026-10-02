"""Feature plug-ins (v3+). Each module in this package is discovered automatically and may define:

    KEY: str                      config section name (e.g. "perimeter")
    DEFAULTS: dict                default config for that section (merged into config.DEFAULTS[KEY])
    def register(sub) -> None     add its argparse sub-command(s) to the CLI (set_defaults(fn=...))
    def check_hook(pilot, report, dry: bool) -> list[str]
                                  optional: called by `dfpilot check`; return only lines worth showing
                                  (usually warnings); must be cheap and must never raise

Rules: modules import only the standard library and dfpilot modules at top level (no cli/config import at
module level -> no import cycles); config is read via pilot.cfg.get(KEY, {}).
"""
from __future__ import annotations

import importlib
import pkgutil

__all__ = ["modules"]

_CACHE: list | None = None


def modules() -> list:
    global _CACHE
    if _CACHE is None:
        found = []
        for m in sorted(pkgutil.iter_modules(__path__), key=lambda m: m.name):
            if not m.name.startswith("_"):
                found.append(importlib.import_module(f"{__name__}.{m.name}"))
        _CACHE = found
    return _CACHE
