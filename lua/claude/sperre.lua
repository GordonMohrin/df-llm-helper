--@ module = true
-- claude/sperre (module) - shaft door (net tunnel z138) + shaft head barrier (run 3, scope verteidigung, 30.09.2026)
-- The player: "both caverns: at least one door that you can then close so that no more monsters come up from the underground."
-- Operated via `claude/schacht` (status | bauen | open | seal | notzu | tuer | cancel). Coordinates + rationale: config.lua KAV_BARRIEREN.
--
-- LAYOUT: caverns 1 and 2 are reachable ONLY via shaft D. Column (136,169) z92..144. Two ways into the fort: (a) head (136,168,144) = wall, stays CLOSED ALWAYS;
-- (b) net tunnel z138: net (137,166) - DOOR (137,167) - WALL (137,168) - WALL (137,169) - column. Two stages: plug walls (beasts do not break constructions)
-- + door (locked = door_flags.forbidden; troglodytes only open unlocked ones). Operation entirely from the FORT side: the connection to the cave is never opened for
-- construction work (lesson 20:33: FB 561 climbed through the opened head into corridor D in 60 s).
-- Target states: 'zu' (closed: both plug walls stand, door stands + locked), 'offen' (open: door unlocked, plugs deconstructed).
-- Open: unlock door -> deconstruct plug walls (outer first). Close: build plug walls (only if nobody is behind the barrier) -> lock door.
-- Initial build ('bauen'): the OUTER old wall (137,167) is converted into the door BEHIND the two other walls (deconstruct + place door), there is never a hole.
local util = reqscript('claude/util')
local repeatUtil = require('repeat-util')
local function C() return reqscript('claude/config') end

local KEY = 'claude-schacht'
local TOOLS = reqscript('claude/util').home() .. '/tools/'
local LOG = TOOLS .. 'out/schacht.log'
local BP_WALL, BP_DOOR = 'claude/r3_wall1.csv', 'claude/r3_door1.csv'
local DD = df.tile_dig_designation

local ST = rawget(_G, 'CLAUDE_SCHACHT')
if not ST then ST = {} rawset(_G, 'CLAUDE_SCHACHT', ST) end
ST.tries = ST.tries or {}
ST.shown = ST.shown or {}

local PLANS = {
  bauen = { { k1 = 'zu' } },                                        -- Initial build: outer wall -> door, lock
  seal = { { k1 = 'zu' }, { kopf = 'zu', k1 = 'zu' } },             -- close everything (head stays wall)
  open1 = { { k1 = 'offen' } },                                     -- make caverns 1+2 reachable (from the net)
  openkopf = { { kopf = 'offen' } },                                -- NOT recommended (lesson 20:33)
  notzu = { { k1 = 'zu' } },                                        -- Emergency: without lock-in protection (ST.force)
}

local function log(s)
  local f = io.open(LOG, 'a')
  if f then f:write(os.date('%H:%M:%S ') .. s .. '\n') f:close() end
end
local function say(t) pcall(dfhack.run_command, 'claude/schau', 'say', t, '4') end
local function show(t, text)
  pcall(dfhack.run_command, 'claude/schau', 'show', tostring(t[1]), tostring(t[2]), tostring(t[3]), text)
end
local function clean(s) return (tostring(s):gsub('%c', ' '):sub(1, 160)) end
local function key(t) return t[1] .. ',' .. t[2] .. ',' .. t[3] end

-- ---------------------------------------------------------------- Tile info
function tile_info(t)
  local x, y, z = t[1], t[2], t[3]
  local blk = dfhack.maps.getTileBlock(x, y, z)
  local tt = blk and blk.tiletype[x % 16][y % 16]
  local attrs = tt and df.tiletype.attrs[tt]
  local bld = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
  local btype = bld and df.building_type[bld:getType()] or nil
  local complete = false
  if bld then
    local ok, v = pcall(function() return bld:getBuildStage() >= bld:getMaxBuildStage() end)
    complete = ok and v or false
  end
  return {
    tiletype = tt and df.tiletype[tt] or '?',
    shape = attrs and df.tiletype_shape[attrs.shape] or '?',
    material = attrs and df.tiletype_material[attrs.material] or '?',
    building = btype and (btype .. ' ' .. bld.id) or nil,
    btype = btype, complete = complete,
    bld = bld,
    dig = blk and df.tile_dig_designation[blk.designation[x % 16][y % 16].dig] or '?',
    blk = blk,
  }
end
local function is_cwall(i) return i.shape == 'WALL' and i.material == 'CONSTRUCTION' end
local function is_free_floor(i) return (i.shape == 'FLOOR') and not i.building end
local function is_door(i) return i.btype == 'Door' end

local function destroy_building(b, complete)
  if not complete then pcall(dfhack.buildings.deconstruct, b) return end   -- planned/unfinished building: remove immediately
  if dfhack.buildings.markedForRemoval(b) then return end
  local job = df.job:new()
  job.job_type = df.job_type.DestroyBuilding
  job.pos = { x = b.centerx, y = b.centery, z = b.z }
  local ref = df.general_ref_building_holderst:new()
  ref.building_id = b.id
  job.general_refs:insert('#', ref)
  b.jobs:insert('#', job)
  dfhack.job.linkIntoWorld(job, true)
end

local function place(bp, t)
  local out = dfhack.run_command_silent('quickfort', 'run', bp, '-c', t[1] .. ',' .. t[2] .. ',' .. t[3])
  log('quickfort ' .. bp .. ' ' .. key(t) .. ' -> ' .. clean(out))
end
local function place_throttled(bp, t)
  local k = bp .. key(t)
  if os.time() - (ST.tries[k] or 0) > 120 then
    ST.tries[k] = os.time()
    place(bp, t)
    return true
  end
  return false
end
-- Mark construction for deconstruction (dig designation Default on a construction = 'Remove Construction')
local function mark_remove(i, t)
  if i.dig == 'No' and i.blk then
    i.blk.designation[t[1] % 16][t[2] % 16].dig = DD.Default
    i.blk.flags.designated = true
    log('Abbau markiert ' .. key(t))
    return true
  end
  return false
end
local function cancel_mark(i, t)
  if i.shape == 'WALL' and i.material == 'CONSTRUCTION' and i.dig == 'Default' then
    i.blk.designation[t[1] % 16][t[2] % 16].dig = DD.No
  end
end

-- ---------------------------------------------------------------- Reachability
local function walk(a, b)
  local ok, v = pcall(dfhack.maps.canWalkBetween, xyz2pos(a[1], a[2], a[3]), xyz2pos(b[1], b[2], b[3]))
  return ok and v or false
end
-- Shaft column -> fort (ueberwacher/UEBERWACHUNG B4b): must be false when the barrier is closed
function saeule_erreicht_fort()
  local from = { { 136, 169, 100 }, { 136, 169, 143 } }
  local to = { { 136, 160, 144 }, { 149, 150, 144 } }
  local r, any = {}, false
  for _, f in ipairs(from) do for _, t in ipairs(to) do
    local v = walk(f, t)
    if v then any = true end
    r[#r + 1] = string.format('(%d,%d,%d)->(%d,%d,%d)=%s', f[1], f[2], f[3], t[1], t[2], t[3], tostring(v))
  end end
  return any, r
end

-- ---------------------------------------------------------------- State
local TUNNEL = { { 137, 169, 138 }, { 137, 168, 138 }, { 137, 167, 138 } }   -- for kopf_state (head 'zu' also checks the tunnel barrier)
function kopf_state()
  local i = tile_info(C().KOPF)
  local s
  if is_cwall(i) then s = 'zu'
  elseif is_door(i) and i.complete then
    s = i.bld.door_flags.forbidden and 'tuer-verriegelt' or 'offen'
  elseif i.building then s = 'im-bau:' .. i.building
  else s = 'frei' end
  return { state = s, dig = i.dig, info = i }
end

function barrier_state(k)
  local B = C().KAV_BARRIEREN[k]
  local walls, free = 0, 0
  for _, p in ipairs(B.plugs) do
    local pi = tile_info(p)
    if is_cwall(pi) then walls = walls + 1 elseif is_free_floor(pi) then free = free + 1 end
  end
  local plug = (walls == #B.plugs) and 'wand' or ((free == #B.plugs) and 'frei' or ('teil ' .. walls .. '/' .. #B.plugs))
  local di = tile_info(B.door)
  local door, locked = 'fehlt', nil
  if is_door(di) then
    if di.complete then door, locked = 'tuer', di.bld.door_flags.forbidden and true or false else door = 'im-bau' end
  elseif is_cwall(di) then door = 'WAND(noch keine Tuer)'
  elseif di.building then door = 'belegt:' .. di.building end
  local r = { key = k, name = B.name, plug = plug, door = door, locked = locked }
  if plug == 'wand' and door == 'tuer' and locked then r.state = 'zu'
  elseif plug == 'wand' then r.state = 'zu-Wand (Tuer noch nicht verriegelt/gebaut)'
  elseif plug == 'frei' and door == 'tuer' and locked == false then r.state = 'offen'
  else r.state = 'unfertig' end
  r.sealed = (plug == 'wand')
  r.reach = walk(B.out, B.inn)   -- Shaft column <-> net tunnel possible on foot? (with 'zu' + head closed: false)
  return r
end

-- Citizen location (lock-in protection). u.pos.x < 0 = not on the map
local function citizens_where(pred)
  local res = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    local p = u.pos
    if p.x >= 0 and pred(p.x, p.y, p.z) then res[#res + 1] = u.id .. '@' .. p.x .. ',' .. p.y .. ',' .. p.z end
  end
  return res
end
-- behind the barrier: shaft column with tunnel pieces (x135..137, y168..171, z<=143; the net tile (137,167) and y<=167 belong to the fort) or everything in the caves (z<=117)
function citizens_beyond()
  return citizens_where(function(x, y, z)
    if z <= 117 then return true end
    return z <= 143 and x >= 135 and x <= 137 and y >= 168 and y <= 171
  end)
end

-- ---------------------------------------------------------------- Threats (cave side reachable)
-- Returns list { id, race, klasse, x,y,z, dist, reach } for intruders/major threats near the cave reference tile (cav) of a barrier.
function threats(k, range)
  local cfg = C()
  local B = cfg.KAV_BARRIEREN[k]
  local res = {}
  range = range or 80
  for _, u in ipairs(df.global.world.units.active) do
    local p = u.pos
    if p.x >= 0 and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then
      local d = math.max(math.abs(p.x - B.cav[1]), math.abs(p.y - B.cav[2]))
      if d <= range and math.abs(p.z - B.cav[3]) <= 30 then
        local okc, intr = pcall(cfg.is_intruder, u)
        if okc and intr then
          local kl = 'wild'
          pcall(function() kl = reqscript('claude/gefahr').klasse(u) or 'wild' end)
          local cr = df.creature_raw.find(u.race)
          res[#res + 1] = { id = u.id, race = cr and cr.creature_id or '?', klasse = kl, x = p.x, y = p.y, z = p.z, dist = d,
            reach = walk({ p.x, p.y, p.z }, B.out) }
        end
      end
    end
  end
  table.sort(res, function(a, b) return a.dist < b.dist end)
  return res
end

-- ---------------------------------------------------------------- Steps (one step moves part of the way to the goal)
-- Returns: done(bool), note
local function step_kopf(tg)
  local k = kopf_state()
  local i = k.info
  local KOPF = C().KOPF
  if tg == 'offen' then
    if is_door(i) and i.complete then
      if i.bld.door_flags.forbidden then i.bld.door_flags.forbidden = false end
      return true, 'offen'
    elseif is_cwall(i) then mark_remove(i, KOPF) return false, 'Kopfwand-Abbau'
    elseif i.building then return false, 'Tuer im Bau'
    elseif is_free_floor(i) then place_throttled(BP_DOOR, KOPF) return false, 'Kopftuer setzen' end
    return false, 'Kopf: unbekannt ' .. i.tiletype
  else -- zu (wall; a door/plan there is removed)
    if is_cwall(i) then cancel_mark(i, KOPF) return true, 'zu' end
    local beyond = ST.force and {} or citizens_beyond()
    if #beyond > 0 then return false, 'wartet: Buerger im Schacht/Hoehle: ' .. table.concat(beyond, ' ', 1, math.min(3, #beyond)) end
    if i.bld then destroy_building(i.bld, i.complete) return false, 'Kopftuer/Plan entfernen' end
    if is_free_floor(i) then place_throttled(BP_WALL, KOPF) return false, 'Kopfwand setzen' end
    return false, 'Kopf: ' .. i.tiletype
  end
end

local function step_k(k, tg)
  local cfg = C()
  local B = cfg.KAV_BARRIEREN[k]
  local s = barrier_state(k)
  local function done_now(s2)
    if tg == 'zu' then return s2.state == 'zu' end
    return s2.state == 'offen'
  end
  if done_now(s) then return true, s.state end
  local notes = {}
  if not ST.shown[k] then ST.shown[k] = true show(B.door, B.name .. ': Tuer + Wand-Sperre wird gebaut/bedient') end
  local di = tile_info(B.door)
  local plugs = {}
  for _, p in ipairs(B.plugs) do plugs[#plugs + 1] = tile_info(p) end
  local function all_plug_walls() for _, pi in ipairs(plugs) do if not is_cwall(pi) then return false end end return true end

  -- 1. Door: the outer old wall is converted into the door - only while the plug walls stand (no hole)
  if is_cwall(di) then
    if all_plug_walls() then mark_remove(di, B.door) notes[#notes + 1] = 'aeussere Wand -> Abbau (Stopfen stehen)'
    else notes[#notes + 1] = 'Wand-Stopfen unvollstaendig, Umbau wartet' end
  elseif not (is_door(di) and di.complete) then
    if di.building then notes[#notes + 1] = 'tuer im bau'
    elseif di.shape == 'FLOOR' then place_throttled(BP_DOOR, B.door) notes[#notes + 1] = 'tuer setzen'
    else notes[#notes + 1] = 'tuerkachel ' .. di.shape end
  end
  local door_ok = is_door(di) and di.complete

  if tg == 'zu' then
    -- 2. Plug walls (inner first): only without citizens behind the barrier
    for idx, pi in ipairs(plugs) do
      local p = B.plugs[idx]
      if is_cwall(pi) then cancel_mark(pi, p)
      elseif pi.building then notes[#notes + 1] = 'stopfen im bau ' .. key(p)
      elseif door_ok or is_cwall(di) == false then
        local out = ST.force and {} or citizens_beyond()
        if #out > 0 then notes[#notes + 1] = 'wartet: Buerger hinter der Sperre ' .. table.concat(out, ' ', 1, math.min(3, #out))
        elseif is_free_floor(pi) then place_throttled(BP_WALL, p) notes[#notes + 1] = 'stopfen setzen ' .. key(p) end
      end
    end
    -- 3. lock: only if both plugs stand
    if door_ok then
      local want = all_plug_walls()
      if di.bld.door_flags.forbidden ~= want then
        di.bld.door_flags.forbidden = want
        log(B.name .. ' Tuer ' .. (want and 'VERRIEGELT' or 'entriegelt'))
      end
    end
  else
    -- 'offen': door must stand (otherwise conversion above), unlock, then deconstruct plugs (outer (137,168) first, then inner)
    if door_ok then
      if di.bld.door_flags.forbidden then di.bld.door_flags.forbidden = false log(B.name .. ' Tuer entriegelt') end
      local outer_done = true
      for idx = #plugs, 1, -1 do   -- B.plugs = { inner, outer }: outer = last entry
        local pi, p = plugs[idx], B.plugs[idx]
        if is_cwall(pi) then
          if outer_done then mark_remove(pi, p) notes[#notes + 1] = 'stopfen-abbau ' .. key(p) end
          outer_done = false
        elseif pi.building then
          destroy_building(pi.bld, pi.complete) notes[#notes + 1] = 'stopfenplan entfernen ' .. key(p)
        end
      end
    end
  end
  local s2 = barrier_state(k)
  return done_now(s2), (#notes > 0 and table.concat(notes, ', ') or s2.state)
end

local function step(keyname, tg)
  if keyname == 'kopf' then return step_kopf(tg) end
  return step_k(keyname, tg)
end

-- ---------------------------------------------------------------- Plan loop (guard job 100 calendar ticks)
local function finish(ok)
  repeatUtil.cancel(KEY)
  local plan = ST.plan
  ST.plan, ST.phase, ST.force = nil, nil, nil
  ST.step = ok and ('Plan ' .. tostring(plan) .. ' FERTIG') or 'abgebrochen'
  log(ST.step)
  if ok then
    if plan == 'seal' or plan == 'bauen' or plan == 'notzu' then
      if plan ~= 'notzu' then os.remove(C().SCHACHT_OFFEN_FLAG) end
      say('Schacht-Tuer: zu (Wand + verriegelte Tuer), Plan ' .. plan .. ' fertig')
    else
      say('Schacht-Tuer offen (' .. plan .. ')')
    end
  end
end

function tick()
  if not util.fort_loaded() then return end
  local ok, err = pcall(function()
    if not ST.plan then repeatUtil.cancel(KEY) return end
    local plan = PLANS[ST.plan]
    local ph = plan and plan[ST.phase or 1]
    if not ph then finish(true) return end
    local all, notes = true, {}
    for _, kn in ipairs({ 'kopf', 'k1' }) do
      local tg = ph[kn]
      if tg then
        local d, note = step(kn, tg)
        if not d then all = false end
        notes[#notes + 1] = kn .. '=' .. tg .. ':' .. (d and 'ok' or tostring(note))
      end
    end
    ST.step = 'Phase ' .. (ST.phase or 1) .. '/' .. #plan .. ' ' .. table.concat(notes, ' | ')
    if all then
      log('Phase ' .. (ST.phase or 1) .. '/' .. #plan .. ' FERTIG')
      ST.phase = (ST.phase or 1) + 1
      if not plan[ST.phase] then finish(true) end
    end
  end)
  if not ok then log('FEHLER ' .. tostring(err)) end
end

function start(plan_name, opts)
  ST.plan, ST.phase, ST.since, ST.tries, ST.step = plan_name, 1, os.date('%H:%M:%S'), {}, 'start'
  ST.force = (opts and opts.force_guard) or (plan_name == 'notzu') or nil
  local okT, T = pcall(reqscript, 'claude/tempo')   -- 100 CALENDAR ticks (also with timestream)
  local fn = function() reqscript('claude/sperre').tick() end   -- always the current module version
  if okT and T and T.schedule then T.schedule(KEY, 100, fn) else repeatUtil.scheduleEvery(KEY, 100, 'ticks', fn) end
  log('Plan ' .. plan_name .. ' gestartet' .. (ST.force and ' (OHNE Einsperr-Schutz)' or ''))
  tick()
end

function cancel()
  repeatUtil.cancel(KEY)
  ST.plan, ST.phase, ST.step, ST.force = nil, nil, 'abgebrochen', nil
  local cfg = C()
  cancel_mark(tile_info(cfg.KOPF), cfg.KOPF)
  for _, k in ipairs(cfg.KAV_ORDER) do
    local B = cfg.KAV_BARRIEREN[k]
    cancel_mark(tile_info(B.door), B.door)
    for _, p in ipairs(B.plugs) do cancel_mark(tile_info(p), p) end
  end
  log('cancel')
end

function set_lock(target, lock)
  local cfg = C()
  local t = (target == 'kopf') and cfg.KOPF or (cfg.KAV_BARRIEREN[target] and cfg.KAV_BARRIEREN[target].door)
  if not t then return false, 'unbekannt: ' .. tostring(target) end
  local i = tile_info(t)
  if not (is_door(i) and i.complete) then return false, 'keine fertige Tuer bei ' .. key(t) end
  i.bld.door_flags.forbidden = lock
  log('Tuer ' .. target .. ' ' .. (lock and 'VERRIEGELT' or 'entriegelt') .. ' (manuell)')
  return true
end

-- Overall status (for claude/schacht status and ueberwacher)
function status()
  local cfg = C()
  local kp = kopf_state()
  local any, r = saeule_erreicht_fort()
  local res = { kopf = { state = kp.state, dig = kp.dig }, saeule_erreicht_fort = any, erreichbar = r,
    plan = ST.plan, phase = ST.phase, step = ST.step, since = ST.since, offen_markiert = cfg.schacht_offen() }
  res.barrieren = {}
  for _, k in ipairs(cfg.KAV_ORDER) do
    local s = barrier_state(k)
    s.bedrohung = {}
    for i, t in ipairs(threats(k, 70)) do
      if i <= 4 then s.bedrohung[#s.bedrohung + 1] = string.format('%s %s id%d (%d,%d,%d) d=%d erreichbar=%s', t.klasse, t.race, t.id, t.x, t.y, t.z, t.dist, tostring(t.reach)) end
    end
    res.barrieren[k] = s
  end
  res.buerger_hinter_sperre = citizens_beyond()
  return res
end
