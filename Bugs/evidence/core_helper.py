"""Helper for the repro scripts of BUG-100..BUG-199 (core tester). Standard library only.

Usage in a repro script:
    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from core_helper import *

Every repro script runs from anywhere; it works on a temporary folder (never on data/state.db or the live tools folder)
unless the script says otherwise. `run()` prints the command, its output and the exit code (this is what `output.txt`
next to the script contains).
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def tmp(prefix: str = "dfh_core_") -> Path:
    return Path(tempfile.mkdtemp(prefix=prefix))


def mkcfg(base: Path, name: str = "cfg", extra: str = "") -> Path:
    """config.yaml with state.db / tools / scopes / gamelog inside `base`; returns the config path."""
    (base / "tools").mkdir(parents=True, exist_ok=True)
    cfg = base / f"{name}.yaml"
    cfg.write_text(
        f"paths:\n  tools: '{base / 'tools'}'\n  scopes: '{base / 'tools' / 'scopes'}'\n"
        f"  state_db: '{base / 'state.db'}'\n  gamelog: '{base / 'gamelog.txt'}'\n" + extra, encoding="utf-8")
    return cfg


def run(args: list[str], *, env: dict | None = None, utf8: bool = True, echo: bool = True,
        input_text: str | None = None) -> subprocess.CompletedProcess:
    """python -m df_llm_helper <args> from the repo folder. utf8=False removes PYTHONUTF8/PYTHONIOENCODING (default
    Windows console encoding, e.g. cp1252)."""
    e = dict(os.environ)
    if utf8:
        e["PYTHONIOENCODING"] = "utf-8"
        e["PYTHONUTF8"] = "1"
    else:
        e.pop("PYTHONIOENCODING", None)
        e.pop("PYTHONUTF8", None)
    e.update(env or {})
    p = subprocess.run([sys.executable, "-m", "df_llm_helper", *args], cwd=str(REPO), env=e, capture_output=True,
                       input=input_text.encode("utf-8") if input_text is not None else None)
    out = p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace")
    if echo:
        print("$ python -m df_llm_helper " + " ".join(f'"{a}"' if " " in a else a for a in args))
        print(out.rstrip("\n"))
        print(f"[exit={p.returncode}]\n")
    p.text = out  # type: ignore[attr-defined]
    return p


def section(title: str) -> None:
    print(f"\n===== {title} =====")
