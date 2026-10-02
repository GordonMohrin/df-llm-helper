"""BUG-111: inbox lines beyond digest.inbox_max_lines are marked as seen and can never be fetched again
('+N more inbox lines (python -m df_llm_helper bus read)' points to the wrong place). Run: python Bugs/evidence/BUG-111/repro.py"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp(); cfg = mkcfg(base)
M = ["--mock", "fixtures/run5", "--config", str(cfg)]
scopes = base / "tools" / "scopes"; scopes.mkdir(parents=True, exist_ok=True)
(scopes / "inbox-orchestrator.md").write_text("""# Inbox
- von bau, 12:30: Tunnel fertig
- from handel, 12:31: KARAWANE IST DA, bitte handeln
- von essen, 12:32: Vorrat 20 Tage
- von a, 12:33: a1
- von a, 12:34: a2
- von a, 12:35: a3
- von a, 12:36: a4
- von a, 12:37: a5
- von a, 12:38: a6
- von a, 12:39: a7
""", encoding="utf-8")
run(M + ["digest"])
print("-> the markdown inbox has 10 messages, the digest shows the newest 6 and 'drops' 4 (incl. 'KARAWANE IST DA'):")
run(M + ["bus", "read", "--to", "orchestrator"])
run(M + ["digest", "--full"])
run(M + ["digest"])
print("-> the 4 dropped lines are gone: second digest 'No change', `bus read` empty, `digest --full` does not list the inbox.")
run(M + ["bus", "import"])      # only a manual `bus import` would have put them into the bus (not mentioned in the hint)
run(M + ["bus", "read", "--to", "orchestrator"])
