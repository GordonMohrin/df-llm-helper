"""BUG-113: input/IO errors end in raw Python tracebacks (exit 1) instead of one-line errors (exit 2).
Run: python Bugs/evidence/BUG-113/repro.py   (temp folder; prints for each case the verdict + the last line)"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *

base = tmp(); cfg = mkcfg(base)
(base / "afile").write_text("x"); (base / "list.json").write_text("[]"); (base / "missing_fields.json").write_text('{"own":[{"id":"x"}],"offer":[]}')
(base / "badtype.yaml").write_text("guard: 5\n"); (base / "badnum.yaml").write_text("thresholds:\n  drink_days_crit: abc\n")
(base / "empty.jsonl").write_text("")
cases = {
 "replay <missing file>":              ["replay", str(base / "nope.jsonl")],
 "replay <directory>":                 ["replay", str(base)],
 "replay <empty file> (false OK)":     ["replay", str(base / "empty.jsonl")],
 "plan blueprint <missing file>":      ["plan", "blueprint", str(base / "nope.csv")],
 "plan blueprint <directory>":         ["plan", "blueprint", str(base)],
 "plan trade (no --json)":             ["plan", "trade"],
 "plan trade --json <missing>":        ["plan", "trade", "--json", str(base / "nope.json")],
 "plan trade --json <directory>":      ["plan", "trade", "--json", str(base)],
 "plan trade --json <list root>":      ["plan", "trade", "--json", str(base / "list.json")],
 "plan trade --json <item w/o fields>":["plan", "trade", "--json", str(base / "missing_fields.json")],
 "plan dig --area-file <missing>":     ["plan", "dig", "--area-file", str(base / "nope.txt"), "--targets", "1,1"],
 "metrics --out <missing dir>":        ["metrics", "--out", str(base / "no" / "dir" / "m.csv")],
 "metrics --out <directory>":          ["metrics", "--out", str(base)],
 "heartbeat (tools path is a file)":   ["--config", str(mkcfg(base / "t2", "c2", "")).replace("c2", "c2"), "heartbeat"],
 "--config <directory>":               ["--config", str(base), "digest"],
 "--config guard: 5 (wrong type)":     ["--mock", "fixtures/run5", "--config", str(base / "badtype.yaml"), "guard"],
 "--config thresholds: abc":           ["--mock", "fixtures/run5", "--config", str(base / "badnum.yaml"), "digest", "--full"],
}
# make the tools path of the 'heartbeat' case a file
t2 = base / "t2"; (t2 / "tools").rmdir(); (t2 / "tools").write_text("I am a file")
for name, args in cases.items():
    if name.startswith(("--config <dir", "heartbeat")):
        pass
    p = run(args if name.startswith("heartbeat") else (args if "--config" in args else (["--config", str(cfg)] + args)), echo=False)
    last = [l for l in p.text.strip().splitlines() if l.strip()][-1:] or ["<no output>"]
    kind = "TRACEBACK" if "Traceback (most recent call last)" in p.text else "message  "
    print(f"{kind} exit={p.returncode}  {name:38}  | {last[0][:150]}")
