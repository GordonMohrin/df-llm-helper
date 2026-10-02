"""BUG-101: `overlay` (even without --send) consumes the orchestrator's digest delta and then sends 'No change' texts.
Run: python Bugs/evidence/BUG-101/repro.py   (mock data, temp folder only)"""
import shlex, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp()
cfg = mkcfg(base)
M = ["--mock", "fixtures/run5", "--config", str(cfg)]
section("A) overlay FIRST (display only, no --send), then the orchestrator's digest")
run(M + ["overlay"])
run(M + ["digest"])
print("-> expected: digest still reports the hunger/caravan items (the orchestrator never saw them); actual: 'No change since ...'")

section("B) second overlay call: the player display gets a useless 'No change' line")
run(M + ["overlay", "--send"])
run(M + ["overlay", "--send"])

section("C) control: digest first, then overlay -> overlay shows only the status line / No change")
base2 = tmp(); cfg2 = mkcfg(base2); M2 = ["--mock", "fixtures/run5", "--config", str(cfg2)]
run(M2 + ["digest"])
run(M2 + ["overlay"])

section("D) side issue: the send command is split with shlex(posix=True) by RealClient; a trailing backslash breaks it")
for text in [r'claude/schau say "Path C:\dir\" 3', 'claude/schau say "ok text" 3']:
    try:
        print(repr(text), "->", shlex.split(text, posix=True))
    except ValueError as e:
        print(repr(text), "-> ValueError:", e, "   (main() prints 'Error: No closing quotation', exit 2)")
