"""BUG-100: `wake` never sees new events once events.log has more than 5000 lines.
Run: python Bugs/evidence/BUG-100/repro.py   (temporary folder only, no game needed)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

for n in (100, 5100):
    section(f"events.log with {n} filler lines, then one CRITICAL line appended")
    base = tmp()
    cfg = mkcfg(base)
    log = base / "tools" / "events.log"
    log.write_text("".join(f"info 10:00:00 [X] filler {i}\n" for i in range(n)), encoding="utf-8")
    run(["--config", str(cfg), "wake"])                       # baseline (first run reports nothing)
    with log.open("a", encoding="utf-8") as f:
        f.write("CRITICAL 10:05:00 [FEATURE_BEAST] A forgotten beast has come!\n")
    print(f"-> expected: WAKE critical [FEATURE_BEAST] ... (lines in file: {len(log.read_text().splitlines())})")
    run(["--config", str(cfg), "wake"])
