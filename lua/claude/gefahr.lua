--@ module = true
-- claude/gefahr [status|selftest|sim <unit_id> <x> <y> <z>]   (Run 3, scope verteidigung/infra, 30.09.2026)
-- Threat classification + alarm events, independent of isInvader. Lesson: Forgotten Beast 'Irka Nohuslico Ratad' (FORGOTTEN_BEAST_5)
-- came at 16:57 via shaft D and killed 14 of 19 dwarves; isInvader=false, guard/watchdog did not see it (neither isDanger nor the wildlife rule),
-- and a stale alert.flag additionally blocked the guard.
--
-- CLASS A (major threat): caste flag FEATURE_BEAST (Forgotten Beast) / MEGABEAST / SEMIMEGABEAST / TITAN / DEMON / UNIQUE_DEMON / NIGHT_CREATURE*,
--   dfhack.units.isGreatDanger, or LARGE_PREDATOR with body size >= config.GEFAHR_GIANT_SIZE (giant predator).
-- CLASS B: invader / isDanger / agitated / insane (previous rule); inside, additionally non-harmless wildlife (config.is_intruder).
-- Never: citizens, pets, prisoners (cage/chain), merchants/diplomats, guests/residents (amphibian men).
--
-- ALARM (e.alarm) for a creature when
--   * it is INSIDE (config.INNEN_BOXEN: fort box z141..145 + shaft head/corridor D)                                         -> zone 'innen'  (A and B)
--   * CLASS A in shaft column D (z92..140) AND reachable on foot into the fort (canWalkBetween to FORT_REFS)                -> zone 'schacht'
--   * CLASS A or B (ground enemy) in the alarm zone: <= ALERT_RANGE to fort/citizen and |dz| <= ALERT_DZ                    -> zone 'nah'
--   * CLASS A otherwise within GEFAHR_RANGE_A/GEFAHR_DZ_A AND reachable (fliers: always reachable)                           -> zone 'erreichbar'
--   Unreachable cavern/underworld monsters (98 demons z1..4, cavern behind the barrier) trigger NOTHING.
-- SLOW MOTION (e.slow): alarm OR visible ground enemy within config.SLOWMO_RANGE (previous rule).
-- EVENT (handle): first alarm for a creature (class A, or inside/shaft) -> tools/alert.flag + tools/siege.flag (class A) + tools/pause.hold ('gefahr'),
--   pause, claude/alert on (refuge burrow is checked/renewed via claude/mil refuge if needed), in-game message. At most once per creature every
--   config.GEFAHR_COOLDOWN_S seconds. Test: `claude/gefahr selftest` (dry run, no flags/pause/alarm).
local util = reqscript('claude/util')
local function C() return reqscript('claude/config') end

local TOOLS = reqscript('claude/util').home() .. '/tools/'
local LOG = TOOLS .. 'out/gefahr.log'

local ST = rawget(_G, 'CLAUDE_GEFAHR') or { events = {}, scans = 0, hits = 0, last_scan_tick = 0 }
rawset(_G, 'CLAUDE_GEFAHR', ST)
ST.events = ST.events or {}

local FLAGS_A = { 'FEATURE_BEAST', 'MEGABEAST', 'SEMIMEGABEAST', 'TITAN', 'DEMON', 'UNIQUE_DEMON',
  'NIGHT_CREATURE', 'NIGHT_CREATURE_HUNTER', 'NIGHT_CREATURE_BOGEYMAN', 'NIGHT_CREATURE_NIGHTMARE', 'NIGHT_CREATURE_EXPERIMENTER' }

local function log(s)
  util.append_log(LOG, os.date('%H:%M:%S ') .. s)
end
local function write_file(path, text)
  local f = io.open(path, 'w')
  if f then f:write(text) f:close() return true end
  return false
end

-- ---------------------------------------------------------------- Classification (raw flags cached per race/caste)
local RC = {}
local function raw_info(u)
  local k = u.race .. ':' .. u.caste
  local e = RC[k]
  if e then return e end
  e = { flagA = nil, large = false, benign = false, flier = false, id = '?' }
  pcall(function()
    local r = df.creature_raw.find(u.race)
    if not r then return end
    e.id = r.creature_id
    local c = r.caste[u.caste]
    for _, f in ipairs(FLAGS_A) do
      local ok, v = pcall(function() return c.flags[f] end)
      if ok and v then e.flagA = f break end
    end
    e.large = c.flags.LARGE_PREDATOR and true or false
    e.benign = c.flags.BENIGN and true or false
    e.flier = c.flags.FLIER and true or false
  end)
  RC[k] = e
  return e
end

-- klasse(u) -> 'A'|'B'|nil, reason.   Checks ONLY the kind of unit (not dead/citizen/zone; eval_unit does that).
function klasse(u)
  local ri = raw_info(u)
  if ri.flagA then return 'A', ri.flagA end
  if dfhack.units.isGreatDanger(u) then return 'A', 'isGreatDanger' end
  if ri.large and (u.body.size_info.size_cur or 0) >= C().GEFAHR_GIANT_SIZE then return 'A', 'Riese' end
  if dfhack.units.isInvader(u) then return 'B', 'isInvader' end
  if dfhack.units.isDanger(u) then return 'B', 'isDanger' end
  if dfhack.units.isAgitated(u) then return 'B', 'isAgitated' end
  if dfhack.units.isCrazed(u) then return 'B', 'isCrazed' end
  return nil
end

local function excluded(u)
  return dfhack.units.isCitizen(u) or dfhack.units.isTame(u) or u.flags1.caged or u.flags1.chained or u.flags1.merchant
    or u.flags1.diplomat or u.flags2.resident or (u.flags2.visitor and not u.flags2.visitor_uninvited)   -- NOT isVisiting/isVisitor: they are true for Forgotten Beasts (visitor_uninvited)
end

local function inbox(b, x, y, z) return x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 end

-- on foot from position pos to a fort reference point? (fliers: always yes)
function reachable(pos, flier)
  if flier then return true end
  for _, r in ipairs(C().FORT_REFS) do
    local ok, v = pcall(dfhack.maps.canWalkBetween, pos, xyz2pos(r[1], r[2], r[3]))
    if ok and v then return true end
  end
  return false
end

-- Near a cavern reference tile (config.KAV_BARRIEREN[k].cav)? -> zone 'tuer-offen' (alarm if the creature reaches the fort on foot = barrier open)
local function near_kav(pos, cfg)
  for _, k in ipairs(cfg.KAV_ORDER or {}) do
    local o = cfg.KAV_BARRIEREN[k].cav
    if math.max(math.abs(pos.x - o[1]), math.abs(pos.y - o[2])) <= cfg.KAV_TUER_RANGE and math.abs(pos.z - o[3]) <= cfg.KAV_TUER_DZ then return k end
  end
  return nil
end

-- Evaluation of a unit. o = { pos = {x,y,z} (simulation), alive = true (simulation), hidden = bool }
local function eval_unit(u, cits, cfg, o)
  o = o or {}
  local pos = o.pos or u.pos
  if pos.x < 0 then return nil end
  if not o.alive and (not dfhack.units.isActive(u) or dfhack.units.isDead(u)) then return nil end
  if excluded(u) then return nil end
  local kl, grund = klasse(u)
  local innen = cfg.interior_name(pos.x, pos.y, pos.z)
  if not kl and innen and cfg.is_intruder(u) then kl, grund = 'B', 'Eindringling' end
  local kavk = (not innen) and near_kav(pos, cfg) or nil
  if not kl and kavk and cfg.is_intruder(u) then kl, grund = 'B', 'Eindringling-Tuer' end   -- troglodytes etc. near the cavern door
  if not kl then return nil end
  local ri = raw_info(u)
  local flier = ri.flier
  local legacy_ground = (kl == 'B') and not (flier and not dfhack.units.isGreatDanger(u))   -- fliers only for major threats (like is_ground_enemy)
  local dx, dy = math.abs(pos.x - cfg.FORT_X), math.abs(pos.y - cfg.FORT_Y)
  local cheb, dz = math.max(dx, dy), math.abs(pos.z - cfg.FORT_Z)
  local function nah()
    if cheb <= cfg.ALERT_RANGE and dz <= cfg.ALERT_DZ then return true end
    for _, c in ipairs(cits) do
      local p = c.pos
      if p.x >= 0 and math.abs(pos.x - p.x) <= cfg.ALERT_RANGE and math.abs(pos.y - p.y) <= cfg.ALERT_RANGE and math.abs(pos.z - p.z) <= cfg.ALERT_DZ then return true end
    end
    return false
  end
  local e = { id = u.id, name = util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 40), race = ri.id, klasse = kl, grund = grund,
    x = pos.x, y = pos.y, z = pos.z, dist = cheb, alarm = false, slow = false, zone = nil, reach = nil }
  local hidden = o.hidden
  if hidden == nil then hidden = util.is_hidden(pos.x, pos.y, pos.z) end
  e.hidden = hidden
  if innen then
    if grund == 'Eindringling' then
      -- harmless/normal wildlife inside: no alarm (civilian warning/pause would be overkill), but kill-order target (mil guard/killorder)
      e.zone = 'innen-wild'
    else
      e.alarm, e.zone = true, 'innen'
    end
  elseif kl == 'A' and cfg.SCHACHT_D_SAEULE and inbox(cfg.SCHACHT_D_SAEULE, pos.x, pos.y, pos.z) then
    e.reach = reachable(pos, flier)
    if e.reach then e.alarm, e.zone = true, 'schacht'
    else e.warn, e.zone = true, 'schacht-gesperrt' end   -- major threat in the shaft but barrier holds: warning (pause + slow motion) to check the walls, no civilian alarm
  elseif kavk and reachable(pos, flier) then
    -- Cavern door/shaft open: creature reaches the fort on foot AND is near a cavern door -> alarm (check barrier: claude/schacht status)
    e.reach, e.alarm, e.zone = true, true, 'tuer-offen'
  elseif kl == 'A' and nah() and reachable(pos, flier) then   -- Run 5: only if the creature can reach the citizen on foot/by air (cavern z95 vs. mine z105 = false alarm)
    e.reach, e.alarm, e.zone = true, true, 'nah'
  elseif kl == 'A' and cheb <= cfg.GEFAHR_RANGE_A and dz <= cfg.GEFAHR_DZ_A and pos.z >= (cfg.Z_MIN or 0) - 3 then  -- Run 5 (01.10.): cavern creatures deep below the fort (z < Z_MIN-3) trigger no warning/pause
    -- major threat farther away but reachable on foot: warning (event + slow motion), civilian warning only at 'nah'/'schacht'/'innen'
    e.reach = reachable(pos, flier)
    if e.reach then e.warn, e.zone = true, 'erreichbar' end
  elseif legacy_ground and nah() then
    e.alarm, e.zone = true, 'nah'
  end
  -- Slow motion: alarm/warning or visible ground enemy <= SLOWMO_RANGE (old rule; major threats also as fliers)
  if e.alarm or e.warn then e.slow = true
  elseif (legacy_ground or kl == 'A') and cheb <= cfg.SLOWMO_RANGE and dz <= cfg.SLOWMO_DZ and not hidden and (kl ~= 'A' or e.reach ~= false) then e.slow = true end
  return e
end

-- scan({ sim = { {id=,x=,y=,z=} } }) -> { list, alarm, alarm_A, slow, slow_list }. Only creatures with a class (otherwise nil) enter the list.
function scan(opts)
  opts = opts or {}
  local cfg = C()
  local cits = dfhack.units.getCitizens()
  local S = { list = {}, alarm = 0, alarm_A = 0, slow = 0, slow_list = {}, sim = opts.sim and true or false }
  local function add(e)
    S.list[#S.list + 1] = e
    if e.alarm then
      S.alarm = S.alarm + 1
      if e.klasse == 'A' then S.alarm_A = S.alarm_A + 1 end
    end
    if e.warn then S.warn = (S.warn or 0) + 1 end
    if e.slow then
      S.slow = S.slow + 1
      if #S.slow_list < 8 then S.slow_list[#S.slow_list + 1] = string.format('%d %s %s (%d,%d,%d) d=%d', e.id, e.klasse, e.name:sub(1, 26), e.x, e.y, e.z, e.dist) end
    end
  end
  local simids = {}
  for _, s in ipairs(opts.sim or {}) do simids[s.id] = s end
  for _, u in ipairs(df.global.world.units.active) do
    if not simids[u.id] then
      local ok, e = pcall(eval_unit, u, cits, cfg)
      if ok and e then add(e) end
    end
  end
  for id, s in pairs(simids) do
    local u = df.unit.find(id)
    if u then
      local ok, e = pcall(eval_unit, u, cits, cfg, { pos = { x = s.x, y = s.y, z = s.z }, alive = true, hidden = false })
      if ok and e then e.sim = true add(e) elseif not ok then S.error = tostring(e) end
    end
  end
  table.sort(S.list, function(a, b) if a.alarm ~= b.alarm then return a.alarm end return a.dist < b.dist end)
  ST.scans, ST.last_scan_tick = ST.scans + 1, df.global.cur_year * 403200 + df.global.cur_year_tick
  return S
end

-- ---------------------------------------------------------------- Check refuge (burrow + alarm 1) and path conflict
function refuge_check(S, fix)
  local al = df.global.plotinfo.alerts
  local b = dfhack.burrows.findByName('Zuflucht', true)
  local Z = C().ZUFLUCHT or {}
  local r = { burrow = b and b.id or nil, alerts = #al.list, civ_burrows = (#al.list > 1) and #al.list[1].burrows or 0, ok = false, konflikt = {} }
  if b and Z.probe then r.tile_probe = dfhack.burrows.isAssignedTile(b, xyz2pos(Z.probe[1], Z.probe[2], Z.probe[3])) end
  r.ok = (r.burrow ~= nil) and r.civ_burrows > 0 and (Z.probe == nil or r.tile_probe == true)
  if not r.ok and fix then
    local okr, err = pcall(dfhack.run_command, 'claude/mil', 'refuge', '--apply')
    r.repariert = okr
    r.ok = #al.list > 1 and #al.list[1].burrows > 0
  end
  -- Path conflict: intruder near the refuge stairs (config.ZUFLUCHT.treppe, optional)
  local T = Z.treppe
  for _, e in ipairs((T and S and S.list) or {}) do
    if e.alarm and math.abs(e.x - T[1]) <= 8 and math.abs(e.y - T[2]) <= 8 then
      r.konflikt[#r.konflikt + 1] = string.format('%s id %d bei (%d,%d,%d) nahe Zufluchtstreppe (%d,%d)', e.klasse, e.id, e.x, e.y, e.z, T[1], T[2])
    end
  end
  return r
end

-- ---------------------------------------------------------------- Event (pause + flags + alarm + message)
-- opts.dry: write nothing (dry run); opts.force: ignore cooldown. Returns: { new = {...}, actions = {...}, text = '...' }
function handle(S, opts)
  opts = opts or {}
  local cfg = C()
  local res = { new = {}, actions = {} }
  local now = os.time()
  for _, e in ipairs(S.list) do
    if (e.alarm or e.warn) and (e.klasse == 'A' or e.zone == 'innen' or e.zone == 'schacht' or e.zone == 'tuer-offen') then
      local last = ST.events[e.id]
      local cool = e.warn and cfg.GEFAHR_COOLDOWN_WARN_S or cfg.GEFAHR_COOLDOWN_S
      if opts.force or not last or (now - last) > cool then
        res.new[#res.new + 1] = e
        if not opts.dry and not opts.test then ST.events[e.id] = now end
      end
    end
  end
  if #res.new == 0 then return res end
  local anyA, ids = false, {}
  local lines = { os.date('%H:%M:%S') .. ' GEFAHR-ALARM (gefahr.lua) ' .. util.game_date().text .. (opts.dry and ' [TROCKENLAUF]' or '') }
  for _, e in ipairs(res.new) do
    if e.klasse == 'A' then anyA = true end
    ids[#ids + 1] = e.id
    lines[#lines + 1] = string.format('%s/%s %s id %d %s bei (%d,%d,%d) zone=%s dist=%d erreichbar=%s%s', e.klasse, e.grund, e.race, e.id, e.name, e.x, e.y, e.z, e.zone or '-', e.dist, tostring(e.reach), e.warn and ' (nur Warnung)' or '')
  end
  local ref = refuge_check(S, not opts.dry and not opts.test)
  lines[#lines + 1] = string.format('Zuflucht: burrow=%s civ_alert_burrows=%d ok=%s%s', tostring(ref.burrow), ref.civ_burrows, tostring(ref.ok), #ref.konflikt > 0 and (' KONFLIKT: ' .. table.concat(ref.konflikt, '; ')) or '')
  local text = table.concat(lines, '\n')
  res.text, res.refuge = text, ref
  local short = string.format('GEFAHR: %s %s (%d,%d,%d) %s', res.new[1].klasse, res.new[1].name:sub(1, 22), res.new[1].x, res.new[1].y, res.new[1].z, res.new[1].zone or '')
  if opts.dry then
    res.actions = { 'alert.flag', anyA and 'siege.flag' or nil, 'pause.hold', 'pause_state=true', S.alarm > 0 and 'civ_alert on' or 'civ_alert bleibt (nur Warnung)', 'schau say: ' .. short }
    return res
  end
  ST.hits = ST.hits + 1
  local dir = opts.test and (TOOLS .. "out/test/") or TOOLS   -- test: only files in tools/out/test/, no pause, no alarm, no message
  write_file(dir .. 'alert.flag', text .. '\n')
  res.actions[#res.actions + 1] = 'alert.flag'
  if anyA or S.alarm >= cfg.SIEGE_MIN then
    write_file(dir .. 'siege.flag', text .. '\n')
    res.actions[#res.actions + 1] = 'siege.flag'
  end
  write_file(dir .. 'pause.hold', 'gefahr ' .. os.date('%H:%M:%S'))
  res.actions[#res.actions + 1] = 'pause.hold'
  if not opts.test then
    df.global.pause_state = true
    res.actions[#res.actions + 1] = 'pause'
    local al = df.global.plotinfo.alerts
    if S.alarm > 0 and al.civ_alert_idx == 0 and #al.list > 1 and #al.list[1].burrows > 0 then
      al.civ_alert_idx = 1
      res.actions[#res.actions + 1] = 'civ_alert on'
    end
    pcall(function() reqscript('claude/schau').say(short, 5) end)
  end
  log((text:gsub('\n', ' | ')))
  return res
end

-- ---------------------------------------------------------------- Self-test for the supervisor (alarm system alive? shaft barrier sealed?)
-- Returns: list of problem texts (empty = all good)
function selbsttest()
  local p = {}
  local now_tick = df.global.cur_year * 403200 + df.global.cur_year_tick
  if (now_tick - (ST.last_scan_tick or 0)) > 600 then
    p[#p + 1] = 'ALARMSYSTEM: gefahr-Scan seit ' .. (now_tick - (ST.last_scan_tick or 0)) .. ' Ticks nicht gelaufen (claude/watchdog stop + start, claude/mil guard start)'
  end
  local sp = C().SCHACHT_PRUEF   -- Run 4: nil (no shaft) -> no test
  local ok, v = false, false
  if sp then ok, v = pcall(dfhack.maps.canWalkBetween, xyz2pos(sp.von[1], sp.von[2], sp.von[3]), xyz2pos(sp.nach[1], sp.nach[2], sp.nach[3])) end
  if ok and v and not C().schacht_offen() then
    p[#p + 1] = 'SCHACHT D OFFEN: Kaverne ist zu Fuss mit dem Fort verbunden, aber config.SCHACHT_D_OFFEN=false (Sperre kaputt? claude/schacht status, claude/schacht seal)'
  end
  -- Cavern doors (claude/sperre): state 'zu' (closed) must really be sealed (cave -> shaft not walkable)
  local okS, S = pcall(reqscript, 'claude/sperre')
  if okS and S then
    for _, k in ipairs(C().KAV_ORDER or {}) do
      local okb, b = pcall(S.barrier_state, k)
      if okb and b and b.sealed and b.reach then p[#p + 1] = 'SCHACHT-TUER ' .. k .. ': Stopfen-Waende stehen, aber Schachtsaeule<->Netz-Tunnel begehbar (Kopf offen oder Tunnelwand kaputt? claude/schacht status)' end
    end
  end
  local al = df.global.plotinfo.alerts
  if not (#al.list > 1 and #al.list[1].burrows > 0) then p[#p + 1] = 'ZUFLUCHT/ZIVILWARNUNG fehlt (claude/mil refuge --apply)' end
  return p
end

-- ---------------------------------------------------------------- Command
if dfhack_flags and dfhack_flags.module then return end

local a = { ... }
local cmd = a[1] or 'status'
local cfg = C()

local function brief(e)
  return string.format('%s/%s %s id%d (%d,%d,%d) zone=%s d=%d reach=%s alarm=%s warn=%s slow=%s%s', e.klasse, e.grund, e.race, e.id, e.x, e.y, e.z, e.zone or '-', e.dist, tostring(e.reach), tostring(e.alarm), tostring(e.warn or false), tostring(e.slow), e.sim and ' [SIM]' or '')
end

if cmd == 'status' then
  -- self-test BEFORE the scan: the scan itself sets last_scan_tick, so the 'alarm system alive?' check could never fail (BUG-412)
  local st = selbsttest()
  local S = scan()
  local rows = {}
  for i, e in ipairs(S.list) do if i <= 12 then rows[#rows + 1] = brief(e) end end
  util.emit({ alarm = S.alarm, alarm_A = S.alarm_A, warn = S.warn or 0, slow = S.slow, selbsttest = st, gelistet = #S.list, top = rows, scans = ST.scans, hits = ST.hits, refuge = refuge_check(S, false),
    civ_alert_idx = df.global.plotinfo.alerts.civ_alert_idx, fps = df.global.enabler.fps })

elseif cmd == 'sim' then
  local id, x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
  if not (id and x and y and z) then util.emit({ error = 'usage: claude/gefahr sim <unit_id> <x> <y> <z>   (Trockenlauf, Einheit wird als lebend an dieser Stelle simuliert)' }) return end
  if not df.unit.find(id) then util.emit({ error = 'Einheit ' .. id .. ' nicht gefunden' }) return end
  local S = scan({ sim = { { id = id, x = x, y = y, z = z } } })
  local h = handle(S, { dry = true, force = true })
  local rows = {}
  for _, e in ipairs(S.list) do if e.sim then rows[#rows + 1] = brief(e) end end
  util.emit({ sim = rows, ereignis = h.text, aktionen = h.actions })

elseif cmd == 'selftest' then
  -- Dry run with existing units: dead Forgotten Beast (id 560 if present) at various places, demons (underworld), dwarves, Rutherer.
  local res = { klassen = {}, sim = {}, ok = true }
  local function count_class(name, id)
    local u = df.unit.find(id)
    if not u then res.klassen[#res.klassen + 1] = name .. ': Einheit ' .. id .. ' fehlt' return end
    local k, g = klasse(u)
    res.klassen[#res.klassen + 1] = string.format('%s id%d race=%s -> %s %s', name, id, raw_info(u).id, tostring(k), tostring(g))
    return k
  end
  local fb
  for _, u in ipairs(df.global.world.units.all) do
    local r = df.creature_raw.find(u.race)
    if r and r.caste[0].flags.FEATURE_BEAST and dfhack.units.isDead(u) then fb = u.id break end
  end
  local kfb = fb and count_class('Vergessene Bestie (tot)', fb)
  if fb and kfb ~= 'A' then res.ok = false end
  -- real units per race: dwarf (no hit), giant rat, demon (underworld: class A, but no alarm)
  local seen = {}
  for _, u in ipairs(df.global.world.units.active) do
    local ri = raw_info(u)
    if not seen[ri.id] and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then
      seen[ri.id] = true
      local k, g = klasse(u)
      res.klassen[#res.klassen + 1] = string.format('real %s id%d z%d -> %s %s%s', ri.id, u.id, u.pos.z, tostring(k), tostring(g), excluded(u) and ' (ausgeschlossen)' or '')
    end
  end
  local S0 = scan()
  res.real_alarm, res.real_alarm_A, res.real_gelistet = S0.alarm, S0.alarm_A, #S0.list
  if fb then
    -- Places relative to config (Run 5: no fixed coordinates of an old map)
    local cf = C()
    local sx, sy, sz = cf.FORT_X, cf.FORT_Y, cf.SURFACE_Z
    local function ort(name, x, y, z) return { string.format('%s (%d,%d,%d)', name, x, y, z), x, y, z } end
    local orte = {
      ort('Fort-Kern Oberflaeche', sx, sy, sz), ort('Fort unterirdisch', sx, sy, sz - 8), ort('Tiefe Ebene', sx, sy, sz - 18),
      ort('Oberflaeche 40 Kacheln O', sx + 40, sy, sz), ort('Oberflaeche fern', 20, 20, sz + 2),
      { 'Unterwelt (111,2,2)', 111, 2, 2 } }
    for _, o in ipairs(orte) do
      local S = scan({ sim = { { id = fb, x = o[2], y = o[3], z = o[4] } } })
      local e
      for _, x in ipairs(S.list) do if x.sim then e = x end end
      local h = handle(S, { dry = true, force = true })
      res.sim[#res.sim + 1] = { ort = o[1], eintrag = e and brief(e) or 'kein Eintrag', ereignis_aktionen = h.actions }
    end
  end
  res.hinweis = 'Trockenlauf: keine Flags, keine Pause, keine Aenderung an alerts/fps.'
  util.emit(res)

elseif cmd == 'fire' or cmd == 'firetest' then
  -- fire = LIVE event for a simulated unit (flags, pause!, civilian warning) - deliberate use only. firetest = same write paths, but only files in tools/out/test/ (no pause, no alarm).
  local id, x, y, z = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
  if not (id and x and y and z) then util.emit({ error = 'usage: claude/gefahr ' .. cmd .. ' <unit_id> <x> <y> <z>' }) return end
  if not df.unit.find(id) then util.emit({ error = 'Einheit ' .. id .. ' nicht gefunden' }) return end
  local S = scan({ sim = { { id = id, x = x, y = y, z = z } } })
  local h = handle(S, { force = true, test = (cmd == 'firetest') })
  util.emit({ ereignis = h.text, aktionen = h.actions })

else
  util.emit({ error = 'unbekannt', usage = 'status | sim <id> x y z | selftest | fire <id> x y z (scharf)' })
end
