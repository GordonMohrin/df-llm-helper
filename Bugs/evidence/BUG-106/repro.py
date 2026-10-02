"""BUG-106: when the game cannot be read (no status/report/config answers) `tempo status`, `guard` and `tempo on`
report "no blockers / time lapse allowed" (fail-open). Run: python Bugs/evidence/BUG-106/repro.py (mock, temp folder)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp(); cfg = mkcfg(base)
# `fixtures/run5_live` has none of the files a mock expects -> every claude/* query fails, exactly like a dead dfhack-run
M = ["--mock", "fixtures/run5_live", "--config", str(cfg)]
run(M + ["heartbeat"])                      # a fresh heartbeat removes the 'no_supervision' blocker
section("DF unreadable: what do the safety commands say?")
run(M + ["digest"])
run(M + ["tempo", "status"])
run(M + ["guard"])
run(M + ["tempo", "on", "--dry-run"])
run(M + ["tempo", "on"])                    # mock: the write 'succeeds'; against a real game that only needs `claude/status` to time out
section("same data, but readable and with real blockers (control)")
run(["--mock", "fixtures/run5", "--config", str(cfg), "tempo", "status"])
section("plan armor / plan supply with an unreadable game print zeros as if they were real")
run(M + ["plan", "armor"])
run(M + ["plan", "supply"])

section("the watcher step with an unreadable game: silent, exit 0, and out/waechter.alive is refreshed (guard then believes the watcher is alive)")
run(M + ["waechter"])
alive = cfg.parent / "tools" / "out" / "waechter.alive"
print("waechter.alive exists:", alive.exists())
run(M + ["guard"])
