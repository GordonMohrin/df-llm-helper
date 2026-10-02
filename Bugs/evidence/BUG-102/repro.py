"""BUG-102: the danger line of the digest prints threats as raw Python dict reprs.
Run: python Bugs/evidence/BUG-102/repro.py   (mock fixture patched in a temp folder; no game needed)"""
import shutil, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp()
fx = base / "fx"
shutil.copytree(REPO / "fixtures" / "run5", fx)
s = (fx / "status.txt").read_text(encoding="utf-8")
# exact shape the live game returns (see live_status_threats_excerpt.txt)
s = s.replace('"threats": []', '"threats": [ {\n\t\t"n": 1,\n\t\t"name": "Snodub Emgen \\"Jackalluster\\", Goblin Thief"\n\t}, {\n\t\t"n": 1,\n\t\t"name": "Smunstu Ezr\u00fbamxu \\"Crewseduced\\", Goblin Thief"\n\t} ]')
(fx / "status.txt").write_text(s, encoding="utf-8")
r = (fx / "report.txt").read_text(encoding="utf-8").replace('"feinde_auf_karte": 0', '"feinde_auf_karte": 5')
(fx / "report.txt").write_text(r, encoding="utf-8")
cfg = mkcfg(base)
run(["--mock", str(fx), "--config", str(cfg), "digest"])
print("expected: '!! 5 enemies on map, Threat: Snodub Emgen \"Jackalluster\", Goblin Thief; Smunstu Ezr\u00fbamxu ...'")
