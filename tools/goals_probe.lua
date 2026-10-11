-- goals_probe: read-only counts for tools/goals.py (one key=value per line). Never names a unit or reads a
-- hidden tile; safe to run while the game runs: dfhack-run lua -f tools/goals_probe.lua
local out = {}
local function put(k, v) out[#out + 1] = k .. '=' .. tostring(v) end

local cit = dfhack.units.getCitizens(true)
local adults, kids, free, need, busy = 0, 0, 0, 0, 0
local NEED = {}
for _, n in ipairs({'Sleep', 'Eat', 'DrinkItem', 'Rest', 'CleanSelf', 'GetProvisions', 'Pray', 'Worship'}) do
  if df.job_type[n] then NEED[df.job_type[n]] = true end
end
local adult_ids = {}
for _, u in ipairs(cit) do
  if dfhack.units.isDead(u) then
  elseif dfhack.units.isAdult(u) then
    adults = adults + 1
    adult_ids[u.id] = true
    local j = u.job.current_job
    if not j then free = free + 1 elseif NEED[j.job_type] then need = need + 1 else busy = busy + 1 end
  else kids = kids + 1 end
end
put('adults', adults); put('kids', kids); put('busy', busy); put('need', need); put('free', free)

-- rooms: zones by type, owners
local zt = df.civzone_type
local bed_owner, owned, byname = {}, {}, {}
local tombs_free, tombs = 0, 0
for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
  if z.type == zt.Bedroom and z.assigned_unit_id >= 0 then bed_owner[z.assigned_unit_id] = true end
  if z.assigned_unit_id >= 0 then owned[z.assigned_unit_id .. ':' .. df.civzone_type[z.type]] = true end
  if z.type == zt.Tomb then
    tombs = tombs + 1
    if z.assigned_unit_id < 0 then tombs_free = tombs_free + 1 end
  end
  local nm = z.name or ''
  if nm ~= '' then byname[nm] = (byname[nm] or 0) + 1 end
end
local housed = 0
for id in pairs(adult_ids) do if bed_owner[id] then housed = housed + 1 end end
put('housed', housed); put('tombs', tombs); put('tombs_free', tombs_free)
for _, n in ipairs({'Temple', 'Tavern', 'Hospital', 'Dining', 'Office', 'Library'}) do put('zone_' .. n, byname[n] or 0) end

-- nobles: office / bedroom / dining of the people whose position asks for it
local function noble(role, tag)
  local u = dfhack.units.getUnitByNobleRole(role)
  if not u or dfhack.units.isDead(u) then put(tag .. '_exists', 0); return end
  put(tag .. '_exists', 1)
  put(tag .. '_office', owned[u.id .. ':Office'] and 1 or 0)
  put(tag .. '_bedroom', owned[u.id .. ':Bedroom'] and 1 or 0)
  put(tag .. '_dining', owned[u.id .. ':DiningHall'] and 1 or 0)
end
noble('mayor', 'mayor'); noble('manager', 'manager'); noble('bookkeeper', 'bookkeeper')

-- metal
local bars, ore = 0, 0
for _, it in ipairs(df.global.world.items.other.BAR) do
  local m = dfhack.matinfo.decode(it)
  if m and m.material.flags.IS_METAL and not it.flags.trader then bars = bars + 1 end
end
for _, it in ipairs(df.global.world.items.other.BOULDER) do
  if it.mat_type == 0 and not it.flags.trader then
    local m = dfhack.matinfo.decode(it)
    local v = m and m.inorganic and m.inorganic.metal_ore and m.inorganic.metal_ore.mat_index
    if v and #v > 0 then ore = ore + 1 end
  end
end
put('metal_bars', bars); put('ore_boulders', ore)

-- farms
local plots, cropped = 0, 0
for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
  if b:getBuildStage() >= b:getMaxBuildStage() then
    plots = plots + 1
    local c = b.plant_id[df.global.cur_season]
    if c and c >= 0 then cropped = cropped + 1 end
  end
end
put('farm_plots', plots); put('farm_cropped', cropped)

-- wounded
local hurt = 0
for _, u in ipairs(cit) do                      -- needs care now (scars of old wounds do not count)
  if not dfhack.units.isDead(u) and u.health and u.health.flags.needs_healthcare then hurt = hurt + 1 end
end
put('wounded', hurt)

put('year', df.global.cur_year)
print(table.concat(out, '\n'))
