"""BUG-114: arguments are accepted without validation and some of them write junk into state.db.
Run: python Bugs/evidence/BUG-114/repro.py   (mock + temp folder)"""
import sqlite3, sys, pathlib, json
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp(); cfg = mkcfg(base); M = ["--mock", "fixtures/run5", "--config", str(cfg)]
section("autopilot enable <nothing / unknown rule>")
run(M + ["autopilot", "enable"])
run(M + ["autopilot", "enable", "no_such_rule"])
c = sqlite3.connect(base / "state.db")
print("rule_state rows now:", c.execute("select rule, disabled from rule_state").fetchall(), "   <- junk rows 'None' and 'no_such_rule'")

section("guard ack-gate <nothing / negative / a gate that does not exist>")
run(M + ["guard", "ack-gate"])
run(M + ["guard", "ack-gate", "-5"])
run(M + ["guard", "ack-gate", "61"])
gs = c.execute("select value from kv where key='guard.state'").fetchone()
print("guard.state.gates_acked:", json.loads(gs[0])["gates_acked"] if gs else None, "   <- None, -5, 61 stored (valid gates are config guard.pop_gates = [60, 80])")

section("plan armor / plan supply: malformed or unknown inputs are ignored silently")
run(M + ["plan", "armor", "--bars", "iron"])                 # no '=' -> ignored
run(M + ["plan", "supply", "--prod", "bogus=5"])             # unknown resource -> ignored
run(M + ["plan", "supply", "--growth", "-1"])                # negative immigrants accepted
run(M + ["plan", "dig", "--area-file", "fixtures/run5/area_z130.txt"])      # no --targets: no output, exit 0
run(M + ["plan", "blueprint"])                               # no files: no output, exit 0
