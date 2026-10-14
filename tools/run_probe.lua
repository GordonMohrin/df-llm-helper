-- Read-only probe for tools/run_watch.py: counts only, no hidden tiles, no unit names (Run 9, 14.10.2026).
-- Prints key=value lines. Visible-tile reads only (hidden tiles are skipped).
local function out(k, v) print(k .. '=' .. tostring(v)) end

-- buildings by kind (built = construction finished)
local counts, planned = {}, {}
local function bump(t, k) t[k] = (t[k] or 0) + 1 end
for _, b in ipairs(df.global.world.buildings.all) do
  local t = df.building_type[b:getType()]
  local key = t
  if t == 'Workshop' then key = 'W_' .. df.workshop_type[b.type]
  elseif t == 'Furnace' then key = 'F_' .. df.furnace_type[b.type]
  elseif t == 'Trap' then key = 'T_' .. df.trap_type[b.trap_type]
  elseif t == 'Civzone' then key = 'Z_' .. df.civzone_type[b.type] end
  local done = true
  if b.getBuildStage and b.getMaxBuildStage then
    local ok, st = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
    done = ok and st or false
  end
  if done then bump(counts, key) else bump(planned, key) end
end
for k, v in pairs(counts) do out('b.' .. k, v) end
for k, v in pairs(planned) do out('p.' .. k, v) end

-- citizens
local cit = dfhack.units.getCitizens(true)
local maxh, maxt, adults = 0, 0, 0
for _, u in ipairs(cit) do
  maxh = math.max(maxh, u.counters2.hunger_timer)
  maxt = math.max(maxt, u.counters2.thirst_timer)
  if dfhack.units.isAdult(u) then adults = adults + 1 end
end
out('cit', #cit); out('adults', adults); out('max_hunger', maxh); out('max_thirst', maxt)

-- army
local sq = 0
for _, s in ipairs(df.global.world.squads.all) do
  if s.entity_id == df.global.plotinfo.group_id then sq = sq + 1 end
end
out('squads', sq)

-- items: mechanisms, bolts, crossbows
local mech = 0
for _, i in ipairs(df.global.world.items.other.TRAPPARTS) do mech = mech + i.stack_size end
out('mechanisms', mech)
local xb = 0
for _, i in ipairs(df.global.world.items.other.WEAPON) do
  if i.subtype and i.subtype.id == 'ITEM_WEAPON_CROSSBOW' then xb = xb + 1 end
end
out('crossbows', xb)
local bone = 0 -- bones: no item vector in this DF build; reported by kernel census


-- visible water tiles in the fort box (well supply)
local w = 0
for z = 110, 116 do
  for y = 50, 70 do for x = 45, 60 do
    local d = dfhack.maps.getTileFlags(x, y, z)
    if d and not d.hidden and d.flow_size > 0 then w = w + 1 end
  end end
end
out('wet_tiles', w)

-- connectivity (run 9 lesson, 14.10.2026: a wall ring sealed the shaft head, food and farms were unreachable for
-- half the colony, and forbidden seed bags stopped all planting). Walkable groups, flags only, no hidden tiles.
local gcount, main, mainn = {}, 0, 0
for _, u in ipairs(cit) do
  if dfhack.units.isAlive(u) then
    local g = dfhack.maps.getWalkableGroup(xyz2pos(dfhack.units.getPosition(u)))
    gcount[g] = (gcount[g] or 0) + 1
  end
end
local ngroups = 0
for g, n in pairs(gcount) do
  if g > 0 then ngroups = ngroups + 1 end
  if g > 0 and n > mainn then main, mainn = g, n end
end
out('cit_groups', ngroups)
out('cit_in_main_group', mainn)
local function unreach(vec, skip_forbidden)
  local n = 0
  for _, i in ipairs(vec) do
    if not (skip_forbidden and i.flags.forbid) then
      local p = xyz2pos(dfhack.items.getPosition(i))
      if p.x and dfhack.maps.getWalkableGroup(p) ~= main then n = n + 1 end
    end
  end
  return n
end
local o = df.global.world.items.other
out('food_unreach', unreach(o.PLANT, true) + unreach(o.PLANT_GROWTH, true) + unreach(o.MEAT, true) + unreach(o.FOOD, true) + unreach(o.FISH, true) + unreach(o.CHEESE, true))
local sforb, sun = 0, 0
for _, i in ipairs(o.SEEDS) do
  local forb = i.flags.forbid
  local c = dfhack.items.getContainer(i)
  while c do
    if c.flags.forbid then forb = true end
    c = dfhack.items.getContainer(c)
  end
  if forb then sforb = sforb + i.stack_size end
end
out('seeds_forbidden', sforb)
out('seeds_unreach', unreach(o.SEEDS, false))
local punr, pn = 0, 0
for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
  pn = pn + 1
  if dfhack.maps.getWalkableGroup(xyz2pos(b.x1, b.y1, b.z)) ~= main then punr = punr + 1 end
end
out('plots_unreach', punr); out('plots', pn)

-- game clock
out('year', df.global.cur_year); out('tick', df.global.cur_year_tick)
out('paused', tostring(df.global.pause_state))

-- uninvited wild creatures on the citizens' walkable group (giant rats etc.): visible tiles only, no names (Lua crash lesson)
do
  local n, races = 0, {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and not dfhack.units.isCitizen(u) and not dfhack.units.isTame(u)
       and (dfhack.units.isWildlife(u) or dfhack.units.isInvader(u)) and not dfhack.units.isGhost(u) then
      local p = xyz2pos(dfhack.units.getPosition(u))
      local fl = dfhack.maps.getTileFlags(p)
      if fl and not fl.hidden and main > 0 and dfhack.maps.getWalkableGroup(p) == main then
        n = n + 1
        local r = df.creature_raw.find(u.race)
        local id = r and r.creature_id or '?'
        races[id] = (races[id] or 0) + 1
      end
    end
  end
  local list = {}
  for k, v in pairs(races) do list[#list + 1] = k .. 'x' .. v end
  table.sort(list)
  out('intruders', n); out('intruder_races', table.concat(list, ','))
end

-- equipment: adults with a wielded weapon AND at least one worn armor piece (Gordon rule 5: every adult equipped)
do
  local eq, sq = 0, 0
  for _, u in ipairs(cit) do
    if dfhack.units.isAdult(u) and dfhack.units.isAlive(u) then
      local w, a = false, false
      for _, inv in ipairs(u.inventory) do
        local t = inv.item:getType()
        if inv.mode == 1 and t == df.item_type.WEAPON then w = true end
        if inv.mode == 2 and (t == df.item_type.ARMOR or t == df.item_type.HELM or t == df.item_type.PANTS
           or t == df.item_type.SHOES or t == df.item_type.GLOVES) then a = true end
      end
      if w and a then eq = eq + 1 end
      if u.military.squad_id >= 0 then sq = sq + 1 end
    end
  end
  out('equipped_adults', eq); out('squad_adults', sq)
end
