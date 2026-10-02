"""BUG-123: the JSON accepted by `plan trade --json` is not documented (field names), `priorities` cannot be passed, and the
default priority list silently excludes categories such as 'gem' or 'seeds'. Run: python Bugs/evidence/BUG-123/repro.py"""
import json, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
here = pathlib.Path(__file__).resolve().parent
run(["plan", "trade", "--help"])
base = tmp()
d = json.loads((here / "working_example_trade.json").read_text(encoding="utf-8"))
section("A) the example with the shape of TradeItem (id,name,category,value,weight,qty) works; 'gem' is never bought")
run(["plan", "trade", "--json", str(here / "working_example_trade.json")])
d["priorities"] = ["gem", "food"]                     # PLANNERS.md: plan_trade(..., priorities=...) - not read by the CLI
(base / "prio.json").write_text(json.dumps(d), encoding="utf-8")
section("B) same file with \"priorities\": [\"gem\", \"food\"] -> ignored (same result, no warning)")
run(["plan", "trade", "--json", str(base / "prio.json")])
section("C) a plausible hand-written file (field names guessed: 'price', 'amount') -> traceback")
(base / "guess.json").write_text('{"own":[{"name":"mug","price":100,"amount":3}],"offer":[{"name":"log","price":10,"amount":9}]}', encoding="utf-8")
run(["plan", "trade", "--json", str(base / "guess.json")])
