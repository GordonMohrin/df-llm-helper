"""Siege/intruder reflex every 5 s (Gordon 14.10.2026: "the dragon simply walked in, why did you not notice and stop it?").
- >= 3 armed invaders in sight (or any inside the fort): raise the trap-corridor bridges at once (levers) and print a loud alarm line.
- no invader in sight for QUIET s: lower them again (traffic, trade). python -u tools/run_guard.py
The bridge state is read from gate_flags.raised (the lever text is not reliable); levers are pulled with DFHack's `lever pull`."""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
QUIET = int(os.environ.get("GUARD_QUIET", "90"))
LOWER = os.environ.get("GUARD_LOWER", "0") == "1"   # 14.10. 23:41: the bridges stay UP after a siege (an army walked in over the lowered ones)


def run(args, timeout=30):
    return subprocess.run([RUN] + args, capture_output=True, text=True, timeout=timeout).stdout


def bridge_states():
    out = run(["lua", "local t={} for _,b in ipairs(df.global.world.buildings.other.BRIDGE) do t[#t+1]=b.id..':'..(b.gate_flags.raised and 'R' or 'L') end print(table.concat(t,' '))"])
    return dict((int(a), c) for a, c in (x.split(":") for x in out.split()))


_last_pull = {}


def pull_to(want_raised):
    """pull every lever whose bridge is not in the wanted state; returns the number of pulls"""
    states = bridge_states()
    levers = run(["lever", "list"])
    pat = re.compile(r"lever #(\d+) @\[[^\]]*\]\W{1,14}linked to (?:raised|lowered) Bridge #(\d+)")
    n = 0
    for lid, bid in pat.findall(levers):
        st = states.get(int(bid))
        if st is None:
            continue
        if (st == "R") != want_raised and time.time() - _last_pull.get(lid, 0) > 60:
            run(["lever", "pull", "--id", lid])
            _last_pull[lid] = time.time()
            n += 1
    return n


def main():
    quiet_since = time.time()
    last_alarm = ""
    last_peace_pull = 0.0
    last_threat_print = 0.0
    while True:
        try:
            line = run(["lua", "-f", os.path.join(HERE, "run_guard.lua")], 30).strip()
            m = dict(re.findall(r"(\w+)=(\d+)", line))
            vis, near, ins = int(m.get("visible", 0)), int(m.get("surface_near", 0)), int(m.get("inside", 0))
            raised, lowered = int(m.get("raised", 0)), int(m.get("lowered", 0))
            if vis > 0:
                quiet_since = time.time()
            threat = ins >= 1 or vis >= 3
            if threat:
                if lowered > 0:
                    n = pull_to(True)
                    if time.time() - last_threat_print > 30:   # the lever jobs stay queued until a dwarf walks there: do not spam
                        print(f"{time.strftime('%H:%M:%S')} !! GUARD INVADERS {line} -> {n} levers pulled (bridges up)")
                        sys.stdout.flush()
                        last_threat_print = time.time()
                elif line != last_alarm and ins >= 1:
                    print(f"{time.strftime('%H:%M:%S')} !! GUARD INVADERS INSIDE {line}")
                    sys.stdout.flush()
                last_alarm = line
            elif not LOWER and vis == 0 and lowered > 0 and time.time() - last_peace_pull > 120:
                n = pull_to(True)
                last_peace_pull = time.time()
                print(f"{time.strftime('%H:%M:%S')} GUARD peace: bridges kept up -> {n} levers pulled")
                sys.stdout.flush()
            elif LOWER and vis == 0 and raised > 0 and time.time() - quiet_since > QUIET:
                n = pull_to(False)
                print(f"{time.strftime('%H:%M:%S')} GUARD quiet {QUIET}s -> {n} levers pulled (bridges down)")
                sys.stdout.flush()
        except Exception as e:  # noqa: BLE001
            print("guard error", e)
            sys.stdout.flush()
        time.sleep(5)


if __name__ == "__main__":
    main()
