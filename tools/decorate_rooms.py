"""Smooth (then engrave) the living rooms - never tunnels, shafts or quarries (Gordon, 11.10.2026).

    python tools/decorate_rooms.py smooth      designate smoothing for floors and walls of every living-room zone
    python tools/decorate_rooms.py engrave     designate engraving once the smoothing is done

Living rooms = Bedroom, DiningHall, Office, MeetingHall (temple, hospital, meeting area) zones. Only the zone
rectangle plus a one-tile ring (the room's own walls) is touched; DF skips tiles that cannot be smoothed
(doors, furniture, soil). Uses quickfort like a player would; read the zone list from the game with Lua.
"""
import os
import re
import subprocess
import sys

DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
BP = os.path.join(DF, "dfhack-config", "blueprints", "dfllm")

LUA = r"""
local want = {Bedroom = true, DiningHall = true, Office = true, MeetingHall = true}
for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
  local t = df.civzone_type[z.type]
  if want[t] then print(string.format('%d,%d,%d,%d,%d,%s', z.x1, z.y1, z.x2, z.y2, z.z, t)) end
end
"""


def dfhack(*args):
    return subprocess.run([RUN, *args], capture_output=True, text=True, timeout=120).stdout


def zones():
    out = dfhack("lua", LUA)
    res = []
    for ln in out.splitlines():
        p = ln.split(",")
        if len(p) == 6 and all(x.lstrip("-").isdigit() for x in p[:5]):
            res.append(tuple(int(x) for x in p[:5]))
    return sorted(set(res))


def main(mode):
    sym = {"smooth": "s", "engrave": "e"}[mode]
    os.makedirs(BP, exist_ok=True)
    n = total = 0
    for x1, y1, x2, y2, z in zones():
        w, h = x2 - x1 + 3, y2 - y1 + 3                      # the zone and a ring of one tile
        rows = [",".join(sym for _ in range(w)) for _ in range(h)]
        name = f"deco_{mode}.csv"
        with open(os.path.join(BP, name), "w", encoding="utf-8") as f:
            f.write(f"#dig label({mode})\n" + "\n".join(rows) + "\n")
        out = dfhack("quickfort", "run", "dfllm/" + name, "--cursor", f"{x1 - 1},{y1 - 1},{z}")
        n += 1
        g = re.search(r"designated for digging: (\d+)", out)
        total += int(g.group(1)) if g else 0
    print(f"{mode}: {n} living-room zones, {total} tiles designated (soil and furniture tiles are skipped)")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("smooth", "engrave"):
        sys.exit(__doc__)
    main(sys.argv[1])
