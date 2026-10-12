-- Periodic fort upkeep (Paddletribes y366): dfhack-run lua -f tools/maintain.lua
-- 1. tomb zones that are not assigned to one unit accept citizens (the tombs template creates them with
--    no_citizens=true, so nobody was ever buried there: 116 loose corpses, 55 ghosts)
-- 2. suspended construction jobs resume (DF suspends them when an item is in the way; suspendmanager is off)
local opened = 0
for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
  if df.civzone_type[z.type] == 'Tomb' and z.assigned_unit_id < 0 and z.zone_settings.tomb.flags.no_citizens then
    z.zone_settings.tomb.flags.no_citizens = false
    opened = opened + 1
  end
end
local resumed = 0
for _, b in ipairs(df.global.world.buildings.all) do
  if b:getBuildStage() < b:getMaxBuildStage() then
    for i = 0, #b.jobs - 1 do
      local j = b.jobs[i]
      if j.job_type == df.job_type.ConstructBuilding and j.flags.suspend then j.flags.suspend = false; resumed = resumed + 1 end
    end
  end
end
print(('tombs opened %d, construction jobs resumed %d'):format(opened, resumed))

-- 3. nobles keep a room: an election leaves the mayor's office and dining room with the old holder
do
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
end
