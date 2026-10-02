"""BUG-121: `metrics` writes one row per digest call (identical rows seconds apart), 4 of the 18 columns are always empty,
`budget` 'Bytes in' is the length of the DF commands, not bytes received. Run: python Bugs/evidence/BUG-121/repro.py (mock + temp)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
base = tmp(); cfg = mkcfg(base); M = ["--mock", "fixtures/run5", "--config", str(cfg)]
for _ in range(3):
    run(M + ["digest"], echo=False)
run(M + ["cycle", "--dry-run"], echo=False)
run(M + ["metrics"])
p = run(M + ["metrics"], echo=False)
rows = [l.split(";") for l in p.text.strip().splitlines() if l.count(";") > 5]
hdr = rows[0]
empty_cols = [hdr[i] for i in range(len(hdr)) if all(r[i] == "" for r in rows[1:])]
print("columns that are empty in every row:", empty_cols)
run(M + ["budget"])
print("-> 'Bytes in' = sum of len(command) of the DF calls (cli.py _usage: sum(len(c) for c in pilot.client.calls)), not the answer size.")
