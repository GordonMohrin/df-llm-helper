"""BUG-110: the CLI never passes map_size/origin, so E_BOUNDS can never be reported; the repo's own 'bad' test file passes.
Run: python Bugs/evidence/BUG-110/repro.py"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
sys.path.insert(0, str(REPO))
f = REPO / "tests" / "blueprints_bad" / "bad_footprint_outside_map.csv"
print(f.read_text(encoding="utf-8"))
print("EXPECTED.txt says:", [l for l in (REPO / "tests/blueprints_bad/EXPECTED.txt").read_text().splitlines() if "footprint" in l])
run(["plan", "blueprint", str(f)])
from df_llm_helper.planners import validate_blueprint
print("API with map_size:", [str(x) for x in validate_blueprint(f.read_text(encoding="utf-8"), map_size=(192, 192, 153))])
