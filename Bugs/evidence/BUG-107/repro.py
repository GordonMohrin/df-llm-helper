"""BUG-107: `plan armor` plans a complete set for every soldier although they already wear armor.
Run: python Bugs/evidence/BUG-107/repro.py   (mock fixture fixtures/run5/mil_tabelle.txt: 'Teile/9' shows worn pieces)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
print((REPO / "fixtures/run5/mil_tabelle.txt").read_text(encoding="utf-8"))
base = tmp(); cfg = mkcfg(base)
run(["--mock", "fixtures/run5", "--config", str(cfg), "plan", "armor", "--bars", "iron=32,bronze=31"])
