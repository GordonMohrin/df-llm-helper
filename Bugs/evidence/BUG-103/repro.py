"""BUG-103: a --config file that does not exist is silently ignored; the defaults (incl. the live data/state.db) are used.
Run: python Bugs/evidence/BUG-103/repro.py   (read-only: only loads the configuration, writes nothing)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
sys.path.insert(0, str(REPO))
from df_llm_helper.config import load_config

for name in ("config.yaml", "tpyo-config.yaml", r"C:\no\such\dir\config.yaml"):
    c = load_config(name if pathlib.Path(name).is_absolute() else REPO / name)
    print(f"--config {name!r:34} exists={pathlib.Path(name).exists() if pathlib.Path(name).is_absolute() else (REPO / name).exists()!s:5} -> state_db={c.path('state_db')}  tools={c.path('tools')}  dfhack_run={c.get('dfhack_run')}")
print("\n-> a misspelled/missing --config path gives no error and silently selects data/state.db + runtime/tools + the default DFHack path.")
