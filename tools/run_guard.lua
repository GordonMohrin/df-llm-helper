-- 5 s guard probe (Gordon 14.10.2026: "the dragon simply walked in - why did you not notice at once?").
-- Prints one line: invaders on the surface near the fort, invaders inside (z <= 117), bridges raised/lowered. Read-only.
local out_inv, ins, near, races = 0, 0, 0, {}
for _, u in ipairs(df.global.world.units.active) do
  if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and dfhack.units.isInvader(u) and not dfhack.units.isCitizen(u)
     and not dfhack.units.isGhost(u) then
    local p = xyz2pos(dfhack.units.getPosition(u))
    local f = dfhack.maps.getTileFlags(p)
    local r = df.creature_raw.find(u.race).creature_id
    if f and not f.hidden then
      out_inv = out_inv + 1
      if p.z <= 117 then ins = ins + 1; races[#races + 1] = r:sub(1, 6) .. '@z' .. p.z .. ',' .. p.x .. ',' .. p.y
      elseif p.x >= 0 and p.x <= 140 and p.y >= 20 and p.y <= 140 then near = near + 1 end
    end
  end
end
local raised, lowered = 0, 0
for _, b in ipairs(df.global.world.buildings.other.BRIDGE) do
  if b.gate_flags.raised then raised = raised + 1 else lowered = lowered + 1 end
end
print(string.format('visible=%d surface_near=%d inside=%d raised=%d lowered=%d where=[%s]', out_inv, near, ins, raised, lowered, table.concat(races, ' ')))
