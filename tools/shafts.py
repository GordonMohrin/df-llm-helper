"""Probe shafts through a light aquifer (live L6, Gordon: "neue Schaechte bis es klappt").

Keeps a list of shaft columns (x, y, top_z) dug down to BOTTOM_Z with up/down stairs at dig priority 1.
Every pass: DF cancels damp designations, so the highest still-undug, undesignated level is designated
again (quickfort, UI-equivalent). Prints one line per shaft: dug depth, water units, state. A shaft whose
column holds >= FLOOD_UNITS of water above BOTTOM_Z+? is marked 'wet'; a shaft dug to the bottom with no
water is 'dry' (success). Usage: python tools/shafts.py [--once] (default loop every 180 s).
"""
import json
import os
import subprocess
import sys
import time

DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
BP_DIR = os.path.join(DF, "dfhack-config", "blueprints", "dfllm")
BOTTOM_Z = 111
SHAFTS = [(66, 87, 127), (40, 30, 130), (30, 50, 131), (120, 30, 127)]   # (60, 20) broke into a cavern at z120: hatch

LUA = r"""
local out = {}
local utils = require('utils')
local jobs = {}
for _, j in utils.listpairs(df.global.world.jobs.list) do jobs[j.pos.x .. ',' .. j.pos.y .. ',' .. j.pos.z] = true end
for _, s in ipairs(%s) do
  local x, y, top = s[1], s[2], s[3]
  local dug, water, gap = 0, 0, nil
  for z = top, %d, -1 do
    local tt = dfhack.maps.getTileType(x, y, z)
    local d = dfhack.maps.getTileFlags(x, y, z)
    local shape = tt and df.tiletype_shape[df.tiletype.attrs[tt].shape] or 'WALL'
    if z == top and shape == 'FLOOR' then shape = 'WALL' end   -- the surface tile becomes the stair's top
    if shape ~= 'WALL' then dug = dug + 1; water = water + d.flow_size
    elseif gap == nil then gap = {z = z, des = (jobs[x .. ',' .. y .. ',' .. z] and 1 or d.dig)} end
    if shape == 'WALL' then break end
  end
  out[#out + 1] = string.format('%%d,%%d,%%d,%%d,%%d,%%s', x, y, top, dug, water,
    gap and (gap.z .. ':' .. tostring(gap.des)) or 'bottom')
end
print(table.concat(out, ';'))
"""


def dfhack(*args):
    r = subprocess.run([RUN, *args], capture_output=True, text=True, timeout=60)
    return r.stdout.strip()


def blueprint(top, bottom):
    name = f"shaft_{top}_{bottom}.csv"
    lines = ["#dig label(shaft)", "i1"]
    for _ in range(top - bottom - 1):
        lines += ["#>", "i1"]
    lines += ["#>", "u1"]
    os.makedirs(BP_DIR, exist_ok=True)
    with open(os.path.join(BP_DIR, name), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return "dfllm/" + name


def one_pass():
    raw = dfhack("lua", LUA % (json.dumps([list(s) for s in SHAFTS]).replace("[", "{").replace("]", "}"), BOTTOM_Z))
    lines = []
    for rec in raw.split(";"):
        try:
            x, y, top, dug, water, gap = rec.split(",")
        except ValueError:
            lines.append(f"? {rec}")
            continue
        x, y, top, dug, water = int(x), int(y), int(top), int(dug), int(water)
        depth = top - BOTTOM_Z + 1
        state = "dry" if gap == "bottom" and water == 0 else ("wet" if water >= 7 else "digging")
        if gap != "bottom":
            gz, des = gap.split(":")
            gz = int(gz)
            if des == "0" and gz >= BOTTOM_Z:       # DF cancelled the designation (damp): designate again
                dfhack("quickfort", "run", blueprint(gz, BOTTOM_Z), "--cursor", f"{x},{y},{gz}")
                state += f" redesignated z{gz}"
        lines.append(f"shaft {x},{y}: {dug}/{depth} levels, water {water} -> {state}")
    return " | ".join(lines)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    once = "--once" in sys.argv
    while True:
        print(time.strftime("%H:%M"), one_pass(), flush=True)
        if once:
            break
        time.sleep(180)
