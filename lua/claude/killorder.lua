--@ module = true
-- claude/killorder.lua (also: lua -f hack/scripts/claude/killorder.lua)  (run 3, Razordrums; scope militaer) - kill order for all squads against intruders in the INTERIOR
-- Call (from the hack folder):  dfhack-run.exe lua -f "<path>/tools/killorder.lua" -- [options]
--   (no option)        find targets and write the kill order (squad_order_kill_listst) into ALL squads with members
--   --dry              dry run: only show targets/squads, change nothing  (test run in peacetime)
--   --release          delete all kill orders of the fort squads (aftercare!  Without orders soldiers eat/drink normally)
--   --status           show the state of squads/orders
--   --surface          additionally allow the surface (z146) inside the fort box (courtyards, forecourts) as a target
--   --include=1,2,3    (only --dry or --selftest) additionally simulate these unit IDs as targets (format test in peacetime)
--   --selftest         structure test in peacetime: sets the order with --include targets (preferably DEAD units), does not wait, deletes it again immediately
--   --squad=25         only this squad
--   --watch            guard job: re-collect targets every 120 ticks, update the order, automatically --release after 4 clean checks
--                      or 3000 ticks (stops with  --unwatch)
--   --unwatch          stop the guard job
-- INTERIOR (definition, map Razordrums; all values from lua/claude/config.lua or below):
--   * fort box x132..164, y126..170 (KASTEN below) on levels z141..145 (below the surface z146)
--   * shaft D: x134..138, y152..172 (corridor x=136 y155..168, door (136,168), shaft head (136,169)) on z141..145
--     (the shaft below z<141 and the caverns z91..117 do NOT belong to it: otherwise squads would run 50 levels into the cave).
-- TARGETS (config.is_intruder): active, living, visible (not 'hidden'), non-captured units that are NOT citizens/pets/traders/
--   guests/residents (amphibian people) and either count as dangerous (isDanger/invader/undead/monster) OR are non-harmless wildlife
--   (Drunians = curious beasts, run 3). Undiscovered tiles
--   are never evaluated (fair play, as via the interface).
-- The command corresponds to the kill menu of the squad window; ran without a crash in run 2 (Wheelsblows).
-- PROTECTION: squads without members are skipped. BUG-426: caged/chained units are never targets (config.is_captive); squads with a
--   member at thirst > 40000 / hunger > 60000 get NO kill order and lose an existing one (soldiers on a kill order never eat/drink);
--   existing kill orders are scrubbed of caged/chained/dead targets on every run (scrub_orders, also from `claude/mil guard`).
-- Module use (reqscript('claude/killorder')): scrub_orders(), relieve_starving() - the command part below is skipped.
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local repeatUtil = require('repeat-util')

local LOG = reqscript('claude/util').home() .. '/tools/out/killorder.log'
local WATCH_KEY = 'claude-killwatch'

-- Map Razordrums: INTERIOR boxes (fort box z141..145 + shaft D) are in lua/claude/config.lua (INNEN_BOXEN / interior_name)
-- Run 5: box relative to the fort center (config), no fixed coordinates of an old map
local KASTEN = { x1 = cfg.FORT_X - 30, x2 = cfg.FORT_X + 30, y1 = cfg.FORT_Y - 30, y2 = cfg.FORT_Y + 30, z1 = cfg.Z_MIN, z2 = cfg.SURFACE_Z - 1 }  -- only for --surface (surface inside the box)

local args = { ... }
local opt = {}
for _, a in ipairs(args) do
  local k, v = a:match('^%-%-([%w%-]+)=?(.*)$')
  if k then opt[k] = (v ~= '' and v) or true end
end

local function log(s)
  local f = io.open(LOG, 'a')
  if f then f:write(os.date('%H:%M:%S ') .. s .. '\n') f:close() end
end

local function inside(x, y, z, r) return x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 and z >= r.z1 and z <= r.z2 end

local function interior(u)
  local p = u.pos
  if p.x < 0 then return nil end
  local n = cfg.interior_name(p.x, p.y, p.z)
  if n then return n end
  if opt.surface and inside(p.x, p.y, p.z, { x1 = KASTEN.x1, x2 = KASTEN.x2, y1 = KASTEN.y1, y2 = KASTEN.y2, z1 = cfg.SURFACE_Z, z2 = cfg.SURFACE_Z }) then
    return 'Oberflaeche'
  end
  return nil
end

-- BUG-423/426: prisoners never count (config.is_captive; fallback for an old merged config.lua without it)
local function captive(u)
  local f = cfg.is_captive
  if f then return f(u) end
  return (u.flags1.caged or u.flags1.chained) and true or false
end

local function is_target(u)
  if captive(u) then return false end   -- BUG-426: a caged dragon drew kill orders until the squads starved
  if util.unit_hidden(u) then return false end
  return cfg.is_intruder(u)
end

local function find_targets()
  local list = {}
  for _, u in ipairs(df.global.world.units.active) do
    local where = interior(u)
    if where and is_target(u) then
      list[#list + 1] = { unit = u, where = where }
    end
  end
  if (opt.dry or opt.selftest) and type(opt.include) == 'string' then
    for id in opt.include:gmatch('%d+') do
      local u = df.unit.find(tonumber(id))
      if u then list[#list + 1] = { unit = u, where = 'SIM', sim = true } end
    end
  end
  return list
end

local function fort_squads()
  local res = {}
  local ent_id = df.global.plotinfo.group_id
  for _, sid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
    local sq = df.squad.find(sid)
    if sq and sq.entity_id == ent_id and (not tonumber(opt.squad) or sq.id == tonumber(opt.squad)) then
      local members, thirsty, hungry = 0, 0, 0
      for i = 0, #sq.positions - 1 do
        local occ = sq.positions[i].occupant
        if occ ~= -1 then
          local hf = df.historical_figure.find(occ)
          local u = hf and df.unit.find(hf.unit_id)
          if u and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then
            members = members + 1
            if u.counters2.thirst_timer > 40000 then thirsty = thirsty + 1 end   -- = STARVE_THIRST
            if u.counters2.hunger_timer > 60000 then hungry = hungry + 1 end     -- = STARVE_HUNGER
          end
        end
      end
      res[#res + 1] = { sq = sq, members = members, thirsty = thirsty, hungry = hungry }
    end
  end
  return res
end

local function clear_kill(sq)
  local n = 0
  for i = #sq.orders - 1, 0, -1 do
    local o = sq.orders[i]
    if df.squad_order_kill_listst:is_instance(o) then sq.orders:erase(i) pcall(function() o:delete() end) n = n + 1 end
  end
  return n
end

local STARVE_THIRST, STARVE_HUNGER = 40000, 60000   -- same limits as fort_squads (thirsty/hungry)

-- BUG-426 self-healing: remove caged/chained/dead/missing units from all kill orders of the fort squads; empty orders are deleted.
-- Logs each (squad, unit) once. Returns the number of removed targets.
SCRUBBED = SCRUBBED or {}
function scrub_orders()
  local n = 0
  for _, s in ipairs(fort_squads()) do
    for i = #s.sq.orders - 1, 0, -1 do
      local o = s.sq.orders[i]
      if df.squad_order_kill_listst:is_instance(o) then
        for k = #o.units - 1, 0, -1 do
          local id = o.units[k]
          local u = df.unit.find(id)
          if not u or dfhack.units.isDead(u) or captive(u) then
            if u and u.hist_figure_id >= 0 then
              for h = #o.histfigs - 1, 0, -1 do if o.histfigs[h] == u.hist_figure_id then o.histfigs:erase(h) end end
            end
            o.units:erase(k)
            n = n + 1
            local key = s.sq.id .. ':' .. id
            if not SCRUBBED[key] then
              SCRUBBED[key] = true
              log(string.format('scrub Trupp %d: Ziel %d entfernt (%s)', s.sq.id, id, not u and 'fehlt' or (dfhack.units.isDead(u) and 'tot' or 'gefangen')))
            end
          end
        end
        if #o.units == 0 and #o.histfigs == 0 then s.sq.orders:erase(i) pcall(function() o:delete() end) end
      end
    end
  end
  return n
end

local function has_kill(sq)
  for i = 0, #sq.orders - 1 do if df.squad_order_kill_listst:is_instance(sq.orders[i]) then return true end end
  return false
end

-- BUG-426: squads standing on a kill order with a thirsty/hungry member lose the order (they eat/drink, the next run sets it again).
-- Returns the number of relieved squads.
function relieve_starving()
  local n = 0
  for _, s in ipairs(fort_squads()) do
    if (s.thirsty > 0 or s.hungry > 0) and has_kill(s.sq) then
      clear_kill(s.sq)
      n = n + 1
      log(string.format('Trupp %d: Kill-Befehl entzogen (%d durstig, %d hungrig) - Soldaten sollen essen/trinken', s.sq.id, s.thirsty, s.hungry))
    end
  end
  return n
end

local function release()
  local n = 0
  for _, s in ipairs(fort_squads()) do n = n + clear_kill(s.sq) end
  print('Kill-Befehle geloescht:', n)
  log('release ' .. n)
  return n
end

local function status()
  for _, s in ipairs(fort_squads()) do
    local ords = {}
    for i = 0, #s.sq.orders - 1 do ords[#ords + 1] = df.squad_order_type[s.sq.orders[i]:getType()] end
    print(string.format('Trupp %d %s: %d Mitglieder, routine %d, Befehle [%s], durstig %d, hungrig %d', s.sq.id,
      dfhack.military.getSquadName(s.sq.id), s.members, s.sq.cur_routine_idx, table.concat(ords, ','), s.thirsty, s.hungry))
  end
  local t = find_targets()
  print('Ziele im Inneren (sichtbar):', #t)
  for _, x in ipairs(t) do
    local u = x.unit
    print(string.format('  %d %s (%d,%d,%d) %s', u.id, util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 40), u.pos.x, u.pos.y, u.pos.z, x.where))
  end
  local w = rawget(_G, 'CLAUDE_KILLWATCH')
  print('Wachjob:', w and w.active and ('aktiv seit ' .. w.since) or 'aus')
end

local function apply(targets)
  local done = 0
  for _, s in ipairs(fort_squads()) do
    local starving = s.thirsty > 0 or s.hungry > 0
    if s.members == 0 then
      print('Trupp ' .. s.sq.id .. ': keine Mitglieder, uebersprungen')
    elseif starving then
      -- BUG-426: soldiers on a kill order do not eat/drink -> no order (an old one is withdrawn) until they are fed
      local n = clear_kill(s.sq)
      print(string.format('Trupp %d: %d durstig/%d hungrig - KEIN Kill-Befehl%s (Soldaten essen nur ohne Befehl)', s.sq.id, s.thirsty, s.hungry, n > 0 and ', alter Befehl entzogen' or ''))
      log(string.format('Trupp %d: hungrig/durstig, kein Kill-Befehl (%d entzogen)', s.sq.id, n))
    end
    if s.members > 0 and not starving and #targets > 0 then
      clear_kill(s.sq)
      local o = df.squad_order_kill_listst:new()
      for _, x in ipairs(targets) do
        o.units:insert('#', x.unit.id)
        if x.unit.hist_figure_id >= 0 then o.histfigs:insert('#', x.unit.hist_figure_id) end
      end
      o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
      s.sq.orders:insert('#', o)
      done = done + 1
      print('Trupp ' .. s.sq.id .. ': Kill-Befehl auf ' .. #targets .. ' Ziele (Befehle gesamt ' .. #s.sq.orders .. ')')
    end
  end
  return done
end

local function say(text, prio)
  pcall(function() dfhack.run_command('claude/schau', 'say', text, tostring(prio or 4)) end)
end

-- ---------------------------------------------------------------- guard job
local function watch_tick()
  local W = rawget(_G, 'CLAUDE_KILLWATCH')
  if not W or not W.active then repeatUtil.cancel(WATCH_KEY) return end
  local ok, err = pcall(function()
    W.ticks = W.ticks + 120
    scrub_orders()
    local t = find_targets()
    if #t == 0 then W.clean = W.clean + 1 else W.clean = 0 apply(t) end
    if W.clean >= 4 or W.ticks >= 3000 then
      release()
      W.active = false
      repeatUtil.cancel(WATCH_KEY)
      log('watch Ende clean=' .. W.clean .. ' ticks=' .. W.ticks)
      say('Eindringlinge im Inneren beseitigt - Kill-Befehl aufgehoben', 3)
    end
  end)
  if not ok then log('watch FEHLER ' .. tostring(err)) end
end

-- module use: only the functions above (BUG-426, claude/mil guard)
if dfhack_flags and dfhack_flags.module then return end

if opt.unwatch then
  local W = rawget(_G, 'CLAUDE_KILLWATCH')
  if W then W.active = false end
  repeatUtil.cancel(WATCH_KEY)
  print('Wachjob gestoppt')
  return
end
if opt.release then release() return end
if opt.status then status() return end

if not opt.dry then scrub_orders() end
local targets = find_targets()
if opt.selftest then
  local n = apply(targets)
  local ords = 0
  for _, s in ipairs(fort_squads()) do ords = ords + #s.sq.orders end
  print('selftest: Befehle gesetzt in', n, 'Trupps, Befehle gesamt', ords)
  release()
  ords = 0
  for _, s in ipairs(fort_squads()) do ords = ords + #s.sq.orders end
  print('selftest: nach release Befehle gesamt', ords)
  return
end
print('Ziele im Inneren:', #targets, opt.dry and '(Trockenlauf)' or '')
for _, x in ipairs(targets) do
  local u = x.unit
  print(string.format('  %d %s (%d,%d,%d) [%s]%s', u.id, util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 40), u.pos.x, u.pos.y, u.pos.z, x.where, x.sim and ' SIMULIERT' or ''))
end
if opt.dry then
  for _, s in ipairs(fort_squads()) do
    print(string.format('Trupp %d %s: %d Mitglieder, durstig %d, hungrig %d -> wuerde %s', s.sq.id, dfhack.military.getSquadName(s.sq.id), s.members, s.thirsty, s.hungry,
      (#targets > 0 and s.members > 0) and 'Kill-Befehl erhalten' or 'nichts tun'))
  end
  return
end
if #targets == 0 then
  print('keine Ziele - nichts gesetzt')
  if not opt.watch then return end
end
if #targets > 0 then
  local n = apply(targets)
  log(string.format('apply %d Ziele, %d Trupps', #targets, n))
  local first = targets[1].unit
  say(string.format('ALARM innen: %d Eindringlinge (%s) - Trupps greifen an', #targets, util.cut(dfhack.df2utf(dfhack.units.getReadableName(first)), 24)), 5)
end
if opt.watch then
  rawset(_G, 'CLAUDE_KILLWATCH', { active = true, since = os.date('%H:%M:%S'), ticks = 0, clean = 0 })
  repeatUtil.scheduleEvery(WATCH_KEY, 120, 'ticks', watch_tick)
  print('Wachjob aktiv (120 Ticks, Ende nach 4 sauberen Pruefungen / 3000 Ticks)')
end
