-- Workaround FR-16: resume suspended ConstructBuilding jobs (buildingplan/suspendmanager keep pausing them).
local l = df.global.world.jobs.list.next
local r, n = 0, 0
while l do
  local j = l.item
  if j and j.job_type == df.job_type.ConstructBuilding then
    n = n + 1
    if j.flags.suspend then j.flags.suspend = false; r = r + 1 end
  end
  l = l.next
end
print('released=' .. r)
print('construct_jobs=' .. n)

-- Workaround FR-16b: the kernel keeps only 2-4 miners; with a big visible dig backlog make sure >= 6 adults mine
-- (idle non-military adults, with a pick available is up to the game's own job assignment).
local backlog = 0
do
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j then
      local t = df.job_type[j.job_type] or ''
      if t:find('^Dig') or t:find('^Carve') then backlog = backlog + 1 end
    end
    l = l.next
  end
end
print('dig_backlog=' .. backlog)
if backlog > 50 then
  local det
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do if w.name == 'Miners' then det = w end end
  if det then
    local have = #det.assigned_units
    local added = 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
      if have + added >= math.min(14, 6 + backlog // 150) then break end
      if dfhack.units.isAdult(u) and u.military.squad_id < 0 and not u.status.labors[df.unit_labor.MINE] then
        det.assigned_units:insert('#', u.id); u.status.labors[df.unit_labor.MINE] = true; added = added + 1
      end
    end
    print('miners=' .. (have + added) .. ' (added ' .. added .. ')')
  end
end

-- Workaround FR-17: fill empty season slots of underground farm plots with the crop of the first non-empty slot.
local filled = 0
for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do
  if b.z < 118 then
    local crop = -1
    for i = 0, 3 do if b.plant_id[i] ~= -1 then crop = b.plant_id[i]; break end end
    if crop ~= -1 then
      for i = 0, 3 do if b.plant_id[i] == -1 then b.plant_id[i] = crop; filled = filled + 1 end end
    end
  end
end
print('farm_slots_filled=' .. filled)

-- Workaround FR-23: tomb zones placed by quickfort are closed to citizens (no_citizens); open unassigned ones so the dead can be buried.
local opened = 0
for _, b in ipairs(df.global.world.buildings.all) do
  if b:getType() == df.building_type.Civzone and b.type == df.civzone_type.Tomb and b.assigned_unit_id == -1 then
    local f = b.zone_settings.tomb.flags
    if f.no_citizens then f.no_citizens = false; opened = opened + 1 end
  end
end
print('tomb_zones_opened=' .. opened)

-- Workaround FR-24: brewing eats the plump helmets the dwarves need as food. While food < 30 days and drink > 60 days,
-- take the brew-from-plant orders off the manager list (the kernel re-adds them once food has recovered).
local fd, dd = tonumber(({...})[1]), tonumber(({...})[2])
local removed = 0
if fd and dd and fd < 30 and dd > 60 then
  local all = df.global.world.manager_orders.all
  for i = #all - 1, 0, -1 do
    local r = all[i].reaction_name or ''
    if r:find('BREW_DRINK_FROM_PLANT') then all:erase(i); removed = removed + 1 end
  end
end
print('brew_orders_removed=' .. removed)

-- Workaround FR-25: the 'Planters' work detail is empty (mode 1 = members only); without it the PlantSeeds jobs of the new farm
-- plots stay unclaimed (79 pending jobs, food 1 day). Keep >= 14 adults in it.
do
  local det
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do if w.name == 'Planters' then det = w end end
  if det then
    local have, added = #det.assigned_units, 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
      if have + added >= 14 then break end
      if dfhack.units.isAdult(u) and u.military.squad_id < 0 then
        local member = false
        for _, id in ipairs(det.assigned_units) do if id == u.id then member = true end end
        if not member then det.assigned_units:insert('#', u.id); u.status.labors[df.unit_labor.PLANT] = true; added = added + 1 end
      end
    end
    print('planters=' .. (have + added) .. ' (added ' .. added .. ')')
  end
end

-- Run 9 lesson (14.10.2026): seed bags that came with a caravan were flagged forbidden; PlantSeeds jobs vanished and the
-- cancellation read 'Needs plump helmet spawn'. Unforbid every seed item and every container holding seeds, each round.
do
  local seen, n = {}, 0
  for _, i in ipairs(df.global.world.items.other.SEEDS) do
    if i.flags.forbid then i.flags.forbid = false; n = n + 1 end
    local c = dfhack.items.getContainer(i)
    while c do
      if not seen[c.id] then seen[c.id] = true; if c.flags.forbid then c.flags.forbid = false; n = n + 1 end end
      c = dfhack.items.getContainer(c)
    end
  end
  print('seed_forbid_cleared=' .. n)
end

-- Run 9 lesson (14.10.2026): repeated quickfort/kernel placements left up to 3 overlapping tomb zones on one coffin tile,
-- each assigned to a different dead citizen, plus zones on tiles without any coffin: nobody was hauled to a coffin.
-- Keep ONE zone per coffin tile (prefer the one whose dead unit is still unburied), remove the others and zones without a coffin.
do
  local corpse_unit_at, unit_unburied = {}, {}
  local coffin_at = {}
  for _, b in ipairs(df.global.world.buildings.other.COFFIN) do coffin_at[b.x1 .. ',' .. b.y1 .. ',' .. b.z] = true end
  for _, i in ipairs(df.global.world.items.other.CORPSE) do
    local p = xyz2pos(dfhack.items.getPosition(i))
    local k = p.x .. ',' .. p.y .. ',' .. p.z
    corpse_unit_at[k] = i.unit_id
    if not coffin_at[k] then unit_unburied[i.unit_id] = true end
  end
  local by_tile = {}
  for _, z in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
    local k = z.x1 .. ',' .. z.y1 .. ',' .. z.z
    by_tile[k] = by_tile[k] or {}; table.insert(by_tile[k], z)
  end
  local removed = 0
  local function drop(z)
    local u = z.assigned_unit_id >= 0 and df.unit.find(z.assigned_unit_id)
    if u then for idx = #u.owned_buildings - 1, 0, -1 do if u.owned_buildings[idx] == z then u.owned_buildings:erase(idx) end end end
    z.assigned_unit_id = -1
    if dfhack.buildings.deconstruct(z) then removed = removed + 1 end
  end
  for k, zs in pairs(by_tile) do
    if not coffin_at[k] then
      for _, z in ipairs(zs) do if z.assigned_unit_id < 0 or unit_unburied[z.assigned_unit_id] then drop(z) end end
    elseif #zs > 1 then
      local keep
      for _, z in ipairs(zs) do if z.assigned_unit_id >= 0 and corpse_unit_at[k] == z.assigned_unit_id then keep = z end end
      if not keep then for _, z in ipairs(zs) do if z.assigned_unit_id >= 0 and unit_unburied[z.assigned_unit_id] then keep = keep or z end end end
      if not keep then keep = zs[1] end
      for _, z in ipairs(zs) do if z ~= keep then drop(z) end end
    end
  end
  print('tomb_zones_removed=' .. removed)
end

-- Run 9 lesson (14.10.2026): dead citizens stay unburied (ghosts, stress) when their assigned tomb zone has no coffin
-- (overlapping zones on one tile, zone planned but coffin never built) or the coffin holds someone else. Re-assign such
-- dead units to a free coffin whose single tomb zone is unassigned. Idempotent; touches only unburied dwarf corpses.
do
  local key = function(p) return p.x .. ',' .. p.y .. ',' .. p.z end
  local occ = {}
  for _, i in ipairs(df.global.world.items.other.CORPSE) do
    local k = key(xyz2pos(dfhack.items.getPosition(i)))
    occ[k] = occ[k] or {}; occ[k][i.unit_id] = true
  end
  local coffin_at = {}
  for _, b in ipairs(df.global.world.buildings.other.COFFIN) do coffin_at[b.x1 .. ',' .. b.y1 .. ',' .. b.z] = true end
  local zones_at, zones_of = {}, {}
  for _, z in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
    local k = z.x1 .. ',' .. z.y1 .. ',' .. z.z
    zones_at[k] = zones_at[k] or {}; table.insert(zones_at[k], z)
    if z.assigned_unit_id >= 0 then zones_of[z.assigned_unit_id] = zones_of[z.assigned_unit_id] or {}; table.insert(zones_of[z.assigned_unit_id], z) end
  end
  local need = {}
  for _, i in ipairs(df.global.world.items.other.CORPSE) do
    local r = df.creature_raw.find(i.race)
    if r and r.creature_id == 'DWARF' then
      local k = key(xyz2pos(dfhack.items.getPosition(i)))
      if not coffin_at[k] then
        local ok = false
        for _, z in ipairs(zones_of[i.unit_id] or {}) do
          local zk = z.x1 .. ',' .. z.y1 .. ',' .. z.z
          local shared = false
          for u in pairs(occ[zk] or {}) do if u ~= i.unit_id then shared = true end end
          if coffin_at[zk] and not shared then ok = true end
        end
        if not ok then need[#need + 1] = i.unit_id end
      end
    end
  end
  local freed = {}
  for _, id in ipairs(need) do
    for _, z in ipairs(zones_of[id] or {}) do
      local u = df.unit.find(id)
      if u then for idx = #u.owned_buildings - 1, 0, -1 do if u.owned_buildings[idx] == z then u.owned_buildings:erase(idx) end end end
      z.assigned_unit_id = -1; z.zone_settings.tomb.flags.no_citizens = false
    end
  end
  local cands = {}
  for _, b in ipairs(df.global.world.buildings.other.COFFIN) do
    local k = b.x1 .. ',' .. b.y1 .. ',' .. b.z
    local zs = zones_at[k]
    if zs and not occ[k] then
      local free = true
      for _, z in ipairs(zs) do if z.assigned_unit_id >= 0 then free = false end end
      if free then cands[#cands + 1] = zs end
    end
  end
  local n = 0
  for _, id in ipairs(need) do
    local zs = table.remove(cands, 1)
    if not zs then break end
    local u = df.unit.find(id)
    if u then
      zs[1].assigned_unit_id = id; u.owned_buildings:insert('#', zs[1])
      zs[1].zone_settings.tomb.flags.no_pets = true; zs[1].zone_settings.tomb.flags.no_citizens = true
      for k = 2, #zs do zs[k].zone_settings.tomb.flags.no_citizens = true end
      n = n + 1
    end
  end
  print('burial_reassigned=' .. n .. ' (unburied needing a coffin: ' .. #need .. ', free coffins left: ' .. #cands .. ')')
end

-- Run 9 (14.10.2026, Gordon): wild creatures walking around inside the fort ("thieving or mischievous creatures") were never
-- fought. Give the fort's squads a kill order on visible non-tame wildlife/invaders on the citizens' walkable group; withdraw it
-- when none is left so the squads return to their training routine. Names are never read (Lua crash lesson).
do
  local gcount, main, mainn = {}, 0, 0
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if dfhack.units.isAlive(u) then
      local g = dfhack.maps.getWalkableGroup(xyz2pos(dfhack.units.getPosition(u)))
      gcount[g] = (gcount[g] or 0) + 1
    end
  end
  for g, n in pairs(gcount) do if g > 0 and n > mainn then main, mainn = g, n end end
  local targets = {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and not dfhack.units.isGhost(u)
       and ((not dfhack.units.isCitizen(u) and not dfhack.units.isTame(u) and (dfhack.units.isWildlife(u) or dfhack.units.isInvader(u)))
            or (dfhack.units.isCitizen(u) and u.mood == df.mood_type.Berserk)) then
      local p = xyz2pos(dfhack.units.getPosition(u))
      local fl = dfhack.maps.getTileFlags(p)
      -- inside the fort only (z <= 117 under the surface, or a berserk citizen anywhere): far wildlife on the open map is not our business
      local inside = p.z <= 117 and p.x >= 20 and p.x <= 110 and p.y >= 35 and p.y <= 125
      if fl and not fl.hidden and main > 0 and dfhack.maps.getWalkableGroup(p) == main and (inside or dfhack.units.isCitizen(u)) then targets[#targets + 1] = u.id end
    end
  end
  table.sort(targets)
  local want = table.concat(targets, ',')
  local set, cleared = 0, 0
  for _, sq in ipairs(df.global.world.squads.all) do
    if sq.entity_id == df.global.plotinfo.group_id then
      local members = 0
      for _, p in ipairs(sq.positions) do if p.occupant >= 0 then members = members + 1 end end
      if members > 0 then
        local have
        for _, o in ipairs(sq.orders) do
          if o:getType() == df.squad_order_type.KILL_LIST then
            local ids = {}
            for _, id in ipairs(o.units) do ids[#ids + 1] = id end
            table.sort(ids); have = table.concat(ids, ',')
          end
        end
        if #targets > 0 and have ~= want then
          for i = #sq.orders - 1, 0, -1 do local o = sq.orders[i]; sq.orders:erase(i); pcall(function() o:delete() end) end
          local o = df.squad_order_kill_listst:new()
          for _, id in ipairs(targets) do o.units:insert('#', id) end
          o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
          sq.orders:insert('#', o); set = set + 1
        elseif #targets == 0 and have ~= nil then
          for i = #sq.orders - 1, 0, -1 do local o = sq.orders[i]; sq.orders:erase(i); pcall(function() o:delete() end) end
          cleared = cleared + 1
        end
      end
    end
  end
  print('intruders=' .. #targets .. ' kill_orders_set=' .. set .. ' kill_orders_cleared=' .. cleared)
end

-- Leather/bone/meat only come from animals (no metal, no leather in stock): keep 3 adults in the 'Hunters' work detail (crossbows 21,
-- bolts 100+ are in stock). Idle <= 30 % and the equipment goal both need hides.
do
  local det
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do if w.name == 'Hunters' then det = w end end
  if det then
    local have, added = #det.assigned_units, 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
      if have + added >= 3 then break end
      if dfhack.units.isAdult(u) and u.military.squad_id < 0 then
        local member = false
        for _, id in ipairs(det.assigned_units) do if id == u.id then member = true end end
        if not member then det.assigned_units:insert('#', u.id); u.status.labors[df.unit_labor.HUNT] = true; added = added + 1 end
      end
    end
    print('hunters=' .. (have + added) .. ' (added ' .. added .. ')')
  end
end
