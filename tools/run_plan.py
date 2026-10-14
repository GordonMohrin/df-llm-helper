"""Yearly plan for Run 9: propose, set Gordon's standing values, check, apply (python tools/run_plan.py).
No build entries (room templates need the fortcore manifest, FR-13); the fort is built by quickfort/blueprints in
runs/run-9-neues-fort. Standing values: mood stock 20, trade wants (seeds first), sell crafts and gems."""
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = [sys.executable, "-m", "df_llm_helper"]


def run(args):
    return subprocess.run(CLI + args, capture_output=True, text=True, cwd=REPO, timeout=120).stdout


def main():
    path = os.path.join(tempfile.gettempdir(), "run_plan_draft.json")
    run(["plan", "propose", path])
    d = json.load(open(path))
    d["seasons"] = [{"build": []} for _ in d.get("seasons", [])] or [{"build": []}] * 4
    d.setdefault("supply", {})["mood_stock"] = 20
    # J353: 1300 silk cloth and 8000 thread sit in the stores; buy metal, leather, bone, seeds, tools, wood; sell crafts, cloth, thread
    d["trade"] = {"sell": ["crafts", "cloth", "thread"], "want": ["bar:iron", "bar:copper", "bar:bronze", "leather", "bone", "seeds",
                                                                   "pick", "axe", "anvil", "wood", "meat"]}
    # Gordon rule 5 (every adult trains >= 3 months a year): 50 % of the adults in squads (21 citizens died in the 14.10. siege with 10 soldiers; training is also work). The DF crashes of 14.10. blamed on this value
    # were caused by manager orders without item_subtype (FR-39), not by the military plan.
    d.setdefault("military", {}).update({"pct": 50})
    json.dump(d, open(path, "w"), indent=1)
    out = run(["plan", "check", path])
    print(out.strip().splitlines()[-1] if out.strip() else "check: no output")
    if "plan OK" in out:
        print(run(["plan", "apply", path]).strip().splitlines()[-1])


if __name__ == "__main__":
    main()
