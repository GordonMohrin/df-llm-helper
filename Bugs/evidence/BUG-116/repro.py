"""BUG-116: `wake` reports harmless message types as WAKE critical and prints legacy mojibake.
Run: python Bugs/evidence/BUG-116/repro.py   (uses sample_events_from_live_log.txt = verbatim lines of the live events.log)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
here = pathlib.Path(__file__).resolve().parent
base = tmp(); cfg = mkcfg(base); log = base / "tools" / "events.log"
run(["--config", str(cfg), "wake"])                                  # baseline on an empty log
log.write_bytes((here / "sample_events_from_live_log.txt").read_bytes())
run(["--config", str(cfg), "wake"])
print("-> VOMIT / RESOLVE_SHARED_ITEMS / DODGE_FLYING_OBJECT / NO_BREAK_GRIP / MASTERPIECE_CRAFTED are not actionable (they contain the word 'goblin');")
print("   lines with '├«'/'Γÿ╝' are CP437 mojibake of UTF-8 written by the old PowerShell watcher (journal.fix_mojibake repairs them, wake does not).")
