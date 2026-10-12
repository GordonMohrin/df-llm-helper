-- Give each noble (mayor, manager, bookkeeper) a free Office zone and the mayor a free DiningHall zone when they have none
-- (an election or a death leaves the rooms with their old owners). Fort-side only: dfhack-run lua -f tools/nobles_rooms.lua
local zones = df.global.world.buildings.other.ACTIVITY_ZONE
local function owner_alive(z)
  if z.assigned_unit_id < 0 then return false end
  local u = df.unit.find(z.assigned_unit_id)
  return u and dfhack.units.isAlive(u)
end
local function holds(u, t)
  for _, z in ipairs(zones) do
    if df.civzone_type[z.type] == t and z.assigned_unit_id == u.id then return true end
  end
  return false
end
local function give(u, t)
  if holds(u, t) then return end
  for _, z in ipairs(zones) do
    if df.civzone_type[z.type] == t and z.name ~= 'Tavern' and z.name ~= 'Dining' and not owner_alive(z) then
      dfhack.buildings.setOwner(z, u)
      print('assigned', t, z.id, 'to', u.id)
      return
    end
  end
  print('no free', t, 'for', u.id)
end
for _, role in ipairs({'mayor', 'manager', 'bookkeeper'}) do
  local u = dfhack.units.getUnitByNobleRole(role)
  if u and dfhack.units.isAlive(u) then
    give(u, 'Office')
    if role == 'mayor' then give(u, 'DiningHall') end
  end
end
