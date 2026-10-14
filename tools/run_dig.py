"""Fast dig loop for Run 9: hidden tiles cannot be designated, so each wave only opens the visible edge of a room.
Re-applying the dig program every 25 s lets the miners work through a big hall in minutes instead of hours.
Own state file (the watcher keeps its own). python -u tools/run_dig.py"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_watch as rw  # noqa: E402

DIGSTATE = os.path.join(os.path.dirname(rw.JOURNAL), ".dig_state.json")


def main():
    last = None
    while True:
        try:
            st = json.load(open(DIGSTATE, encoding="utf-8"))
        except Exception:  # noqa: BLE001
            st = {}
        msg = rw.dig_program(st)
        json.dump(st, open(DIGSTATE, "w", encoding="utf-8"))
        left = sum(1 for e in st.get("dig", {}).values() if not e.get("done"))
        if left != last:  # quiet: only report when the number of open plans changes
            print(f"{time.strftime('%H:%M:%S')} {msg} | offen: {left}")
            sys.stdout.flush()
            last = left
        if not left:
            print("Grabprogramm abgeschlossen")
            return
        time.sleep(25)


if __name__ == "__main__":
    main()
