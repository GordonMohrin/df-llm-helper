"""BUG-108: `plan supply` food days differ from the digest's "Food <n>d" for the same data (plants are not counted).
Run: python Bugs/evidence/BUG-108/repro.py (mock, temp folder)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
base = tmp(); cfg = mkcfg(base); M = ["--mock", "fixtures/run5", "--config", str(cfg)]
run(M + ["digest", "--full"])
run(M + ["plan", "supply"])
print("fixtures/run5: mahlzeiten 52 + fisch 20 + fleisch 0 = 72 (plan supply) ; pflanzen 25 not counted ; status.food_days = 189")
