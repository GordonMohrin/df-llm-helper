-- claude/mil <status|report|equip|routines|enemies|plan|train|station|kill|release> [Optionen]
-- Military control WITHOUT desktop (research VERTEIDIGUNG-AUTOMATION.md). Default = READ ONLY / dry run.
--   status            squads, members, routine, orders, equipment, thirst/hunger (read)
--   report            one compact line + log tools/out/mil.log (read, for schedules)
--   equip [--squad N] equipment check per member: uniform slots / assigned items / worn (read)
--   routines          routine schedules (Off duty/Staggered/Constant/Ready) per squad (read)
--   enemies           visible enemies (isDanger, not citizen, not captive, not hidden) (read)
--   plan              alarm plan as text: what would happen (read, dry run)
--   train <squad> <idx> [--apply]   set cur_routine_idx (= UI dropdown routine); without --apply display only
--   station <squad> <x> <y> <z> [--apply --experimental]   move/station order (UNTESTED, see docs)
--   kill <squad> <unitid,...> [--apply --experimental]     kill order (UNTESTED)
--   release <squad> [--apply --experimental]              delete orders (UNTESTED)
-- Run 3 (30.09.2026, TESTED on the running game, no crash; documentation tools/scopes/militaer.md):
--   create <name> <leader_unit_id> [--apply]   create a new squad (MILITIA_CAPTAIN assignment + makeSquad + leader pos 0); the answer always
--                                              carries squad_id (or error); empty squads to reuse are listed as reuse_hint
--   add <squad> <unit_id> [--apply]            member into the first free slot >= 1 (slot 0 = leader last); answer: ok + slot, or ok=false
--                                              + reason (squad full / already in a squad / addToSquad refused); removes labors MINE/CUTWOOD/HUNT
--   remove <squad> <unit_id> [--apply]         remove member (ok=false + reason on failure)
--   rename <squad> <name> [--apply]            rename a squad (UI: squad name) - to REUSE an empty squad
--   NOTE (BUG-425): squads can NOT be deleted through DFHack (no API, no player action we can mirror); empty squads stay in the list.
--   Reuse them (rename + add) instead of creating new ones; `status` marks them with empty = true.
--   uniform <squad> <tpl_idx> [weapon_subtype] [--apply]   uniform template (entity.uniforms[i]) onto ALL positions; fixed weapon
--                                              (default 1 = ITEM_WEAPON_AXE_BATTLE; -1 = template 'best melee weapon'); triggers update
--   barracks <squad> <zone_id> [--apply]       assign barracks as training room (updateRoomAssignments train=true)
--   update [--apply]                           trigger 'Update equipment' (plotinfo.equipment.update.* = true)
--   workmode <squad> on|off [--apply]          WORK MODE (E18 solution): squad works as militia miners. on = uniform only weapon pick (no armor),
--                                              delete old weapon/armor assignments, routine 0 (Off duty, civilian clothes), labor MINE + work detail Miners.
--                                              off = battle axe + metal armor (template 1) + constant training (routine 2). Without --apply display only.
--   pickfix [--apply] [--ensure ids]           E18 SOLUTION run 5: releases reserved free picks, removes pick uniform specs of all squads, update.weapon
--                                              -> engine distributes work picks to all MINE dwarves (see pickfix.lua). Replaces workmode on.
--   ammo <squad> [amount=25] [subtype=0] [--apply]   squad ammunition (UI: squad equipment -> ammunition): one AMMO spec
--                                              (combat + training) replaces the existing ones, then ammo/quiver update
--   refuge [--apply]                           create/check refuge burrow (config.ZUFLUCHT.rects) + civilian alert; existing
--                                              tiles are only replaced when rects are configured
--   refuge check                               read only (BUG-423): drink/food/wells/water tiles/hospital inside the refuge burrow;
--                                              problems ZUFLUCHT OHNE WASSER / ZUFLUCHT OHNE ESSEN; FEATURE-005: status per
--                                              category OK/MISSING/UNREACHABLE (canWalkBetween from the hospital/probe anchor), lines
--   guard start|stop|status                    guard job (60 ticks): visible intruder in the INTERIOR (config.INNEN_BOXEN) -> tools/killorder.lua --watch
-- Protection: pcall everywhere, log, no change without --apply; station/kill/release only with --experimental AND
-- after agreement with scope agent militaer. Fair play: no unit/item manipulation, no reveal.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local LOG = reqscript('claude/util').home() .. '/tools/out/mil.log'
local cfg = reqscript('claude/config')   -- FORT_X/Y, ALERT_RANGE, ALERT_DZ per map
local FORT_X, FORT_Y, RANGE = cfg.FORT_X, cfg.FORT_Y, cfg.ALERT_RANGE
local THIRST_WARN, HUNGER_WARN = 30000, 40000 -- ticks; limit ~50000 (thirst) cf. ueberwacher 45000/60000

local args = { ... }
local cmd = table.remove(args, 1) or 'status'
local opt, pos = {}, {}
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--squad' then opt.squad = tonumber(args[i + 1]) i = i + 2
    elseif a:sub(1, 2) == '--' then opt[a:sub(3)] = true i = i + 1
    else pos[#pos + 1] = a i = i + 1 end
  end
end
local dry = not opt.apply

local function log(s)
  util.append_log(LOG, os.date('%H:%M:%S ') .. cmd .. ' ' .. s)
end
local function nm(u) return util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 40) end
local function out(t) util.emit(t) end

local function squads()
  local res = {}
  for _, id in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
    local s = df.squad.find(id)
    if s then res[#res + 1] = s end
  end
  return res
end

local function member_unit(p)
  if p.occupant == -1 then return nil end
  local hf = df.historical_figure.find(p.occupant)
  return hf and df.unit.find(hf.unit_id) or nil
end

local function slots_needed(p)
  local n = 0
  for _, name in ipairs{ 'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon' } do
    n = n + #p.equipment.uniform[name]
  end
  return n
end

local function worn_count(u)
  local worn, weapon = 0, 0
  for _, ii in ipairs(u.inventory) do
    if ii.mode == df.inv_item_role_type.Worn then worn = worn + 1
    elseif ii.mode == df.inv_item_role_type.Weapon then weapon = weapon + 1 end
  end
  return worn, weapon
end

-- BUG-423/426: prisoners never count (config.is_captive; fallback for an old merged config.lua without it)
local function captive(u)
  local f = cfg.is_captive
  if f then return f(u) end
  return (u.flags1.caged or u.flags1.chained) and true or false
end

local function enemies()
  local res = {}
  for _, u in ipairs(df.global.world.units.active) do
    local ok = dfhack.units.isActive(u) and not dfhack.units.isDead(u) and dfhack.units.isDanger(u)
      and not dfhack.units.isCitizen(u) and not captive(u)
    if ok and not util.unit_hidden(u) then
      local d = math.max(math.abs(u.pos.x - FORT_X), math.abs(u.pos.y - FORT_Y))
      res[#res + 1] = { id = u.id, name = nm(u), x = u.pos.x, y = u.pos.y, z = u.pos.z, dist = d,
        near = cfg.is_ground_enemy(u) and cfg.in_alert_zone(u), flier = cfg.is_flier(u), great = dfhack.units.isGreatDanger(u) }
    end
  end
  table.sort(res, function(a, b) return a.dist < b.dist end)
  return res
end

local function squad_info(s, detail)
  local occ, members = 0, {}
  local routines = { [0] = 'Off duty', 'Staggered training', 'Constant training', 'Ready' } -- assumption, cf. docs
  local minfo = { thirsty = 0, hungry = 0, incomplete = 0 }
  for i = 0, #s.positions - 1 do
    local p = s.positions[i]
    local u = member_unit(p)
    if u then
      occ = occ + 1
      local need = slots_needed(p)
      local assigned = #p.equipment.assigned_items
      local worn, weapon = worn_count(u)
      local th, hu = u.counters2.thirst_timer, u.counters2.hunger_timer
      if th > THIRST_WARN then minfo.thirsty = minfo.thirsty + 1 end
      if hu > HUNGER_WARN then minfo.hungry = minfo.hungry + 1 end
      if assigned < need or weapon == 0 then minfo.incomplete = minfo.incomplete + 1 end -- Heuristic: gaps in the assignment / no weapon
      if detail then
        members[#members + 1] = { pos = i, id = u.id, name = nm(u), slots = need, assigned = assigned,
          worn = worn, weapon = weapon, thirst = th, hunger = hu, job = u.job.current_job and df.job_type[u.job.current_job.job_type] or '-',
          dead = dfhack.units.isDead(u) }
      end
    end
  end
  local ords = {}
  for _, o in ipairs(s.orders) do ords[#ords + 1] = df.squad_order_type[o:getType()] end
  return { id = s.id, name = dfhack.military.getSquadName(s.id), routine = s.cur_routine_idx,
    routine_name = routines[s.cur_routine_idx] or '?', members = occ, of = #s.positions, orders = ords, empty = (occ == 0),
    thirsty = minfo.thirsty, hungry = minfo.hungry, equip_incomplete = minfo.incomplete,
    detail = detail and members or nil }
end

-- burrow_blocks_max = map blocks (16x16), not tiles
local function civ_state()
  local al = df.global.plotinfo.alerts
  local tiles = 0
  for _, b in ipairs(df.global.plotinfo.burrows.list) do tiles = math.max(tiles, #b.block_x) end
  return { civ_alert_idx = al.civ_alert_idx, alerts = #al.list, burrow_blocks_max = tiles }
end

local function find_squad(id)
  local s = id and df.squad.find(id)
  if not s or s.entity_id ~= df.global.plotinfo.group_id then return nil end
  return s
end

-- ---------------------------------------------------------------- Guard job (interior intruders -> kill order)
local KILL_SCRIPT = dfhack.getDFPath() .. '/hack/scripts/claude/killorder.lua'
local GUARD_KEY = 'claude-milguard'
local function guard_tick()
  local G = rawget(_G, 'CLAUDE_MILGUARD')
  if not G or not G.active then require('repeat-util').cancel(GUARD_KEY) return end
  if not util.fort_loaded() then return end
  local okg, errg = pcall(function()
    local n, first = 0, nil
    for _, u in ipairs(df.global.world.units.active) do
      if cfg.interior_name(u.pos.x, u.pos.y, u.pos.z) and cfg.is_intruder(u) and not util.unit_hidden(u) then
        n = n + 1 first = first or u
      end
    end
    G.last_targets, G.checks = n, (G.checks or 0) + 1
    -- Run 3 (30.09.): second safeguard of the alarm system (if the watchdog job hangs): same event logic (cooldown per unit prevents double alarm)
    -- Speed (30.09.): scan only if the watchdog scan is > 70 calendar ticks old (both jobs run every 60 -> otherwise duplicate 7 ms scans; the safeguard kicks in if the watchdog hangs)
    pcall(function()
      local GS = rawget(_G, 'CLAUDE_GEFAHR')
      local now_t = df.global.cur_year * 403200 + df.global.cur_year_tick
      if GS and GS.last_scan_tick and now_t >= GS.last_scan_tick and now_t - GS.last_scan_tick <= 70 then return end
      local GF = reqscript('claude/gefahr') GF.handle(GF.scan())
    end)
    -- BUG-426: drop kill-order targets that are caged/chained/dead and orders of starving squads (every guard tick, also without killwatch)
    pcall(function()
      local K = reqscript('claude/killorder')
      local sc, st = K.scrub_orders(), K.relieve_starving()
      if sc > 0 or st > 0 then
        local f = io.open(LOG, 'a')
        if f then f:write(os.date('%H:%M:%S ') .. 'guard: ' .. sc .. ' Kill-Ziele (gefangen/tot) entfernt, ' .. st .. ' Trupps wegen Hunger/Durst entlassen' .. string.char(10)) f:close() end
      end
    end)
    local W = rawget(_G, 'CLAUDE_KILLWATCH')
    if n > 0 and not (W and W.active) then
      G.hits, G.last_hit = (G.hits or 0) + 1, os.date('%H:%M:%S')
      dfhack.run_command('lua', '-f', KILL_SCRIPT, '--watch')
      local f = io.open(LOG, 'a')
      if f then f:write(os.date('%H:%M:%S ') .. 'guard TREFFER ' .. n .. ' Eindringlinge im Inneren, killorder --watch gestartet (erster: ' .. nm(first) .. ')' .. string.char(10)) f:close() end
    end
  end)
  if not okg then
    local f = io.open(LOG, 'a')
    if f then f:write(os.date('%H:%M:%S ') .. 'guard FEHLER ' .. tostring(errg) .. string.char(10)) f:close() end
  end
end

local ok, err = pcall(function()
  if cmd == 'status' then
    local res = {}
    for _, s in ipairs(squads()) do
      if not opt.squad or opt.squad == s.id then res[#res + 1] = squad_info(s, true) end
    end
    local e = enemies()
    out({ squads = res, civ = civ_state(), enemies_visible = #e, enemies_near = (function() local n = 0 for _, x in ipairs(e) do if x.near then n = n + 1 end end return n end)() })

  elseif cmd == 'report' then
    local e, parts = enemies(), {}
    local near = 0
    for _, x in ipairs(e) do if x.near then near = near + 1 end end
    for _, s in ipairs(squads()) do
      local i = squad_info(s, false)
      parts[#parts + 1] = string.format('%s[%d/%d r%d o%d dur%d hun%d eq%d]', i.name, i.members, i.of, i.routine, #i.orders, i.thirsty, i.hungry, i.equip_incomplete)
    end
    local line = string.format('feinde=%d nah=%d civ=%d %s', #e, near, df.global.plotinfo.alerts.civ_alert_idx, table.concat(parts, ' '))
    log(line) print(line)

  elseif cmd == 'equip' then
    local res = {}
    for _, s in ipairs(squads()) do
      if not opt.squad or opt.squad == s.id then
        local i = squad_info(s, true)
        local bad = {}
        for _, m in ipairs(i.detail) do
          if m.assigned < m.slots or m.weapon == 0 then bad[#bad + 1] = m end
        end
        res[#res + 1] = { squad = i.id, name = i.name, members = i.members, incomplete = bad,
          hinweis = 'Zuweisung neuer Items ("Update equipment") ist per API NICHT ausloesbar; nur Kontrolle. Hilfsmittel: uniform-unstick (Doku).' }
      end
    end
    out({ equip = res })

  elseif cmd == 'routines' then
    local res = {}
    for _, s in ipairs(squads()) do
      local r = {}
      for ri = 0, #s.schedule.routine - 1 do
        local e0, e11 = s.schedule.routine[ri].month[0], s.schedule.routine[ri].month[11]
        r[#r + 1] = { idx = ri, sleep = e0.sleep_mode, uniform = e0.uniform_mode, orders = #e0.orders,
          order_types = (function() local t = {} for _, o in ipairs(e0.orders) do t[#t + 1] = df.squad_order_type[o.order:getType()] end return t end)() }
      end
      res[#res + 1] = { squad = s.id, name = dfhack.military.getSquadName(s.id), current = s.cur_routine_idx, routines = r }
    end
    out({ routines = res })

  elseif cmd == 'enemies' then
    out({ enemies = enemies(), civ = civ_state() })

  elseif cmd == 'plan' then
    local e = enemies()
    local near = {}
    for _, x in ipairs(e) do if x.near then near[#near + 1] = x end end
    local steps = {}
    if #near == 0 then steps[#steps + 1] = 'Keine Feinde in Reichweite: kein Alarm noetig (ggf. Zivilwarnung aus).'
    else
      steps[#steps + 1] = string.format('1. Zivilwarnung AN (%d Feinde nah; naechster %s dist %d)', #near, near[1].name, near[1].dist)
      for _, s in ipairs(squads()) do
        local i = squad_info(s, false)
        steps[#steps + 1] = string.format('2. Trupp %s (%d Mitglieder, Ausruestung unvollst.: %d, durstig: %d): Routine/Station pruefen', i.name, i.members, i.equip_incomplete, i.thirsty)
      end
      steps[#steps + 1] = '3. Kill/Station erst nach Freigabe durch Scope-Agent militaer (--experimental).'
      steps[#steps + 1] = '4. Entwarnung: keine Feinde 5 Pruefzyklen -> Zivilwarnung aus, Trupp-Befehle loeschen, Routine zurueck auf Training.'
    end
    out({ plan = steps, civ = civ_state() })

  elseif cmd == 'train' then
    local s = find_squad(tonumber(pos[1]))
    local idx = tonumber(pos[2])
    if not s or not idx or idx < 0 or idx >= #s.schedule.routine then out({ error = 'usage: train <squad_id> <routine_idx 0..3> [--apply]' }) return end
    local msg = { squad = s.id, from = s.cur_routine_idx, to = idx, dry = dry }
    if not dry then s.cur_routine_idx = idx log('train squad ' .. s.id .. ' -> ' .. idx) end
    out(msg)

  elseif cmd == 'station' or cmd == 'kill' or cmd == 'release' then
    local s = find_squad(tonumber(pos[1]))
    if not s then out({ error = 'Trupp nicht gefunden' }) return end
    local info = squad_info(s, false)
    -- Protection checks: station/order prevents eating/drinking (run 2: archers almost died of thirst)
    local risk = {}
    if info.thirsty > 0 then risk[#risk + 1] = info.thirsty .. ' Mitglieder durstig' end
    if info.hungry > 0 then risk[#risk + 1] = info.hungry .. ' Mitglieder hungrig' end
    if info.equip_incomplete > 0 then risk[#risk + 1] = info.equip_incomplete .. ' Mitglieder ohne volle Ausruestung' end
    local plan = { squad = s.id, name = info.name, cmd = cmd, dry = dry, existing_orders = info.orders, risks = risk }
    if cmd == 'station' then
      local x, y, z = tonumber(pos[2]), tonumber(pos[3]), tonumber(pos[4])
      if not (x and y and z) then out({ error = 'usage: station <squad> <x> <y> <z>' }) return end
      plan.target = { x = x, y = y, z = z }
      plan.hinweis = 'Nach Gefahr Befehle loeschen (release), sonst essen/trinken Soldaten nicht.'
    elseif cmd == 'kill' then
      local ids, list = pos[2] or '', {}
      for id in ids:gmatch('%d+') do
        local u = df.unit.find(tonumber(id))
        if u and dfhack.units.isDanger(u) and not dfhack.units.isCitizen(u) and not captive(u) and not util.unit_hidden(u) then list[#list + 1] = u.id
        else plan.skipped = (plan.skipped or '') .. id .. ' ' end
      end
      plan.targets = list
    end
    if dry or not opt.experimental then
      plan.hinweis2 = 'Trockenlauf. Scharf nur mit --apply --experimental (nach Absprache; Struktur ungetestet).'
      out(plan) return
    end
    if #risk > 0 and not opt.force then plan.abbruch = 'Schutzpruefung: ' .. table.concat(risk, ', ') .. ' (--force zum Ueberstimmen)' out(plan) return end
    -- EXPERIMENTAL: creates the same order objects as the squad menu. Never tested on the running game.
    if cmd == 'release' then
      for i = #s.orders - 1, 0, -1 do local o = s.orders[i] s.orders:erase(i) pcall(function() o:delete() end) end
      log('release squad ' .. s.id)
    elseif cmd == 'station' then
      local o = df.squad_order_movest:new()
      o.pos.x, o.pos.y, o.pos.z = plan.target.x, plan.target.y, plan.target.z
      o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
      s.orders:insert('#', o)
      log(string.format('station squad %d -> %d,%d,%d', s.id, plan.target.x, plan.target.y, plan.target.z))
    elseif cmd == 'kill' then
      local o = df.squad_order_kill_listst:new()
      for _, id in ipairs(plan.targets) do o.units:insert('#', id) end
      o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
      s.orders:insert('#', o)
      log('kill squad ' .. s.id .. ' -> ' .. table.concat(plan.targets, ','))
    end
    plan.applied = true
    out(plan)
  elseif cmd == 'create' then
    local name, uid = pos[1], tonumber(pos[2])
    local u = uid and df.unit.find(uid)
    if not name or not u or not dfhack.units.isCitizen(u) or u.hist_figure_id < 0 or u.military.squad_id ~= -1 then
      out({ error = 'usage: create <name> <leader_unit_id> (Buerger ohne Trupp, mit Geschichtsfigur)' }) return end
    local ent = df.historical_entity.find(df.global.plotinfo.group_id)
    local own_idx, cap
    for i = 0, #ent.positions.own - 1 do if ent.positions.own[i].code == 'MILITIA_CAPTAIN' then own_idx, cap = i, ent.positions.own[i] end end
    local plan = { create = name, leader = uid, dry = dry, position_idx = own_idx }
    -- BUG-425: squads cannot be deleted -> point at empty squads that can be reused (rename + add)
    local empty = {}
    for _, sq0 in ipairs(squads()) do
      local okc, inf = pcall(squad_info, sq0, false)
      if okc and inf.members == 0 then empty[#empty + 1] = { id = sq0.id, name = inf.name } end
    end
    if #empty > 0 then plan.reuse_hint = { empty_squads = empty, hinweis = 'leere Trupps wiederverwenden: mil rename <squad> <name> --apply, dann mil add' } end
    if not cap then plan.ok, plan.error = false, 'keine Position MILITIA_CAPTAIN in der Festungs-Entitaet' out(plan) return end
    if dry then out(plan) return end
    local asg = df.entity_position_assignment:new()
    asg.id = ent.positions.next_assignment_id
    asg.histfig, asg.histfig2, asg.position_vector_idx = -1, -1, -1
    asg.position_id = cap.id
    asg.squad_id, asg.st_id, asg.ab_id, asg.vassal_of_entity_id, asg.vassal_of_position_profile_id, asg.assigned_army_controller_id = -1, -1, -1, -1, -1, -1
    asg.temp = 0
    ent.positions.next_assignment_id = asg.id + 1
    ent.positions.assignments:insert('#', asg)
    local ai = #ent.positions.assignments - 1
    local okm, sq = pcall(dfhack.military.makeSquad, asg.id)
    if not okm or not sq then
      ent.positions.assignments:erase(ai) ent.positions.next_assignment_id = asg.id
      out({ error = 'makeSquad fehlgeschlagen (zurueckgerollt)', detail = tostring(sq) }) return
    end
    -- BUG-425: the squad exists from here on; report its id even if a later step fails (before: the outer pcall printed only 'error')
    plan.squad, plan.squad_id, plan.assignment = sq.id, sq.id, asg.id
    log('create squad ' .. sq.id .. ' ' .. name .. ' leader ' .. uid)
    local okl, errl = pcall(function()
      sq.alias = name
      sq.name.nickname = name
      local hf = df.historical_figure.find(u.hist_figure_id)
      asg.histfig, asg.histfig2, asg.position_vector_idx = hf.id, hf.id, own_idx
      hf.entity_links:insert('#', { new = df.histfig_entity_link_positionst, entity_id = ent.id, entity_vector_idx = ent.id,
        link_strength = 100, assignment_id = asg.id, assignment_vector_idx = ai, start_year = df.global.cur_year })
      hf.entity_links:insert('#', { new = df.histfig_entity_link_squadst, entity_id = ent.id, entity_vector_idx = -1,
        link_strength = 100, squad_id = sq.id, squad_position = 0, start_year = df.global.cur_year })
      sq.positions[0].occupant = hf.id
      u.military.squad_id, u.military.squad_position = sq.id, 0
      for rk, v in pairs(cap.responsibilities) do
        if v then
          local vec, found = ent.assignments_by_type[rk], false
          for i = 0, #vec - 1 do if vec[i].id == asg.id then found = true end end
          if not found then vec:insert('#', asg) end
        end
      end
    end)
    plan.ok = okl
    if not okl then
      plan.warning = 'Trupp angelegt, Anfuehrer-Zuweisung unvollstaendig: ' .. tostring(errl) .. ' (Trupp wiederverwenden: mil add ' .. sq.id .. ' <unit> --apply)'
      log('create squad ' .. sq.id .. ' leader FEHLER ' .. tostring(errl))
    end
    local oki, inf = pcall(squad_info, sq, false)   -- status query afterwards
    if oki then plan.status = { members = inf.members, of = inf.of, name = inf.name } end
    out(plan)

  elseif cmd == 'add' or cmd == 'remove' then
    local s = find_squad(tonumber(pos[1]))
    local uid = tonumber(pos[2])
    local u = uid and df.unit.find(uid)
    if not s or not u then out({ error = 'usage: ' .. cmd .. ' <squad_id> <unit_id> [--apply]' }) return end
    local plan = { cmd = cmd, squad = s.id, unit = uid, name = nm(u), dry = dry }
    local function fail(reason) plan.ok, plan.reason = false, reason out(plan) end
    if cmd == 'add' then
      -- BUG-425: every refusal carries a reason; explicit slot instead of -1 (-1 landed on an empty/orphaned leader slot and failed silently)
      if not dfhack.units.isCitizen(u) or dfhack.units.isChild(u) then plan.error = 'kein erwachsener Buerger' return fail('not an adult citizen') end
      if dfhack.units.isDead(u) then return fail('unit is dead') end
      if u.hist_figure_id < 0 then return fail('unit has no historical figure') end
      if u.military.squad_id == s.id then return fail('unit already in this squad') end
      if u.military.squad_id ~= -1 then return fail('unit already in squad ' .. u.military.squad_id .. ' (mil remove first)') end
      local cand, orphan = {}, {}
      local function classify(i)
        local p = s.positions[i]
        if p.occupant == -1 then cand[#cand + 1] = i return end
        local m = member_unit(p)
        if not m or dfhack.units.isDead(m) then orphan[#orphan + 1] = i end   -- histfig gone / dead occupant
      end
      for i = 1, #s.positions - 1 do classify(i) end
      if #s.positions > 0 then classify(0) end   -- leader slot last
      plan.free_slots, plan.orphaned_slots = cand, (#orphan > 0) and orphan or nil
      if #cand == 0 then
        return fail('squad full' .. ((#orphan > 0) and (' (orphaned slots ' .. table.concat(orphan, ',') .. ': occupant without a living unit)') or ''))
      end
      plan.slot = cand[1]
      if dry then out(plan) return end
      local tried = {}
      for _, slot in ipairs(cand) do
        local okk, r = pcall(dfhack.military.addToSquad, uid, s.id, slot)
        if okk and r then plan.ok, plan.slot = true, slot break end
        tried[#tried + 1] = slot .. ':' .. (okk and tostring(r) or ('error ' .. tostring(r)))
      end
      if not plan.ok then
        plan.slot = nil
        log('add ' .. uid .. ' -> squad ' .. s.id .. ' FEHLER ' .. table.concat(tried, ' '))
        return fail('addToSquad refused every free slot (' .. table.concat(tried, ' ') .. ')')
      end
      plan.reason = nil
      -- Labors that collide with weapons/uniform (uniform-unstick hint)
      for _, lb in ipairs{ 'MINE', 'CUTWOOD', 'HUNT' } do u.status.labors[df.unit_labor[lb]] = false end
      log('add ' .. uid .. ' -> squad ' .. s.id .. ' slot ' .. plan.slot)
    else
      if u.military.squad_id ~= s.id then return fail('unit not in this squad') end
      if dry then out(plan) return end
      local okk, r = pcall(dfhack.military.removeFromSquad, uid)
      plan.ok = okk and r ~= false
      if not plan.ok then plan.reason = okk and 'removeFromSquad refused' or ('error ' .. tostring(r)) end
      log('remove ' .. uid .. ' <- squad ' .. s.id .. ' ok=' .. tostring(plan.ok))
    end
    out(plan)

  elseif cmd == 'rename' then
    local s = find_squad(tonumber(pos[1]))
    local name = pos[2]
    if not s or not name or name == '' then out({ error = 'usage: rename <squad_id> <name> [--apply]' }) return end
    local plan = { squad = s.id, from = dfhack.military.getSquadName(s.id), to = name, dry = dry }
    if dry then out(plan) return end
    s.alias = name
    plan.ok = true
    log('rename squad ' .. s.id .. ' -> ' .. name)
    out(plan)

  elseif cmd == 'uniform' then
    local s = find_squad(tonumber(pos[1]))
    local ti = tonumber(pos[2])
    local ent = df.historical_entity.find(df.global.plotinfo.group_id)
    local tpl = ti and ent.uniforms[ti]
    if not s or not tpl then out({ error = 'usage: uniform <squad_id> <template_idx 0..' .. (#ent.uniforms - 1) .. '> [weapon_subtype|-1] [--apply]' }) return end
    local wsub = tonumber(pos[3]) or 1
    local names = { [0] = 'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon' }
    local plan = { squad = s.id, template = tpl.name, weapon_subtype = wsub, dry = dry }
    if dry then out(plan) return end
    local n = 0
    for pi = 0, #s.positions - 1 do
      local p = s.positions[pi]
      for si = 0, 6 do
        local vec = p.equipment.uniform[names[si]]
        for k = #vec - 1, 0, -1 do local o = vec[k] vec:erase(k) pcall(function() o:delete() end) end
        local tinfo = tpl.uniform_item_info[si]
        for ei = 0, #tinfo - 1 do
          local e = tinfo[ei]
          local sp = df.squad_uniform_spec:new()
          sp.item = -1
          sp.item_type = tpl.uniform_item_types[si][ei]
          sp.item_subtype = tpl.uniform_item_subtypes[si][ei]
          sp.material_class, sp.mattype, sp.matindex, sp.color = e.material_class, e.mattype, e.matindex, -1
          for k2, v2 in pairs(e.indiv_choice) do if type(k2) == 'string' then sp.indiv_choice[k2] = v2 end end
          if names[si] == 'weapon' and wsub >= 0 then
            sp.item_subtype = wsub
            sp.indiv_choice.melee, sp.indiv_choice.any, sp.indiv_choice.ranged = false, false, false
          end
          vec:insert('#', sp) n = n + 1
        end
      end
      p.equipment.flags.replace_clothing = tpl.flags.replace_clothing
      p.equipment.flags.exact_matches = false
    end
    log('uniform squad ' .. s.id .. ' tpl ' .. ti .. ' weapon ' .. wsub .. ' specs ' .. n)
    for _, f in ipairs{ 'weapon', 'armor', 'shoes', 'shield', 'helm', 'gloves', 'pants' } do df.global.plotinfo.equipment.update[f] = true end
    plan.specs, plan.hinweis = n, 'update-Flags gesetzt (Zuweisung folgt in den naechsten Ticks)'
    out(plan)

  elseif cmd == 'workmode' then
    local s = find_squad(tonumber(pos[1]))
    local mode = pos[2]
    if not s or (mode ~= 'on' and mode ~= 'off') then out({ error = 'usage: workmode <squad_id> on|off [--apply]' }) return end
    local members = {}
    for i = 0, #s.positions - 1 do local u = member_unit(s.positions[i]) if u then members[#members + 1] = u.id end end
    local plan = { squad = s.id, mode = mode, members = members, dry = dry }
    if dry then out(plan) return end
    local ent = df.historical_entity.find(df.global.plotinfo.group_id)
    local function set_update()
      for _, f in ipairs{ 'weapon', 'armor', 'shoes', 'shield', 'helm', 'gloves', 'pants' } do df.global.plotinfo.equipment.update[f] = true end
    end
    if mode == 'on' then
      local PICK = 7 -- ITEM_WEAPON_PICK (index in itemdefs.weapons)
      local names = { [0] = 'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon' }
      local wtypes = { [df.item_type.WEAPON] = true, [df.item_type.ARMOR] = true, [df.item_type.SHOES] = true, [df.item_type.SHIELD] = true,
        [df.item_type.HELM] = true, [df.item_type.GLOVES] = true, [df.item_type.PANTS] = true }
      local removed = 0
      for pi = 0, #s.positions - 1 do
        local p = s.positions[pi]
        for si = 0, 6 do
          local vec = p.equipment.uniform[names[si]]
          for k = #vec - 1, 0, -1 do local o = vec[k] vec:erase(k) pcall(function() o:delete() end) end
        end
        local sp = df.squad_uniform_spec:new()
        sp.item, sp.item_type, sp.item_subtype = -1, df.item_type.WEAPON, PICK
        sp.material_class, sp.mattype, sp.matindex, sp.color = -1, -1, -1, -1
        sp.indiv_choice.melee, sp.indiv_choice.any, sp.indiv_choice.ranged = false, false, false
        p.equipment.uniform.weapon:insert('#', sp)
        -- delete outdated assignments (otherwise dwarves fetch/drop armor in circles: PickupEquipment loop)
        local v = p.equipment.assigned_items
        for k = #v - 1, 0, -1 do
          local it = df.item.find(v[k])
          if not it or wtypes[it:getType()] then v:erase(k) removed = removed + 1 end
        end
        p.equipment.flags.replace_clothing, p.equipment.flags.exact_matches = false, false
      end
      -- Routine 0: no orders, civilian clothes, sleep as before
      for m = 0, 11 do s.schedule.routine[0].month[m].uniform_mode = 0 s.schedule.routine[0].month[m].sleep_mode = 0 end
      s.cur_routine_idx = 0
      for _, uid in ipairs(members) do
        local u = df.unit.find(uid)
        if u then
          u.status.labors[df.unit_labor.MINE] = true
          pcall(dfhack.run_command, 'claude/workdetail', 'assign', tostring(uid), 'Miners', 'true')
        end
      end
      set_update()
      plan.removed_assignments = removed
    else
      pcall(dfhack.run_command, 'claude/mil', 'uniform', tostring(s.id), '1', '1', '--apply')
      s.cur_routine_idx = 2
      for _, uid in ipairs(members) do
        local u = df.unit.find(uid)
        if u then u.status.labors[df.unit_labor.MINE] = false end
        pcall(dfhack.run_command, 'claude/workdetail', 'assign', tostring(uid), 'Miners', 'false')
      end
      set_update()
    end
    log('workmode squad ' .. s.id .. ' ' .. mode)
    plan.applied = true
    out(plan)

  elseif cmd == 'tabelle' then
    -- Report: squad | member | weapon | armor pieces/9 (breastplate, helm, greaves, 2 gloves, 2 boots, shield, weapon) | training | skill
    -- Options: --say (short sentence via claude/schau say), --file (writes tools/out/mil-tabelle.txt)
    local SKN = { 'AXE', 'SWORD', 'MACE', 'HAMMER', 'SPEAR', 'DAGGER', 'MELEE_COMBAT', 'WRESTLING', 'SHIELD', 'ARMOR', 'DODGING' }
    local function skills(u)
      local parts = {}
      if u.status.current_soul then
        for _, sk in ipairs(u.status.current_soul.skills) do
          local n = df.job_skill[sk.id]
          for _, w in ipairs(SKN) do
            if n == w and sk.rating > 0 then parts[#parts + 1] = n:sub(1, 3) .. sk.rating end
          end
        end
      end
      return table.concat(parts, ',')
    end
    local function metalmat(it) local mi = dfhack.matinfo.decode(it) return mi and mi.material and mi.material.flags.IS_METAL end
    local lines, sumeq, sumn, trainers = {}, 0, 0, 0
    lines[#lines + 1] = 'Trupp | Id | Name | Waffe | Teile/9 | Training | Skills'
    for _, s in ipairs(squads()) do
      local routine = s.cur_routine_idx
      for i = 0, #s.positions - 1 do
        local u = member_unit(s.positions[i])
        if u and not dfhack.units.isDead(u) then
          local t = { body = 0, head = 0, legs = 0, hands = 0, feet = 0, shield = 0, weapon = nil }
          for _, ii in ipairs(u.inventory) do
            local it = ii.item
            local ty = it:getType()
            if ty == df.item_type.WEAPON then
              local d = dfhack.items.getSubtypeDef(ty, it:getSubtype())
              t.weapon = (d and d.name or 'Waffe') .. (metalmat(it) and '' or '*')
            elseif ii.mode == df.inv_item_role_type.Worn or ty == df.item_type.SHIELD then
              if metalmat(it) then
                if ty == df.item_type.ARMOR then t.body = t.body + 1
                elseif ty == df.item_type.HELM then t.head = t.head + 1
                elseif ty == df.item_type.PANTS then t.legs = t.legs + 1
                elseif ty == df.item_type.GLOVES then t.hands = math.min(2, t.hands + 1)
                elseif ty == df.item_type.SHOES then t.feet = math.min(2, t.feet + 1)
                elseif ty == df.item_type.SHIELD then t.shield = t.shield + 1 end
              end
            end
          end
          local n = math.min(1, t.body) + math.min(1, t.head) + math.min(1, t.legs) + t.hands + t.feet + math.min(1, t.shield) + (t.weapon and 1 or 0)
          local job = u.job.current_job and df.job_type[u.job.current_job.job_type] or '-'
          local train = (routine == 2) and 'ja (Constant)' or (routine == 1 and 'gestaffelt' or (routine == 3 and 'Bereit' or 'nein'))
          if routine == 2 then trainers = trainers + 1 end
          local sk = skills(u)
          lines[#lines + 1] = string.format('%s | %d | %s | %s | %d/9 | %s (%s) | %s', dfhack.military.getSquadName(s.id), u.id, nm(u):sub(1, 22), t.weapon or '-', n, train, job, sk ~= '' and sk or '-')
          sumeq, sumn = sumeq + n, sumn + 1
        end
      end
    end
    lines[#lines + 1] = string.format('Summe: %d Soldaten, Ruestungsteile %d/%d, trainierend (Routine 2): %d', sumn, sumeq, sumn * 9, trainers)
    for _, l in ipairs(lines) do print(l) end
    if opt.file then
      local f = io.open(reqscript('claude/util').home() .. '/tools/out/mil-tabelle.txt', 'w')
      if f then f:write(os.date('%Y-%m-%d %H:%M:%S') .. string.char(10) .. table.concat(lines, string.char(10)) .. string.char(10)) f:close() end
    end
    if opt.say then
      local txt = string.format('Militaer: %d Soldaten, Ruestung %d/%d Teile, %d trainieren.', sumn, sumeq, sumn * 9, trainers)
      pcall(dfhack.run_command, 'claude/schau', 'say', txt, '3')
    end
    log('tabelle ' .. sumn .. ' Soldaten ' .. sumeq .. '/' .. sumn * 9)

  elseif cmd == 'barracks' then
    local s = find_squad(tonumber(pos[1]))
    local zid = tonumber(pos[2])
    local z = zid and df.building.find(zid)
    if not s or not z or not df.building_civzonest:is_instance(z) then out({ error = 'usage: barracks <squad_id> <zone_id (Barracks-Zone)>' }) return end
    local plan = { squad = s.id, zone = zid, type = df.civzone_type[z.type], dry = dry }
    if dry then out(plan) return end
    plan.ok = pcall(dfhack.military.updateRoomAssignments, s.id, zid, { train = true })
    log('barracks squad ' .. s.id .. ' zone ' .. zid)
    out(plan)

  elseif cmd == 'update' then
    if dry then out({ dry = true, would = 'Ausruestungs-Zuweisung anstossen (update.*); mit --apply ausfuehren' }) return end
    for _, f in ipairs{ 'weapon', 'armor', 'shoes', 'shield', 'helm', 'gloves', 'pants' } do df.global.plotinfo.equipment.update[f] = true end
    log('update equipment')
    out({ ok = true, hinweis = 'Ausruestungs-Zuweisung angestossen (wie UI Update equipment); Ergebnis nach einigen Ticks mit `equip`' })

  elseif cmd == 'pickfix' then
    -- E18 solution run 5 (01.10.2026): release squad pick reservations + remove pick uniform specs + update.weapon;
    -- the engine then distributes free picks as work picks to all dwarves with the MINE labor. Details lua/claude/pickfix.lua.
    -- Options: --apply, --ensure id,id (labor MINE + Miners). Use instead of `workmode on` (workmode blocks free picks).
    local pa = {}
    for _, a in ipairs(args) do pa[#pa + 1] = a end
    local okp, errp = pcall(dfhack.run_command, 'claude/pickfix', table.unpack(pa))
    if not okp then out({ error = tostring(errp) }) end

  elseif cmd == 'ammo' then
    -- ammunition of a squad (= UI squad equipment -> ammunition): ONE spec 'amount x AMMO subtype', combat + training;
    -- replaces the squad's existing ammo specs, then triggers the ammo/quiver update (ported from the live copy, BUG-420)
    local s = find_squad(tonumber(pos[1]))
    if not s then out({ error = 'usage: ammo <squad_id> [amount] [subtype] [--apply]' }) return end
    local amount, sub = tonumber(pos[2]) or 25, tonumber(pos[3]) or 0
    if amount < 1 or sub < 0 then out({ error = 'usage: ammo <squad_id> [amount >= 1] [subtype >= 0] [--apply]' }) return end
    local plan = { squad = s.id, amount = amount, subtype = sub, vorhanden = #s.ammo.ammunition, dry = dry }
    if dry then out(plan) return end
    for i = #s.ammo.ammunition - 1, 0, -1 do
      local o = s.ammo.ammunition[i]
      s.ammo.ammunition:erase(i)
      pcall(function() o:delete() end)
    end
    local sp = df.squad_ammo_spec:new()
    sp.item_type, sp.item_subtype = df.item_type.AMMO, sub
    sp.material_class, sp.mattype, sp.matindex = -1, -1, -1
    sp.amount = amount
    sp.flags.use_combat, sp.flags.use_training = true, true
    s.ammo.ammunition:insert('#', sp)
    s.ammo.update.ammo = true
    df.global.plotinfo.equipment.update.ammo, df.global.plotinfo.equipment.update.quiver = true, true
    log('ammo squad ' .. s.id .. ' ' .. amount .. 'x subtype ' .. sub)
    plan.applied = true
    out(plan)

  elseif cmd == 'guard' then
    local sub = pos[1] or 'status'
    local G = rawget(_G, 'CLAUDE_MILGUARD')
    if not G then G = { active = false, hits = 0, checks = 0 } rawset(_G, 'CLAUDE_MILGUARD', G) end
    local repeatUtil = require('repeat-util')
    if sub == 'start' then
      G.active, G.since = true, os.date('%H:%M:%S')
      -- 60 CALENDAR ticks (also with timestream; claude/tempo.schedule), fallback 'ticks'
      local okT, T = pcall(reqscript, 'claude/tempo')
      if okT and T and T.schedule then T.schedule(GUARD_KEY, 60, guard_tick) else repeatUtil.scheduleEvery(GUARD_KEY, 60, 'ticks', guard_tick) end
      log('guard start')
    elseif sub == 'stop' then
      G.active = false
      repeatUtil.cancel(GUARD_KEY)
      log('guard stop')
    end
    local W = rawget(_G, 'CLAUDE_KILLWATCH')
    out({ guard = G.active, since = G.since, checks = G.checks, hits = G.hits, last_hit = G.last_hit, last_targets = G.last_targets,
          killwatch_active = (W and W.active) or false })

  elseif cmd == 'refuge' then
    local Z = cfg.ZUFLUCHT
    local rects = Z and Z.rects or {}
    if pos[1] == 'check' then
      -- BUG-423 (read only): is the refuge supplied? drink/water and food inside the burrow
      local G = reqscript('claude/gefahr')
      local sup = G.refuge_supply(nil, true)
      local al = df.global.plotinfo.alerts
      out({ refuge = sup, lines = G.refuge_lines(sup), civ_burrows = (#al.list > 1) and #al.list[1].burrows or 0,
            civ_alert_idx = al.civ_alert_idx, require_water = cfg.REFUGE_REQUIRE_WATER ~= false,
            hint = 'BFS inside the burrow + repair: python -m df_llm_helper refuge check|repair' })
      return
    end
    if dry then
      out({ dry = true, rects = #rects, would = 'Zuflucht-Burrow + Zivilwarnung anlegen/pruefen; mit --apply ausfuehren' })
      return
    end
    local utils = require('utils')
    local burrows, alerts = df.global.plotinfo.burrows, df.global.plotinfo.alerts
    local b = dfhack.burrows.findByName('Zuflucht', true)
    if not b then
      b = df.burrow:new() b.id = burrows.next_id burrows.next_id = b.id + 1 b.name = 'Zuflucht'
      b.symbol_index, b.texture_r, b.texture_g, b.texture_b, b.texture_br, b.texture_bg, b.texture_bb = 5, 60, 160, 255, 195, 95, 0
      burrows.list:insert('#', b)
    end
    -- Run 4: tiles from config.ZUFLUCHT (placeholder at the wagon until bau fixes an underground refuge); old tiles (run 3: z141) are removed first
    -- without configured rects keep the existing tiles (clearing would wipe the refuge of the civilian alert, BUG-407)
    if #rects > 0 then pcall(dfhack.burrows.clearTiles, b) end
    for _, r in ipairs(rects) do
      for y = r[2], r[4] do for x = r[1], r[3] do for z = r[5], (r[6] or r[5]) do dfhack.burrows.setAssignedTile(b, xyz2pos(x, y, z), true) end end end
    end
    while #alerts.list < 2 do
      local it = df.alert_statest:new() it.id = alerts.next_id alerts.next_id = it.id + 1 it.name = 'civ-alert' alerts.list:insert('#', it)
    end
    utils.insert_sorted(alerts.list[1].burrows, b.id)
    log('refuge burrow ' .. b.id)
    local res = { burrow = b.id, blocks = #dfhack.burrows.listBlocks(b), alerts = #alerts.list, civ_burrows = #alerts.list[1].burrows, civ_alert_idx = alerts.civ_alert_idx }
    local oks, sup = pcall(function() return reqscript('claude/gefahr').refuge_supply(b, true) end)
    if oks and sup then res.supply_ok, res.problems = sup.ok, sup.problems end   -- BUG-423: report an unsupplied refuge right away
    out(res)

  else
    out({ error = 'unbekannt: ' .. tostring(cmd), usage = 'status|report|equip|routines|enemies|plan|train|station|kill|release|create|add|remove|rename|uniform|workmode|pickfix|ammo|barracks|update|refuge|guard' })
  end
end)
if not ok then
  log('FEHLER ' .. tostring(err))
  out({ error = tostring(err) })
end
