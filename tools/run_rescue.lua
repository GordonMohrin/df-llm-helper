-- Fast rescue pass (every ~10 s real time; the game runs at 300-500 ticks/s, so the 3-minute watcher round is too slow for thirst):
--  * citizens flagged for health care who are thirsty/hungry get released (no forced rest, no diagnosis) so they drink and eat themselves
--  * threat popups are logged and dismissed (the game halts on them while pause_state stays false)
--  * death incidents of loose dwarf corpses are marked discovered
local freed = 0
for _, u in ipairs(dfhack.units.getCitizens(true)) do
  local h = u.health
  if h and (h.flags.should_not_move or h.flags.rq_diagnosis) and (u.counters2.thirst_timer > 20000 or u.counters2.hunger_timer > 35000) then
    h.flags.should_not_move = false
    h.flags.rq_diagnosis = false
    local j = u.job.current_job
    -- (no dfhack.job.removeJob: DF crashed on unit 24510 after job removal, 14.10. 17:47)
    freed = freed + 1
  end
end
local p = df.global.world.status.popups
local n = 0
while #p > 0 and n < 10 do
  local text = dfhack.df2utf(p[0].text or '')
  if text:find('Strike the earth') then break end
  print('popup=' .. text:sub(1, 100))
  p:erase(0); n = n + 1
end
local disc = 0
for _, i in ipairs(df.global.world.items.other.CORPSE) do
  local r = df.creature_raw.find(i.race)
  if r and r.creature_id == 'DWARF' then
    local u = df.unit.find(i.unit_id)
    if u and u.counters.death_id >= 0 then
      local ic = df.incident.find(u.counters.death_id)
      if ic and not ic.flags.discovered then ic.flags.discovered = true; disc = disc + 1 end
    end
  end
end
if n + disc > 0 then print('rescue released=' .. freed .. ' popups=' .. n .. ' discovered=' .. disc) end

-- Shaft-head doors: forbidden while invaders are on the map (goblins open doors and would bypass the trap corridor through the shaft),
-- allowed again when none is left. Lesson: feedback_df_tueren_forbid_lenken.
do
  local inv = 0
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and dfhack.units.isInvader(u) and not dfhack.units.isGhost(u) then inv = inv + 1 end
  end
  local want = inv >= 2
  for _, p in ipairs({{54, 62, 118}, {56, 62, 118}}) do
    local b = dfhack.buildings.findAtTile(xyz2pos(p[1], p[2], p[3]))
    if b and b:getType() == df.building_type.Door and b.door_flags.forbidden ~= want then
      b.door_flags.forbidden = want
      print('shaft door ' .. p[1] .. ' forbidden=' .. tostring(want) .. ' invaders=' .. inv)
    end
  end
end

-- Intruder kill orders every 10 s (copied from run_release.lua): civilians brawl with every wild animal in the fort and come back with 5-8 wounds.
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
  local siege_n = 0
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and dfhack.units.isInvader(u) and not dfhack.units.isGhost(u) then siege_n = siege_n + 1 end
  end
  local targets = {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isActive(u) and dfhack.units.isAlive(u) and not dfhack.units.isGhost(u)
       and ((not dfhack.units.isCitizen(u) and not dfhack.units.isTame(u) and (dfhack.units.isWildlife(u) or dfhack.units.isInvader(u)))
            or (dfhack.units.isCitizen(u) and u.mood == df.mood_type.Berserk)) then
      local p = xyz2pos(dfhack.units.getPosition(u))
      local fl = dfhack.maps.getTileFlags(p)
      -- inside the fort only (z <= 117 under the surface, or a berserk citizen anywhere): far wildlife on the open map is not our business
      local inside = p.z <= (siege_n >= 4 and 116 or 117) and p.x >= 20 and p.x <= 110 and p.y >= 35 and p.y <= 125   -- during an organised siege the trap corridor (z117) is the traps' job
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
  if set > 0 or cleared > 0 then print('intruders=' .. (hunting and 0 or #targets) .. ' hunt_targets=' .. (hunting and #targets or 0) .. ' kill_orders_set=' .. set .. ' kill_orders_cleared=' .. cleared) end
end
