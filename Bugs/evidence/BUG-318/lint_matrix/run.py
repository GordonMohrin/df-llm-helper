"""Lint rule matrix for L01..L30 (146 cases in cases.py: direct forms, evasions, look-alike identifiers).

Run from the project folder:   python Bugs/evidence/BUG-318/lint_matrix/run.py [crlf]
Writes one .lua file per case to %TEMP%/lint_cases[_crlf]/ and runs `python -m df_llm_helper lint <dir>` once.
Expected result today: 12 mismatches (6 false negatives -> BUG-318, 6 false positives -> BUG-319).
"""
import os, re, subprocess, sys, shutil, tempfile
from pathlib import Path
here = Path(__file__).parent
sys.path.insert(0, str(here))
from cases import CASES
crlf = len(sys.argv) > 1 and sys.argv[1] == "crlf"
d = Path(tempfile.gettempdir()) / ("lint_cases_crlf" if crlf else "lint_cases")
if d.exists():
    shutil.rmtree(d)
d.mkdir()
index = {}
for i, (rule, kind, code, label) in enumerate(CASES):
    fn = d / f"{i:03d}_{rule}_{kind}.lua"
    text = code + "\n"
    if crlf:
        text = text.replace("\n", "\r\n")
    fn.write_bytes(text.encode("utf-8"))
    index[fn.name] = (rule, kind, label, code)
env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
out = subprocess.run([sys.executable, "-m", "df_llm_helper", "--mock", "fixtures/run5", "lint", str(d)],
                     env=env, capture_output=True, text=True, encoding="utf-8")
found = {}
for ln in out.stdout.splitlines():
    m = re.match(r"(.*?):(\d+): (L\d+) ", ln)
    if m:
        found.setdefault(Path(m.group(1)).name, set()).add(m.group(3))
bad = 0
for name, (rule, kind, label, code) in sorted(index.items()):
    got = found.get(name, set())
    fired = rule in got
    ok = fired if kind == "pos" else not fired
    if not ok:
        bad += 1
        print(f"MISMATCH {rule} {kind}: {label!r}  -> got {sorted(got)}  code={code!r}")
print("last line:", out.stdout.strip().splitlines()[-1], "| exit", out.returncode, "| mismatches", bad, "of", len(index))
print("rules covered:", len({r for r, *_ in CASES}))
