"""Fast rescue loop: run_rescue.lua every 10 s. Prints only when it did something. python -u tools/run_rescue.py"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")


def main():
    while True:
        try:
            r = subprocess.run([RUN, "lua", "-f", os.path.join(HERE, "run_rescue.lua")], capture_output=True, text=True, timeout=60)
            out = r.stdout.strip()
            if out:
                print(time.strftime("%H:%M:%S"), out.replace("\n", " | "))
                sys.stdout.flush()
        except Exception as e:  # noqa: BLE001
            print("rescue error", e)
            sys.stdout.flush()
        time.sleep(10)


if __name__ == "__main__":
    main()
