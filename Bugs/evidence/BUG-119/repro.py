"""BUG-119: documentation contradictions found while running the documented examples.
Run: python Bugs/evidence/BUG-119/repro.py   (reads docs, runs selftest --quick and the documented record example)"""
import re, subprocess, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

def grep(pattern, *files):
    for f in files:
        for i, l in enumerate((REPO / f).read_text(encoding="utf-8").splitlines(), 1):
            if re.search(pattern, l):
                print(f"  {f}:{i}: {l.strip()[:190]}")

section("1) Python version")
grep(r"Python 3\.1\d|3\.1\d\+|3\.12 or newer|python3\.12|# 3\.12", "README.md", "docs/OVERVIEW.md", "docs/MANUAL.md", "docs/PLANNERS.md", "docs/INTEGRATION.md")
section("2) OVERVIEW: `record --record x.jsonl [commands]` (documented form) vs MANUAL: `--record x.jsonl record <command>`")
grep(r"record --record|--record x.jsonl record", "docs/OVERVIEW.md", "docs/MANUAL.md")
base = tmp(); cfg = mkcfg(base)
run(["--mock", "fixtures/run5", "--config", str(cfg), "record", "--record", str(base / "x.jsonl"), "claude/status"])      # OVERVIEW form
run(["--mock", "fixtures/run5", "--config", str(cfg), "--record", str(base / "x.jsonl"), "record", "claude/status"])      # MANUAL form
section("3) file names")
grep(r"LINT-BEFUNDE|LINT-FINDINGS", "docs/OVERVIEW.md")
print("  docs/ contains:", sorted(p.name for p in (REPO / "docs").glob("LINT*")))
section("4) what is lua/ and which files are installed?")
grep(r"pilot_wd\.lua|pilot_\*\.lua|lua/claude/\*\.lua", "README.md", "docs/MANUAL.md", "docs/OVERVIEW.md", "COMPANION.md")
print("  lua/ contains:", len(list((REPO / "lua").glob("pilot_*.lua"))), "pilot_*.lua and", len(list((REPO / "lua/claude").glob("*.lua"))), "claude/*.lua")
section("5) selftest: documented duration / exit code without pytest")
grep(r"~10 s|≈ 30 s|needs pytest", "README.md", "docs/MANUAL.md")
for extra in (["--quick"], []):
    p = subprocess.run([sys.executable, "-m", "df_llm_helper.selftest", *extra], cwd=str(REPO), capture_output=True, text=True, encoding="utf-8")
    tail = [l for l in p.stdout.strip().splitlines() if l.strip()][-1]
    print(f"  selftest {' '.join(extra) or '(no flag)':8} exit={p.returncode}  last line: {tail}")
print("  -> without pytest the full run prints a '[!]' hint and exits 0 (looks green to a script); nothing like 'Self-test GREEN' / 'NOT RUN'.")
section("6) OVERVIEW 'Structure' section names")
grep(r"^`df-llm-helper/`|`df-llm-helper/`", "docs/OVERVIEW.md")
print("  actual package folder:", [p.name for p in REPO.iterdir() if p.is_dir() and p.name.startswith(("df_", "df-"))])
