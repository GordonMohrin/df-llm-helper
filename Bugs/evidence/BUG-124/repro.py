"""BUG-124: `autopilot --loop` / `guard --loop` print without flush: when stdout is a pipe/file (a background monitor), nothing arrives
until the 8 KB buffer is full. Bounded test: 3 seconds, mock data, process killed afterwards. Run: python Bugs/evidence/BUG-124/repro.py"""
import subprocess, sys, pathlib, os, re
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from core_helper import *
base = tmp(); cfg = mkcfg(base)
env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
for cmd in (["guard", "--loop", "--interval", "0.2", "--dry-run"], ["autopilot", "--loop", "--interval", "0.2", "--dry-run"]):
    p = subprocess.Popen([sys.executable, "-m", "df_llm_helper", "--mock", "fixtures/run5", "--config", str(cfg), *cmd], cwd=str(REPO), env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        out, _ = p.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill(); out, _ = p.communicate()
    print(f"{' '.join(cmd):55} -> bytes received after 3 s (process still looping, then killed): {len(out)}")
src = (REPO / "df_llm_helper" / "cli.py").read_text(encoding="utf-8")
print("\nflush=True in cmd_waechter (watcher):", len(re.findall(r"print\(ln, flush=True\)", src)), " in cmd_wake:", len(re.findall(r"print\(line, flush=True\)", src)),
      " in cmd_autopilot/cmd_guard loops: 0 (print() without flush)")
