"""BUG-104: --mock together with an explicit --config is not isolated: the mock run changes the configured tools folder
(deletes real flag files) and state.db. Run: python Bugs/evidence/BUG-104/repro.py   (temp folder only)"""
import os, sys, time, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp()
cfg = mkcfg(base)                               # stands for the player's config.yaml (paths -> the real/live tools folder)
flag = base / "tools" / "alert.flag"
flag.write_text("11:46:50 [AMBUSH_SNATCHER] Snatcher!  Protect the children!", encoding="utf-8")
old = time.time() - 238 * 60
os.utime(flag, (old, old))
section("A) a REAL (stale) alert.flag lies in the configured tools folder")
print("flag exists before:", flag.exists())
run(["--mock", "fixtures/run5", "--config", str(cfg), "autopilot"])
print("flag exists after :", flag.exists(), "   state.db written:", (base / "state.db").exists())
print("-> a MOCK run deleted the real flag file and wrote its fixture data (pop 24, Y102) into the configured state.db")

section("B) control: --mock WITHOUT --config is isolated (runtime/mock, temp via DF_LLM_HELPER_HOME)")
home = tmp()
(base / "tools" / "alert.flag").write_text("again", encoding="utf-8"); os.utime(flag, (old, old))
run(["--mock", "fixtures/run5", "autopilot"], env={"DF_LLM_HELPER_HOME": str(home)})
print("flag exists after control run (must be True):", flag.exists())
