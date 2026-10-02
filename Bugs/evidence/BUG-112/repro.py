"""BUG-112: without PYTHONUTF8/PYTHONIOENCODING (default Windows console encoding cp1252) every output containing a character
outside cp1252 aborts the command ("Error: 'charmap' codec can't encode ..."); `wake` has already consumed the events then.
Run: python Bugs/evidence/BUG-112/repro.py   (temp folder; on a machine whose default encoding is UTF-8 the A/B/C parts will not fail)"""
import os, subprocess, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
_e = {k: v for k, v in os.environ.items() if k not in ("PYTHONUTF8", "PYTHONIOENCODING")}
print("stdout encoding of a child process without PYTHONUTF8/PYTHONIOENCODING:",
      subprocess.run([sys.executable, "-c", "import sys,locale;print(sys.stdout.encoding, locale.getpreferredencoding())"], env=_e, capture_output=True).stdout.decode().strip())

base = tmp(); cfg = mkcfg(base)
section("A) overlay text with U+263C (the sun character that Dwarf Fortress puts around artifact names)")
run(["--mock", "fixtures/run5", "--config", str(cfg), "overlay", "Test \u263c ok"], utf8=False)

section("B) wake: two new CRITICAL events, one with U+263C -> error, and the events are gone on the next run")
cfg2 = mkcfg(tmp(), "wk"); log = cfg2.parent / "tools" / "events.log"
run(["--config", str(cfg2), "wake"], utf8=False)                         # baseline
with log.open("ab") as f:
    f.write("CRITICAL 12:30:00 [MASTERPIECE_CRAFTED] Urist has created a masterpiece \u263cgoblin figurine\u263c!\n".encode("utf-8"))
    f.write(b"CRITICAL 12:30:05 [CITIZEN_DEATH] Mebzuth has been found dead.\n")
run(["--config", str(cfg2), "wake"], utf8=False)
print("-> second run (events already consumed, nothing printed):")
run(["--config", str(cfg2), "wake"], utf8=False)

section("C) plan trade with a unicode item name")
(base / "t.json").write_text('{"own":[{"id":"o1","name":"Krug \u263c","category":"other","value":100,"weight":1,"qty":5}],'
                             '"offer":[{"id":"f1","name":"Brot","category":"food","value":10,"weight":1,"qty":5}]}', encoding="utf-8")
run(["plan", "trade", "--json", str(base / "t.json")], utf8=False)

section("control: the same B with PYTHONUTF8=1")
cfg3 = mkcfg(tmp(), "wk"); log3 = cfg3.parent / "tools" / "events.log"
run(["--config", str(cfg3), "wake"])
with log3.open("ab") as f:
    f.write("CRITICAL 12:30:00 [MASTERPIECE_CRAFTED] Urist has created a masterpiece \u263cgoblin figurine\u263c!\n".encode("utf-8"))
run(["--config", str(cfg3), "wake"])
