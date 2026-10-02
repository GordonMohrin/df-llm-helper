"""BUG-117: report wording/semantics problems in digest/check/cycle/autopilot (several small S3 items).
Run: python Bugs/evidence/BUG-117/repro.py   (mock + temp folders)"""
import shutil, sqlite3, sys, time, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))
from core_helper import *
from df_llm_helper.store import Store

def fresh():
    b = tmp(); return b, ["--mock", "fixtures/run5", "--config", str(mkcfg(b))]

section("A) a queued crit warning from 3.5 hours ago is shown as a current '!!' line without its age")
b, M = fresh()
Store(b / "state.db").warn(time.time() - 3.5 * 3600, "reach", "reach:unreachable", "UNREACHABLE: Well (cause unknown)", "crit")
run(M + ["digest"])

section("B) `check --dry-run` is not 'dry' for the report: it consumes warnings and the delta (next real check says nothing)")
b, M = fresh()
Store(b / "state.db").warn(time.time(), "test", "t:k", "TEST-WARNING pending for the orchestrator", "crit")
run(M + ["check", "--dry-run"])
run(M + ["check"])

section("C) a death report 'resolves' on the very next call although nothing changed")
b, M = fresh()
fx = b / "fx"; shutil.copytree(REPO / "fixtures" / "run5", fx)
fa = REPO / "fixtures" / "run5"
(fx / "status.txt").write_text((fa / "status.txt").read_text(encoding="utf-8").replace('"total": 24', '"total": 22'), encoding="utf-8")
run(["--mock", str(fa), "--config", M[3], "digest"])             # pop 24
run(["--mock", str(fx), "--config", M[3], "digest"])             # pop 22 -> '!! Population -2'
run(["--mock", str(fx), "--config", M[3], "digest"])             # same -> 'ok resolved: Losses'

section("D) autopilot/cycle action lines: verify lines look the same for pass and fail; warn lines show the raw key and repeat the text 3x")
b, M = fresh()
fb = b / "fxb"; shutil.copytree(REPO / "fixtures" / "run5", fb)
(fb / "status.txt").write_text((fa / "status.txt").read_text(encoding="utf-8").replace('"drink_days": 76', '"drink_days": 25'), encoding="utf-8")
M = ["--mock", str(fb), "--config", M[3]]
import os
fl = b / "tools" / "dig.flag"; fl.write_text("09:31:47 Grabqueue niedrig: 0", encoding="utf-8"); old = time.time() - 141 * 60; os.utime(fl, (old, old))
run(M + ["autopilot"])
run(M + ["check"])

section("E) 'None' leaks into the status line / mood line when a value is missing")
b, M = fresh()
fn = b / "fxn"; shutil.copytree(REPO / "fixtures" / "run5", fn)
(fn / "report.txt").write_text('{"buerger": 24, "stimmungen_aktiv": [1, null]}', encoding="utf-8")
run(["--mock", str(fn), "--config", M[3], "digest"])

section("F) scoped digest: first call and unknown scope both say 'No change since last check.'")
b, M = fresh()
run(M + ["digest", "--scope", "trinken"])
run(M + ["digest", "--scope", "no_such_scope"])
