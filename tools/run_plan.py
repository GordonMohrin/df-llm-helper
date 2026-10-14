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
    d["trade"] = {"sell": ["crafts"], "want": ["seeds", "bar:iron", "bar:copper", "bar:bronze", "wood", "bone", "meal", "meat",
                                              "cheese", "drink", "pick", "axe", "anvil", "cloth", "leather", "thread"]}
    json.dump(d, open(path, "w"), indent=1)
    out = run(["plan", "check", path])
    print(out.strip().splitlines()[-1] if out.strip() else "check: no output")
    if "plan OK" in out:
        print(run(["plan", "apply", path]).strip().splitlines()[-1])


if __name__ == "__main__":
    main()
