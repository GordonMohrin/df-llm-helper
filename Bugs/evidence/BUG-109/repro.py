"""BUG-109: `plan blueprint` reports errors for blueprints that quickfort accepts (and that were used in the live game).
Run: python Bugs/evidence/BUG-109/repro.py   (reads only the sample files next to this script)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
d = pathlib.Path(__file__).resolve().parent / "blueprints"
for f in sorted(d.glob("*.csv")):
    print("-----", f.name); print(f.read_text(encoding="utf-8").rstrip()[:500]); print()
run(["plan", "blueprint", *[str(f) for f in sorted(d.glob("*.csv"))]])
