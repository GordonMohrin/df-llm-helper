"""Utilisation monitor (Gordon 14.10.2026: utilisation is far too low - whenever it is low, work on a goal; monitor it).
Every 45 s: kernel idle % and jobless adults. Prints a line when idle > LIMIT in two samples in a row (and then at most every
3 minutes while it stays high) with the diagnosis from run_idle.lua. python -u tools/run_idle.py"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
LIMIT = int(os.environ.get("IDLE_LIMIT", "30"))


def main():
    high = 0
    last_print = 0.0
    while True:
        try:
            diag = subprocess.run([RUN, "lua", "-f", os.path.join(HERE, "run_idle.lua")], capture_output=True, text=True,
                                  timeout=60).stdout.strip()
            m = re.search(r"civ_idle=(\d+)%", diag)
            idle = int(m.group(1)) if m else -1   # civilians only: soldiers on a training routine have no job but are not idle
            if idle > LIMIT:
                high += 1
            else:
                high = 0
            if high >= 2 and time.time() - last_print > 180:
                print(f"{time.strftime('%H:%M:%S')} IDLE civilians {idle}% > {LIMIT}% | {diag}")
                sys.stdout.flush()
                last_print = time.time()
        except Exception as e:  # noqa: BLE001
            print("idle monitor error", e)
            sys.stdout.flush()
        time.sleep(45)


if __name__ == "__main__":
    main()
