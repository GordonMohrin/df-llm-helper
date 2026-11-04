-- Run 15b Earthboat y385 (i3, fix14-lockdown): BUG-331 a SIEGE of 35 goblins that stood 37-84 tiles out for 64+ days, none
-- inside, none near a bridge, kept the deep defense (weak: worn 56% < 60%) and the civilians in the dry Tiefe+ the whole time;
-- nobody asked to attack, nothing eased. Now siege_long.days of calm ease the siege (the deep defense lifted, the civilians back
-- to Kern+, DECISION_NEEDED siege_long with the squad.sortie command); a hostile coming near ends the easing. BUG-330 (the same
-- night): siege lists water's care burrow in the civ alert. The world is test_intake's (the real sense, threat, siege, gate,
-- military and reflex on the siege world) with the army far east of O1. Every test fails on 9b6f614 except the off/near guard.
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function manifest()
  local m = S.manifest()
  m.zones = {Z1 = {{48, 11, Z, 54, 15, Z}}, Z2 = {{51, 16, Z, 51, 24, Z}, {51, 32, Z, 51, 39, Z}},
             Z3 = {{44, 41, Z, 58, 59, Z}}, Z4 = {{40, 61, Z, 80, 95, Z}}}
  return m
end

-- opts: reflex (config/reflex.json), army {n, x, y}, extra (more modules to load), equip
local function world(o)
  o = o or {}
  local dir = H.tmpdir(o.tag or 'lg')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local units = X.citizens(50, 1)
  local ar = o.army or {12, 120, 0}
  for _, u in ipairs(S.army(ar[1], ar[2], ar[3])) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = manifest(), dfpath = dir, cfg = {reflex = o.reflex or {v = 2}}}
  X.install(W, {})
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return y < 25 end
  package.loaded['dfllm.reflex'] = nil
  local mods = {X.runner('P5'), snap, require('dfllm.reflex')}
  for _, m in ipairs(o.extra or {}) do mods[#mods + 1] = m end
  X.load(W, {'military'}, mods)
  for _, u in ipairs(units) do if u.invader then W.unit(u.id)._m.hidden = true end end
  W.run(9, {skip = 9})
  for _, u in ipairs(units) do if u.invader then W.unit(u.id)._m.hidden = nil end end
  if o.equip ~= false then X.equip_all(W) end
  W.goblins = {}
  for _, u in ipairs(units) do if u.invader then W.goblins[#W.goblins + 1] = u.id end end
  return W
end

local function run(W, ticks)
  local done = 0
  while done < ticks do
    W.frame(9)
    S.sim(W)
    done = done + 9
  end
end

local function until_(W, ticks, fn)
  local n = 0
  while n < ticks do
    if fn(W) then return true end
    run(W, 25)
    n = n + 25
  end
  return fn(W)
end

local function evs(W, t, id)
  local r = {}
  for _, e in ipairs(W.find_events(t)) do if id == nil or e.d.id == id then r[#r + 1] = e end end
  return r
end

local function logged(W, needle)
  for _, l in ipairs(W.logs) do
    if tostring(l.msg or l[3] or l):find(needle, 1, true) then return true end
  end
  return false
end

local LG = {v = 2, siege_long = {days = 1, near = 25}}

---------------------------------------------------------------- BUG-331
T.test('BUG-331 (Earthboat y385: 64 days of SIEGE, the army far, the civilians held in the dry refuge): siege_long.days ' ..
       'of calm lift the deep defense (civilians back to Kern+) and ask once (DECISION_NEEDED siege_long, the sortie command)',
       function()
  local W = world{equip = false, reflex = LG}
  T.ok(until_(W, 900, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  T.ok(until_(W, 900, function() return #evs(W, 'SIEGE_DEEP') > 0 end), 'the weak squads: the deep defense first')
  run(W, 300)
  T.eq(W.alert_burrows[1], 'Tiefe+')
  T.ok(until_(W, 2400, function() return #evs(W, 'DECISION_NEEDED', 'siege_long') > 0 end),
       'old code: the deep defense holds for the whole siege, nothing asks')
  local e = evs(W, 'DECISION_NEEDED', 'siege_long')[1]
  T.eq({e.cls, e.d.lifted, e.d.vis}, {'A', 1, 12})
  T.ok(e.d.n > 25, 'the nearest hostile ' .. tostring(e.d.n))
  T.ok(e.msg:find('no hostile inside Kern+ or within 25 tiles', 1, true), e.msg)
  T.ok(e.msg:find('deep defense lifted: the civilians back to Kern+', 1, true), e.msg)
  T.ok(type(e.d.cmd) == 'string' and e.d.cmd:find('squad.sortie', 1, true) and e.d.cmd:find('"approve":true', 1, true),
       tostring(e.d.cmd))
  T.ok(#e.msg <= 200 and #e.d.q <= 200)
  run(W, 300)
  T.eq(W.state().wave.deep, nil, 'the deep defense is lifted')
  T.ok(W.state().wave.lg ~= nil, 'state wave.lg: eased since')
  T.eq(W.alert_burrows[1], 'Kern+', 'the civilians go back to Kern+ (food, drink, patients)')
  T.eq(W.K.mode(), 'SIEGE', 'still a siege: the bridges stay up')
  run(W, 3000)
  T.eq(#evs(W, 'DECISION_NEEDED', 'siege_long'), 1, 'asked once per easing')
  T.eq(W.state().wave.deep, nil, 'no deep defense while eased (no destroyer)')
end)

T.test('BUG-331: a hostile within siege_long.near ends the easing (kern.log) and the deep defense comes back on its own ' ..
       'reasons; the calm clock starts again', function()
  local W = world{equip = false, reflex = LG}
  T.ok(until_(W, 900, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  T.ok(until_(W, 3600, function() return #evs(W, 'DECISION_NEEDED', 'siege_long') > 0 end), 'eased')
  local n0 = #evs(W, 'SIEGE_DEEP')
  W.move(W.goblins[1], 60, 2, Z)                             -- 9 tiles from O1
  T.ok(until_(W, 600, function() return logged(W, 'the eased siege ends') end), 'the easing ends')
  T.ok(until_(W, 600, function() return W.state().wave.deep == 'weak' end), 'the deep defense is back')
  T.ok(#evs(W, 'SIEGE_DEEP') > n0, 'SIEGE_DEEP again')
  run(W, 300)
  T.eq(W.alert_burrows[1], 'Tiefe+')
end)

T.test('BUG-331: siege_long.on false keeps the old rule; an army near O1 is never calm', function()
  local W = world{equip = false, reflex = {v = 2, siege_long = {on = false, days = 1}}}
  T.ok(until_(W, 900, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  run(W, 3600)
  T.eq(#evs(W, 'DECISION_NEEDED', 'siege_long'), 0)
  T.eq(W.state().wave.deep, 'weak')
  local W2 = world{equip = false, reflex = LG, army = {12, 51, 0}}  -- 8-10 tiles from O1
  T.ok(until_(W2, 900, function() return W2.K.mode() == 'SIEGE' end), 'SIEGE')
  run(W2, 3600)
  T.eq(#evs(W2, 'DECISION_NEEDED', 'siege_long'), 0, 'not calm')
  T.eq(W2.state().wave.deep, 'weak')
end)

-- BUG-331 review (merge14): seal's fight_rule kept a sounding refuge (KEEP) unless it had a reason; a stub with that rule
-- (the refuge kept unless `release`, Kern+ otherwise) records what siege asks
local function seal_stub(calls)
  return {name = 'seal', every = {ticks = 100000},
          alert_burrow = function(K, mode, default, hold, cur, release)
            calls[#calls + 1] = {mode = mode, cur = cur, release = release}
            if mode == 'BREACH' then return 'Tiefe+' end
            if cur == 'Tiefe+' and release ~= true then return 'Tiefe+', nil, 'Tiefe+ kept (SIEGE)' end
            return default
          end}
end

T.test('BUG-331 review: the eased siege releases the refuge in seal (alert_burrow `release`): the civilians really go ' ..
       'back to Kern+, and the question and the brief name the burrow seal holds', function()
  local calls = {}
  local W = world{equip = false, reflex = LG, extra = {seal_stub(calls)}}
  T.ok(until_(W, 900, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  T.ok(until_(W, 900, function() return #evs(W, 'SIEGE_DEEP') > 0 end), 'the deep defense first')
  run(W, 300)
  T.eq(W.alert_burrows[1], 'Tiefe+')
  T.ok(until_(W, 2400, function() return #evs(W, 'DECISION_NEEDED', 'siege_long') > 0 end), 'eased')
  local e = evs(W, 'DECISION_NEEDED', 'siege_long')[1]
  T.eq({e.d.lifted, e.d.to}, {1, 'Kern+'})
  T.ok(e.msg:find('deep defense lifted: the civilians back to Kern+', 1, true), e.msg)
  run(W, 300)
  T.eq(W.alert_burrows[1], 'Kern+', 'old code: seal keeps the sounding Tiefe+ (no release)')
  local last = calls[#calls]
  T.eq({last.mode, last.release}, {'SIEGE', true})
end)

T.test('BUG-331 review: when seal still holds another burrow, the question says so (never "back to Kern+")', function()
  local calls = {}
  local stub = seal_stub(calls)
  stub.alert_burrow = function(K, mode, default, hold, cur, release)
    calls[#calls + 1] = {mode = mode, cur = cur, release = release}
    return 'Tiefe+', nil, 'Tiefe+ kept'                       -- Kern+ fails seal's audit: the refuge stays
  end
  local W = world{equip = false, reflex = LG, extra = {stub}}
  T.ok(until_(W, 900, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  T.ok(until_(W, 3600, function() return #evs(W, 'DECISION_NEEDED', 'siege_long') > 0 end), 'eased')
  local e = evs(W, 'DECISION_NEEDED', 'siege_long')[1]
  T.eq(e.d.to, 'Tiefe+')
  T.ok(e.msg:find('deep defense lifted, but the civ alert holds the civilians in Tiefe+', 1, true),
       'old code: "back to Kern+": ' .. e.msg)
end)

---------------------------------------------------------------- BUG-330: the care burrow in the alert list
T.test('BUG-330: while water names its care burrow (water.care_rooms), siege lists it in the civ alert after the mode\'s ' ..
       'burrow; when water drops it, it leaves the list', function()
  local care = {'Pflege+'}
  local water = {name = 'water', every = {ticks = 1200}, care_rooms = function() return care end}
  local W = world{extra = {water}}
  W.burrow('Pflege+', {74, 83, Z, 74, 83, Z})               -- water's act.burrow_tiles made it (create)
  T.ok(until_(W, 900, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  run(W, 300)
  T.eq(W.alert_burrows[1], 'Kern+')
  local has = false
  for _, n in ipairs(W.alert_burrows) do if n == 'Pflege+' then has = true end end
  T.ok(has, 'old code: the alert list is the mode burrow and the lever rooms only: ' .. table.concat(W.alert_burrows, ','))
  care = {}
  run(W, 300)
  for _, n in ipairs(W.alert_burrows) do T.ok(n ~= 'Pflege+', 'dropped') end
end)

T.done()
