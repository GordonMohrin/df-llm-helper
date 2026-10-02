"""BUG-120: --help of the core commands: options without help text, options that do nothing, no examples, silent no-ops.
Run: python Bugs/evidence/BUG-120/repro.py   (introspects the argparse parser; mock + temp folder for the rest)"""
import argparse, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))
from core_helper import *
from df_llm_helper.cli import build_parser

CORE = "digest check cycle autopilot guard waechter tempo heartbeat wake overlay replay record budget metrics plan".split()
ap = build_parser()
sub = next(a for a in ap._actions if isinstance(a, argparse._SubParsersAction))
section("A) options/positionals of the core commands WITHOUT help text (argparse introspection)")
total = 0
for name in CORE:
    p = sub.choices[name]
    missing = [(a.option_strings[0] if a.option_strings else a.dest) for a in p._actions if a.dest != "help" and not a.help]
    total += len(missing)
    print(f"{name:10} description={'none' if not p.description else 'yes'}  no-help: {', '.join(missing) or '-'}")
print("total without help:", total)

base = tmp(); cfg = mkcfg(base); M = ["--mock", "fixtures/run5", "--config", str(cfg)]
section("B) --once is accepted by autopilot and guard but never read (cli.py: args.once unused)")
import re
src = (REPO / "df_llm_helper" / "cli.py").read_text(encoding="utf-8")
print("occurrences of 'args.once' in cli.py:", len(re.findall(r"args\.once", src)), "(siege uses it; autopilot/guard do not)")
run(M + ["autopilot", "--once"])

section("C) a global option after the sub-command gives an unhelpful argparse error (OVERVIEW shows `record --record x.jsonl`)")
run(M + ["record", "--record", str(base / "x.jsonl"), "claude/status"])
run(["--version"]); run(["help"])

section("D) --mock with a folder that does not exist / is a file is accepted; the failure shows up later as 'Query failed'")
run(["--mock", str(base / "no_such_folder"), "--config", str(cfg), "digest"])
run(["--mock", "fixtures/run5/status.txt", "--config", str(cfg), "digest"])

section("E) `digest --scope <unknown>` (see BUG-117 F) and `tempo` without action")
run(M + ["tempo"])
