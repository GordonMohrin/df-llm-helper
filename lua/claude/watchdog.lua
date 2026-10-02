-- claude/watchdog start|stop|status
-- Runs directly in DFHack (independent of Claude): every 600 ticks
--  * clear message windows (otherwise they halt the simulation),
--  * with ground enemies <= 45 tiles AND |dz| <= 10 (values: claude/config) switch on the civilian alert (civilians into the burrow),
--  * after ~5 quiet checks switch the civilian alert off again,
--  * slow motion (fps 50) with a visible ground enemy <= 90 tiles, siege.flag from 6 enemies (siege warning).
local util = reqscript('claude/util')
-- FORT_X/Y, ALERT_RANGE, Z range, refuse box (ONE place per map): C() fetches the current version on every run (changes apply without restart)
local function C() return reqscript('claude/config') end
local repeatUtil = require('repeat-util')

local KEY = 'claude-watchdog'
local INTERVAL = 600

state = state or { clean = 0, alarms = 0, last_alarm = nil, popups = 0 }

local function stack_sum(vec, free_only)
  local n = 0
  for _, i in ipairs(vec) do
    local f = i.flags
    if not (f.forbid or f.rotten or f.dump or f.trader or (free_only and f.in_job)) then n = n + i:getStackSize() end
  end
  return n
end

local function add_task(id, name, count)
  dfhack.run_script('claude/task', 'add', tostring(id), name, tostring(count))
end

-- Secure drinks and buckets without Claude (workshop menu equivalent)
local function supplies()
  local items = df.global.world.items.other
  local drinks = stack_sum(items.DRINK, false)
  local plants = stack_sum(items.PLANT, true)
  if drinks < 80 and plants >= 2 then   -- Run 5 (01.10.): PH is also the only food -> with drinks >= 80 eat raw instead of brewing
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if b:getSubtype() == df.workshop_type.Still and b:getBuildStage() >= b:getMaxBuildStage() and #b.jobs < 3 then
        add_task(b.id, 'brew drink from plant', 2)
        state.brews = (state.brews or 0) + 2
      end
    end
  end
  -- Food: kitchen cooks meals from plants/meat/fish when little prepared food is available
  local food = 0
  for _, i in ipairs(items.FOOD) do
    if not (i.flags.forbid or i.flags.rotten or i.flags.dump or i.flags.trader) then food = food + i:getStackSize() end
  end
  state.food = food
  -- Run 5 (01.10.): only with cookable ingredients (otherwise >300 aborts 'Needs unrotten cookable solid item'); raw fish does not count
  local cookable = stack_sum(items.MEAT, true)   -- PH cooking is banned (essen.lua, run 5): PH is eaten raw
  if food < 60 and cookable >= 2 then
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if b:getSubtype() == df.workshop_type.Kitchen and b:getBuildStage() >= b:getMaxBuildStage() and #b.jobs < 3 then
        add_task(b.id, 'prepare easy meal', 2)
        state.meals = (state.meals or 0) + 2
      end
    end
  end
  -- Barrels: 'Needs empty food storage item' stops brewing (run 2, 30.09.: 48 barrels, only 3 empty; the rest full of food).
  -- If < 6 free empty barrels exist and wood is available, add 'make barrel' at the carpenter (max. 2 open MakeBarrel jobs).
  do
    local free_barrels, logs = 0, 0
    for _, i in ipairs(items.BARREL) do
      local f = i.flags
      if not (f.forbid or f.dump or f.trader or f.in_building or f.rotten) and #dfhack.items.getContainedItems(i) == 0 then free_barrels = free_barrels + 1 end
    end
    for _, i in ipairs(items.WOOD) do
      local f = i.flags
      if not (f.forbid or f.dump or f.trader or f.in_job or f.rotten) then logs = logs + 1 end
    end
    state.free_barrels = free_barrels
    if free_barrels < 6 and logs >= 2 then
      for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
        if b:getSubtype() == df.workshop_type.Carpenters and b:getBuildStage() >= b:getMaxBuildStage() then
          local open = 0
          for _, j in ipairs(b.jobs) do if j.job_type == df.job_type.MakeBarrel then open = open + 1 end end
          if open < 2 then
            add_task(b.id, 'make barrel', 2)
            state.barrels_ordered = (state.barrels_ordered or 0) + 2
          end
          break
        end
      end
    end
  end
  local buckets = 0
  for _, i in ipairs(items.BUCKET) do if not i.flags.forbid then buckets = buckets + 1 end end
  -- Run 5 D3: no bucket orders without wood ('Make bucket: Needs logs' = abort loop, desert)
  local haslogs = false
  for _, i in ipairs(items.WOOD) do
    local f = i.flags
    if not (f.forbid or f.dump or f.trader or f.in_job or f.rotten or f.in_building) then haslogs = true break end
  end
  if buckets < 6 and haslogs then
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if b:getSubtype() == df.workshop_type.Carpenters and b:getBuildStage() >= b:getMaxBuildStage() and #b.jobs < 3 then
        add_task(b.id, 'make bucket', 2)
        break
      end
    end
  end
end

-- Order missing items for planned buildings directly at the workshops
local FEED_MAP = {
  ['Bed'] = { 'Carpenters', 'construct bed' }, ['Beds'] = { 'Carpenters', 'construct bed' },
  ['Door'] = { 'Carpenters', 'construct door' }, ['Doors'] = { 'Carpenters', 'construct door' },
  ['Box'] = { 'Carpenters', 'construct chest' }, ['Boxes'] = { 'Carpenters', 'construct chest' },
  ['Hatch cover'] = { 'Carpenters', 'construct hatch cover' }, ['Hatch covers'] = { 'Carpenters', 'construct hatch cover' },
  ['Table'] = { 'Masons', 'construct table' }, ['Tables'] = { 'Masons', 'construct table' },
  ['Chair'] = { 'Masons', 'construct throne' }, ['Chairs'] = { 'Masons', 'construct throne' },
  ['Coffin'] = { 'Masons', 'construct coffin' }, ['Coffins'] = { 'Masons', 'construct coffin' },
  ['Cabinet'] = { 'Masons', 'construct cabinet' }, ['Cabinets'] = { 'Masons', 'construct cabinet' },
  ['Quern'] = { 'Masons', 'construct quern' },
  ['Mechanism'] = { 'Mechanics', 'construct mechanisms' }, ['Mechanisms'] = { 'Mechanics', 'construct mechanisms' },
  ['Traction bench'] = { 'Mechanics', 'construct traction bench' }, ['Traction benchs'] = { 'Mechanics', 'construct traction bench' },
}

local function workshop_of(kind)
  local best
  for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
    if df.workshop_type[b:getSubtype()] == kind and b:getBuildStage() >= b:getMaxBuildStage() then
      if not best or #b.jobs < #best.jobs then best = b end
    end
  end
  return best
end

local function feed()
  local out = dfhack.run_command_silent('buildingplan', 'status')
  for line in tostring(out):gmatch('[^%c]+') do
    local n, name = line:match('^%s+(%d+)%s+(.-)%s*$')
    local m = n and FEED_MAP[name]
    if m and m[1] == 'Carpenters' then   -- Run 5 D6: wooden furniture only with free logs ('Make bed: Needs logs' 5645x)
      local logs = false
      for _, i in ipairs(df.global.world.items.other.WOOD) do
        local f = i.flags
        if not (f.forbid or f.dump or f.trader or f.in_job or f.rotten or f.in_building) then logs = true break end
      end
      if not logs then m = nil end
    end
    if m then
      local w = workshop_of(m[1])
      if w and #w.jobs < 6 then
        add_task(w.id, m[2], math.min(tonumber(n), 10))
        state.fed = (state.fed or 0) + 1
      end
    end
  end
  local blocks = stack_sum(df.global.world.items.other.BLOCKS, false)
  if blocks < 60 then
    local w = workshop_of('Masons')
    if w and #w.jobs < 6 then add_task(w.id, 'construct blocks', 10) end
  end
end

-- Caravan: send the broker to the depot; as soon as broker AND traders are at the depot: pause the game and
-- write tools/caravan.flag + tools/pause.hold (the real-time guard then wakes Claude).
local TOOLS = reqscript('claude/util').home() .. '/tools/'
local function write_flag(name, text)
  local f = io.open(TOOLS .. name, 'w')
  if f then f:write(text) f:close() end
end

local function caravan_watch()
  local depot
  for _, b in ipairs(df.global.world.buildings.all) do
    if df.building_type[b:getType()] == 'TradeDepot' then depot = b break end
  end
  if not depot then return end
  local car = #df.global.plotinfo.caravans > 0
  if not car then state.caravan_paused = false return end
  depot.trade_flags.trader_requested = true
  if state.caravan_paused then return end
  local function at_depot(u)
    local p = u.pos
    return p.z == depot.z and p.x >= depot.x1 and p.x <= depot.x2 and p.y >= depot.y1 and p.y <= depot.y2
  end
  local merchant, broker = false, false
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isActive(u) and u.flags1.merchant and at_depot(u) then merchant = true end
  end
  local ent = df.historical_entity.find(df.global.plotinfo.group_id)
  for _, a in ipairs(ent.positions.assignments) do
    if a.histfig >= 0 then
      local code
      for _, p in ipairs(ent.positions.own) do if p.id == a.position_id then code = p.code end end
      if code == 'BROKER' then
        local hf = df.historical_figure.find(a.histfig)
        local u = hf and df.unit.find(hf.unit_id)
        if u and at_depot(u) then broker = true end
      end
    end
  end
  if merchant and broker then
    df.global.pause_state = true
    write_flag('pause.hold', 'karawane')
    write_flag('caravan.flag', util.game_date().text)
    state.caravan_paused = true
  end
end

-- Clear the dead (mood!): mark lying corpses around the fortress for removal,
-- and ensure enough coffins for dwarf corpses (burial happens automatically).
local function corpses()
  local cfg = C()
  local marked, dwarf_loose = 0, 0
  for _, i in ipairs(df.global.world.items.other.CORPSE) do
    local f = i.flags
    if f.on_ground and not (f.forbid or f.dump or f.in_job or f.trader) then
      local p = i.pos
      if cfg.in_fort_box(p.x, p.y, p.z) then
        local r = df.creature_raw.find(i.race)
        if r and r.creature_id == 'DWARF' then
          dwarf_loose = dwarf_loose + 1
        else
          -- Refuse room (cfg.REFUSE_BOX) and dump zones (cfg.DUMP_TILES) are the destination itself; send everything else to the dump
          -- (E19: dump zone outside the stockpiles works; full refuse stockpiles previously blocked everything)
          if not (cfg.in_refuse(p.x, p.y, p.z) or cfg.in_dump(p.x, p.y, p.z)) then
            f.dump = true
            marked = marked + 1
          end
        end
      end
    end
  end
  for _, i in ipairs(df.global.world.items.other.CORPSEPIECE) do
    local f = i.flags
    if f.on_ground and not (f.forbid or f.dump or f.in_job or f.trader) then
      local p = i.pos
      if cfg.in_fort_box(p.x, p.y, p.z) and not (cfg.in_refuse(p.x, p.y, p.z) or cfg.in_dump(p.x, p.y, p.z)) then
        f.dump = true
        marked = marked + 1
      end
    end
  end
  state.corpses_marked = (state.corpses_marked or 0) + marked
  state.tomb_free = 0
  for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
    if z.type == df.civzone_type.Tomb then
      -- Every dead dwarf claims ONE tomb zone (assigned_unit_id; it stays his!) -> one 1x1 zone per coffin (quickfort `T`), never a large one.
      -- Only free (unoccupied) zones must allow citizens.
      if (z.assigned_unit_id or -1) < 0 then
        state.tomb_free = (state.tomb_free or 0) + 1
        if z.zone_settings.tomb.flags.no_citizens then
          z.zone_settings.tomb.flags.no_citizens = false
          state.tomb_fixed = (state.tomb_fixed or 0) + 1
        end
      end
    end
  end
  state.dwarf_corpses_loose = dwarf_loose
  local free = 0
  for _, i in ipairs(df.global.world.items.other.COFFIN) do if not i.flags.in_building then free = free + 1 end end
  if free < 4 then
    local w = workshop_of('Masons')
    if w and #w.jobs < 6 then add_task(w.id, 'construct coffin', 2) end
  end
end

-- Use idle time: if many adults have no job, fill workshops with standard work
local FILLER = {
  -- Run 2, year 68: filler had overproduced 32 beds/68 cabinets/54 tables/41 chairs (wood/stone wasted) -> only blocks/coffins now
  -- Masons/loom filler removed (run 2, year 70, monitor): 108 coffins in stock, 'Needs hard stone boulders' ~3000 aborts, loom 'silk thread' ~1650 aborts -> job loop; coffins are made by supplies() at free < 4.
}
local function busy()
  local adults, idle = 0, 0
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAdult(u) then
      adults = adults + 1
      if not u.job.current_job then idle = idle + 1 end
    end
  end
  state.idle = idle
  state.adults = adults
  if idle < 6 then return end
  state.rot = (state.rot or 0) + 1
  for kind, names in pairs(FILLER) do
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if df.workshop_type[b:getSubtype()] == kind and b:getBuildStage() >= b:getMaxBuildStage() and #b.jobs < 2 then
        local name = names[(state.rot % #names) + 1]
        add_task(b.id, name, 2)
        state.filled = (state.filled or 0) + 1
      end
    end
  end
end

-- Civilian alert for ground enemies in range (the player's requirement: call civilians in immediately) + slow motion + siege.flag.
-- Called frequently (every 60 ticks) so that even fast armies do not surprise.
--  * Alarm: ground enemy (cfg.is_ground_enemy: no fliers except dragons/titans) <= cfg.ALERT_RANGE tiles AND |dz| <= cfg.ALERT_DZ
--    (to the fort center or to a citizen).
--  * Slow motion: visible ground enemy <= cfg.SLOWMO_RANGE -> enabler.fps/gfps = cfg.SLOWMO_FPS (only if we set it);
--    after 5 quiet checks back to cfg.NORMAL_FPS. >= cfg.SIEGE_MIN enemies in slow-motion range -> tools/siege.flag.
-- timestream (claude/tempo): slow motion and timestream are mutually exclusive. When switching down, timestream OFF FIRST (synchronously), then lower fps;
-- when switching back only raise fps - timestream is switched on again by the guard job claude-tempo after cfg.TIMESTREAM_CALM_S of calm.
local function set_fps(v)
  if v < C().NORMAL_FPS then
    local okT, T = pcall(reqscript, 'claude/tempo')
    if okT and T then pcall(T.suspend, 'zeitlupe fps ' .. v) end
  end
  df.global.enabler.fps = v
  df.global.enabler.gfps = 30  -- SCHNELLER-run3.md: low graphics FPS = more ticks/s
end

-- Schedule calendar-based (claude/tempo.schedule) so that the intervals stay calendar ticks even with timestream; fallback: 'ticks' (= frames)
local function sched(key, n, fn)
  local okT, T = pcall(reqscript, 'claude/tempo')
  if okT and T and T.schedule then T.schedule(key, n, fn) else repeatUtil.scheduleEvery(key, n, 'ticks', fn) end
end

local function alert_check()
  if not util.fort_loaded() then return end
  local cfg = C()
  pcall(function() reqscript('claude/tempo').ensure() end)   -- Keep the timestream guard job alive
  -- Strange mood watch (E26): new mood -> tools/mood.flag with demand and stock gaps
  pcall(function() reqscript('claude/mood').watch() end)
  local cits = dfhack.units.getCitizens()
  local enemies, slow, slow_list = 0, 0, {}
  -- Run 3 (30.09.2026, lesson forgotten beast): classification/zones/reachability/event (pause + flags + alarm) in claude/gefahr.lua,
  -- independent of isInvader. On error there the watchdog falls back to the old rule (is_ground_enemy).
  local okg, G = pcall(reqscript, 'claude/gefahr')
  local S
  if okg and G then
    local oks, res = pcall(G.scan)
    if oks then S = res else state.gefahr_error = tostring(res) end
  end
  if S then
    enemies, slow, slow_list = S.alarm, S.slow, S.slow_list
    state.gefahr_A, state.gefahr_warn, state.gefahr_error = S.alarm_A, S.warn or 0, nil
    local okh, herr = pcall(G.handle, S)
    if not okh then state.gefahr_error = 'handle: ' .. tostring(herr) end
  else
    for _, u in ipairs(df.global.world.units.active) do
      if cfg.is_ground_enemy(u) then
        if cfg.in_alert_zone(u, cits) then enemies = enemies + 1 end
        if cfg.in_slowmo_zone(u) and not util.unit_hidden(u) then
          slow = slow + 1
          if #slow_list < 8 then slow_list[#slow_list + 1] = string.format('%d %s (%d,%d,%d) d=%d', u.id, util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 30), u.pos.x, u.pos.y, u.pos.z, cfg.cheb(u)) end
        end
      end
    end
  end
  state.enemies_near = enemies
  state.enemies_slow = slow
  cfg.rt.enemies_near, cfg.rt.enemies_slow = enemies, slow
  -- Slow motion
  if slow > 0 then
    state.slow_clean = 0
    if not state.slowmo then
      state.slowmo = true
      state.slowmo_prev_fps = df.global.enabler.fps
      state.slowmo_count = (state.slowmo_count or 0) + 1
      state.slowmo_since = util.game_date().text
      set_fps(cfg.SLOWMO_FPS)
    elseif df.global.enabler.fps > cfg.SLOWMO_FPS then
      set_fps(cfg.SLOWMO_FPS) -- someone turned it back while enemies are present
    end
    cfg.rt.slowmo = true
    if slow >= cfg.SIEGE_MIN and not state.siege_flagged then
      state.siege_flagged = true
      write_flag('siege.flag', os.date('%H:%M:%S') .. ' ' .. util.game_date().text .. ' ' .. slow .. ' Bodenfeinde <= ' .. cfg.SLOWMO_RANGE .. ' Kacheln (Zeitlupe fps ' .. cfg.SLOWMO_FPS .. ')' .. string.char(10) .. table.concat(slow_list, string.char(10)))
    end
  else
    state.slow_clean = (state.slow_clean or 0) + 1
    if state.slowmo and state.slow_clean >= 5 then
      state.slowmo = false
      state.siege_flagged = false
      set_fps(cfg.NORMAL_FPS)
      cfg.rt.slowmo = false
    end
  end
  local al = df.global.plotinfo.alerts
  if enemies > 0 then
    state.clean = 0
    -- Run 3: civ_alert_idx = 1 only if alarm 1 exists AND has a refuge burrow (before: index outside the list possible)
    if al.civ_alert_idx == 0 and not (#al.list > 1 and #al.list[1].burrows > 0) then
      pcall(dfhack.run_command, 'claude/mil', 'refuge')   -- Alarm/burrow missing (often gone after loading): recreate idempotently
    end
    if al.civ_alert_idx == 0 and #al.list > 1 and #al.list[1].burrows > 0 then
      al.civ_alert_idx = 1
      state.alarms = state.alarms + 1
      state.last_alarm = util.game_date().text
    end
  else
    state.clean = state.clean + 1
    if state.clean >= 5 and al.civ_alert_idx ~= 0 then al.civ_alert_idx = 0 end
  end
end

local function check()
  if not util.fort_loaded() then return end
  pcall(supplies)
  pcall(feed)
  pcall(corpses)
  pcall(busy)
  pcall(caravan_watch)

  local p = df.global.world.status.popups
  while #p > 0 do
    local x = p[#p - 1]
    p:erase(#p - 1)
    x:delete()
    state.popups = state.popups + 1
  end
end

local cmd = ({ ... })[1] or 'status'
local cfg = C()
if cmd == 'start' then
  -- stuck slow motion (restart of the job loses state) is reverted; alert_check immediately sets it again for enemies
  if df.global.enabler.fps == cfg.SLOWMO_FPS then set_fps(cfg.NORMAL_FPS) end
  sched(KEY, INTERVAL, check)
  sched(KEY .. '-alert', 60, alert_check)
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  repeatUtil.cancel(KEY .. '-alert')
  if state.slowmo then set_fps(cfg.NORMAL_FPS) state.slowmo = false cfg.rt.slowmo = false end
end
util.emit({ running = repeatUtil.isScheduled and repeatUtil.isScheduled(KEY) or (cmd == 'start'),
            brews = state.brews or 0, free_barrels = state.free_barrels, barrels_ordered = state.barrels_ordered or 0, fed = state.fed or 0, alarms = state.alarms, last_alarm = state.last_alarm, popups_dismissed = state.popups,
            civ_alert_active = df.global.plotinfo.alerts.civ_alert_idx, enemies_near = state.enemies_near, enemies_slowmo_range = state.enemies_slow,
            gefahr_A = state.gefahr_A, gefahr_warn = state.gefahr_warn, gefahr_error = state.gefahr_error, slowmo = state.slowmo or false, slowmo_count = state.slowmo_count or 0,
            fps = math.floor(df.global.enabler.fps) })
