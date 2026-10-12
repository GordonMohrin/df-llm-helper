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
