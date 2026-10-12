"""Designate safe stone-wall tiles for quarrying when the fort has no free boulders (Gordon's fort, 12.10.2026).

    python tools/quarry.py [N]     designate up to N (default 90) revealed stone walls via quickfort

A tile qualifies when it is revealed, plain stone (not soil, not smoothed), not wet, outside every zone
(2-tile margin), has no building, and exactly one of its six neighbours is open and reachable from a citizen:
digging it can never join two areas. Hidden tiles are never read.
"""
import collections
import os
import subprocess
import sys
import tempfile

DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
BP = os.path.join(DF, "dfhack-config", "blueprints", "dfllm")
LUA = r"""
local N=%d
local cit=dfhack.units.getCitizens(true)[1]
local g=dfhack.maps.getWalkableGroup(xyz2pos(dfhack.units.getPosition(cit)))
local function info(p) local ok,tt=pcall(dfhack.maps.getTileType,p) if not ok or not tt then return nil end local a=df.tiletype.attrs[tt] return df.tiletype_shape[a.shape], df.tiletype_material[a.material], df.tiletype_special[a.special] end
local zones={} for _,z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do zones[#zones+1]=z end
local function inzone(p) for _,z in ipairs(zones) do if p.z==z.z and p.x>=z.x1-2 and p.x<=z.x2+2 and p.y>=z.y1-2 and p.y<=z.y2+2 then return true end end return false end
local n=0
for _,b in ipairs(df.global.world.map.map_blocks) do
 for x=0,15 do for y=0,15 do
  local p=xyz2pos(b.map_pos.x+x,b.map_pos.y+y,b.map_pos.z) local d=b.designation[x][y]
  if n<N and not d.hidden and d.dig==0 and d.flow_size==0 and not d.water_table then
   local s,m,sp=info(p)
   if s=='WALL' and m=='STONE' and sp~='SMOOTH' and not inzone(p) then
    local open,reach=0,false
    for _,dd in ipairs({{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) do
     local q=xyz2pos(p.x+dd[1],p.y+dd[2],p.z+dd[3]) local qs=info(q)
     if qs and qs~='WALL' then open=open+1 if dfhack.maps.getWalkableGroup(q)==g then reach=true end end end
    if open==1 and reach and not dfhack.buildings.findAtTile(p) then print(p.x,p.y,p.z) n=n+1 end end end end end end
"""


def main(n):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(LUA % n)
    out = subprocess.run([RUN, "lua", "-f", f.name], capture_output=True, text=True, timeout=120).stdout
    os.unlink(f.name)
    pts = [tuple(map(int, ln.split())) for ln in out.splitlines() if len(ln.split()) == 3]
    by_z = collections.defaultdict(list)
    for p in pts:
        by_z[p[2]].append(p)
    total = 0
    for z, pl in by_z.items():
        x0, y0 = min(p[0] for p in pl), min(p[1] for p in pl)
        x1, y1 = max(p[0] for p in pl), max(p[1] for p in pl)
        s = {(p[0], p[1]) for p in pl}
        rows = [",".join("d" if (x, y) in s else "`" for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
        name = f"quarry_auto_{z}.csv"
        with open(os.path.join(BP, name), "w", encoding="utf-8") as fh:
            fh.write(f"#dig label(qa_{z})\n" + "\n".join(rows) + "\n")
        r = subprocess.run([RUN, "quickfort", "run", "dfllm/" + name, "--cursor", f"{x0},{y0},{z}"],
                           capture_output=True, text=True, timeout=120).stdout
        total += len(pl)
        print(z, len(pl), r.strip().splitlines()[-1] if r.strip() else "")
    print(f"{total} stone walls designated")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 90)
