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
if backlog > 0 then
  local det
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do if w.name == 'Miners' then det = w end end
  if det then
    local have = #det.assigned_units
    local added = 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
      if have + added >= math.min(14, 4 + backlog // 150) then break end
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
  -- no intruder: the squad hunts harmless grazers on the open map for hides, bone and meat (leather/bone feed the strange moods;
  -- a failed mood costs a citizen). Never while a large predator is visible; at most 2 targets at a time.
  local hunting = false
  if #targets == 0 then
    local predator = false
    local grazers = {}
    for _, u in ipairs(df.global.world.units.active) do
      if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and not dfhack.units.isCitizen(u) and not dfhack.units.isTame(u) and dfhack.units.isWildlife(u) then
        local r = df.creature_raw.find(u.race)
        local c = r and r.caste[u.caste]
        local p = xyz2pos(dfhack.units.getPosition(u))
        local fl = dfhack.maps.getTileFlags(p)
        if c and fl and not fl.hidden then
          if c.flags.LARGE_PREDATOR then if math.abs(p.x - 60) <= 70 and math.abs(p.y - 62) <= 70 then predator = true end
          elseif c.flags.GRAZER and not c.flags.MEGABEAST and main > 0 and dfhack.maps.getWalkableGroup(p) == main
                 and p.x >= 10 and p.x <= 150 and p.y >= 10 and p.y <= 150 then grazers[#grazers + 1] = u.id end
        end
      end
    end
    if not predator and #grazers > 0 then
      table.sort(grazers)
      for i = 1, math.min(2, #grazers) do targets[#targets + 1] = grazers[i] end
      hunting = true
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
  print('intruders=' .. (hunting and 0 or #targets) .. ' hunt_targets=' .. (hunting and #targets or 0) .. ' kill_orders_set=' .. set .. ' kill_orders_cleared=' .. cleared)
end

-- Leather/bone/meat only come from animals (no metal, no leather in stock): keep 3 adults in the 'Hunters' work detail (crossbows 21,
-- bolts 100+ are in stock). Idle <= 30 % and the equipment goal both need hides.
do
  local det
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do if w.name == 'Hunters' then det = w end end
  if det then
    -- a visible large predator (andrewsarchus, bears, ...) near the fort: nobody hunts outside until it is gone
    local danger = 0
    for _, u in ipairs(df.global.world.units.active) do
      if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and not dfhack.units.isCitizen(u) and not dfhack.units.isTame(u) and dfhack.units.isWildlife(u) then
        local r = df.creature_raw.find(u.race)
        local c = r and r.caste[u.caste]
        if c and c.flags.LARGE_PREDATOR then
          local p = xyz2pos(dfhack.units.getPosition(u))
          local fl = dfhack.maps.getTileFlags(p)
          if fl and not fl.hidden and math.abs(p.x - 60) <= 70 and math.abs(p.y - 62) <= 70 then danger = danger + 1 end
        end
      end
    end
    if danger > 0 or true then
      for i = #det.assigned_units - 1, 0, -1 do det.assigned_units:erase(i) end
      print('hunters=0 (large predator visible: ' .. danger .. ')')
    else
      local have, added = #det.assigned_units, 0
      local HUNTERS = 0   -- 14.10.: 4 hunters/soldiers came back wounded and died in the ward (no working hospital water); raise again once the hospital has water
      for _, u in ipairs(dfhack.units.getCitizens(true)) do
        if have + added >= HUNTERS then break end
        if dfhack.units.isAdult(u) and u.military.squad_id < 0 then
          local member = false
          for _, id in ipairs(det.assigned_units) do if id == u.id then member = true end end
          if not member then det.assigned_units:insert('#', u.id); u.status.labors[df.unit_labor.HUNT] = true; added = added + 1 end
        end
      end
      print('hunters=' .. (have + added) .. ' (added ' .. added .. ')')
    end
  end
end

-- Run 9 (14.10.2026): the kernel's civ-alert confines every citizen to the 4-tile 'Kern+' burrow whenever ANY hostile is visible;
-- four dingoes on the surface froze the whole colony (idle 95 %, levers and jobs unreachable). Keep the civ-alert only while a real
-- threat (invader or danger) is visible; wildlife outside is the hunters' and squad's business.
do
  local a = df.global.plotinfo.alerts
  if a.civ_alert_idx ~= 0 then
    local real = 0
    for _, u in ipairs(df.global.world.units.active) do
      if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and not dfhack.units.isCitizen(u) and not dfhack.units.isTame(u)
         and not dfhack.units.isGhost(u) and (dfhack.units.isInvader(u) or dfhack.units.isDanger(u)) then
        local fl = dfhack.maps.getTileFlags(xyz2pos(dfhack.units.getPosition(u)))
        if fl and not fl.hidden then real = real + 1 end
      end
    end
    if real == 0 then a.civ_alert_idx = 0; print('civ_alert_released=1') else print('civ_alert_kept real_threats=' .. real) end
  end
end

-- Hospital rescue (Run 9, 14.10.2026, 4 patients at thirst 63-70k): caregivers cancel 'Give water: No water source' and
-- 'Diagnose patient: Patient not resting', so bedridden patients die of thirst/hunger in the ward. A patient who is already thirsty or
-- hungry is released: no forced rest, no diagnosis requirement, current rest job cancelled, so the unit fetches its own drink and food.
do
  local freed = 0
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    local h = u.health
    if h and (h.flags.should_not_move or h.flags.rq_diagnosis) and (u.counters2.thirst_timer > 30000 or u.counters2.hunger_timer > 40000) then
      h.flags.should_not_move = false
      h.flags.rq_diagnosis = false
      local j = u.job.current_job
      if j and df.job_type[j.job_type] == 'Rest' then pcall(function() dfhack.job.removeJob(j) end) end
      freed = freed + 1
    end
  end
  print('hospital_patients_released=' .. freed)
end

-- Run 9 (14.10.2026): "Snatcher! Protect the children!" popup froze the game for minutes while two kidnappers walked the fort: the
-- arbiter only dismisses harmless popups and pause_state stays false. A popup is a normal player prompt: log its text, then dismiss it
-- (never the embark intro).
do
  local p = df.global.world.status.popups
  local n = 0
  while #p > 0 do
    local text = dfhack.df2utf(p[0].text or '')
    if text:find('Strike the earth') then break end
    print('popup_dismissed=' .. text:sub(1, 120))
    p:erase(0); n = n + 1
    if n >= 10 then break end
  end
  print('popups_dismissed=' .. n)
end

-- A loose dwarf corpse is only hauled to its coffin once its death incident is 'discovered' (a dwarf must find the body); bodies in
-- quiet rooms stayed unburied for days. Mark the incidents of loose dwarf corpses as discovered (what DFHack's entomb script does).
do
  local n = 0
  for _, i in ipairs(df.global.world.items.other.CORPSE) do
    local r = df.creature_raw.find(i.race)
    if r and r.creature_id == 'DWARF' then
      local u = df.unit.find(i.unit_id)
      if u and u.counters.death_id >= 0 then
        local ic = df.incident.find(u.counters.death_id)
        if ic and not ic.flags.discovered then ic.flags.discovered = true; n = n + 1 end
      end
    end
  end
  print('incidents_discovered=' .. n)
end

-- Run 9 (14.10.2026): the civ-alert burrow 'Kern+' had 4 tiles; every goblin wave locked all citizens into it without drink and a child and
-- a leatherworker died of thirst. Keep it as the whole interior (z108-z116, walkable group of the citizens) so food, drink, beds and the
-- crypt stay inside the alert area; the surface and the trap corridor (z117/118) stay outside.
do
  local b = dfhack.burrows.findByName('Kern+')
  if b and #b.block_x < 60 then
    local main = dfhack.maps.getWalkableGroup(xyz2pos(55, 62, 110))
    local n = 0
    for z = 108, 116 do
      for x = 20, 125 do
        for y = 20, 125 do
          local pos = xyz2pos(x, y, z)
          local f = dfhack.maps.getTileFlags(pos)
          if f and not f.hidden and dfhack.maps.getWalkableGroup(pos) == main then dfhack.burrows.setAssignedTile(b, pos, true); n = n + 1 end
        end
      end
    end
    print('kern_burrow_tiles_added=' .. n)
  end
end

-- Run 9 (14.10.2026): the manager died in a goblin raid; without a manager no new work order is ever validated (BREW_DRINK, slabs, coffins
-- stayed 'valid false'). Validate pending orders ourselves until a new manager is appointed.
do
  local n = 0
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if not o.status.validated and o.amount_left > 0 then o.status.validated = true; n = n + 1 end
  end
  print('orders_validated=' .. n)
end
