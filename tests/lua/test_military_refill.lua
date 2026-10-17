-- Run 11 siege 3 (Kilrudrabed, y432/433: 25 dead, pop 54 -> 29, soldiers 10 -> 5, O1 destroyed): squads A and B
-- emptied (deaths) during the siege and were never refilled; only C (5) remained. In SIEGE/BREACH a melee squad below
-- half its target (the first melee squad at least HOLD_MIN, whatever the shrunk population target or the tools-first
-- rule says) is refilled from healthy adult civilians standing in Kern+, never from the refuge; kern.log says so.
-- Real sense and military on the WP6 world (k_mock, strict): Kern+ 40..80 x 41..95 (z 8..10), Tiefe+ 60..80 x 60..80
-- (z 3..5); the citizens stand in Kern+ (X.cit).
local T = require('testlib')
local X = require('wp6_world')
local kmock = require('dfllm.util.k_mock')
local Z = X.Z

local function boot(n, units)
  local W = X.world{n = n, units = units}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end

local function ids_of(s)
  local r = {}
  for _, p in ipairs(s.positions) do if p.occupant >= 0 then r[#r + 1] = df.historical_figure.find(p.occupant).unit_id end end
  return r
end
local function alive(W, s)
  local n = 0
  for _, id in ipairs(ids_of(s)) do if not W.unit(id)._m.dead then n = n + 1 end end
  return n
end
local function kill_squad(W, s)
  for _, id in ipairs(ids_of(s)) do W.kill(id) end
end
local function logs(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then r[#r + 1] = l.msg end end
  return r
end

-- 30 citizens: A 2, B 1, C 2 in PEACE; `later` come after that (no soldiers); then the siege kills A and B
local function siege_world(later)
  local W = boot(30)
  W.run(3600, {skip = 9})
  local A, B, C = X.squad_of(W, 'A'), X.squad_of(W, 'B'), X.squad_of(W, 'C')
  T.eq({alive(W, A), alive(W, B), alive(W, C)}, {2, 1, 2}, 'staffed in PEACE')
  for _, u in ipairs(later or {}) do X.add(W, u) end
  W.K.set_mode('SIEGE', 'test')
  kill_squad(W, A)
  kill_squad(W, B)
  return W, A, B, C
end

T.test('Run 11 siege 3: A and B die in a SIEGE -> A refilled to HOLD_MIN (5) and B to its target with healthy ' ..
       'civilians from Kern+; kern.log names them', function()
  -- old code: A back to its population target (2) at most
  local W, A, B, C = siege_world()
  W.run(1300, {skip = 9})
  T.eq({alive(W, A), alive(W, B), alive(W, C)}, {5, 1, 2})
  local l = logs(W, 'military: SIEGE refill: squad A ')
  T.ok(#l >= 1 and l[#l]:find('-> 5 of 5 with healthy civilians from the core', 1, true), l[#l] or 'no refill line')
end)

T.test('Run 11 siege 3: never from the refuge, never a hurt, thirsty or outside citizen; the best ones in the core', function()
  -- the eight best fighters: four in the refuge, two outside the core, one wounded, one thirsty
  local units = {}
  local spots = {{70, 70, Z - 6}, {71, 70, Z - 6}, {72, 70, Z - 6}, {73, 70, Z - 6}, {20, 20, Z}, {21, 20, Z},
                 {50, 50, Z}, {51, 50, Z}}
  for i, p in ipairs(spots) do
    units[i] = {id = 100 + i, pos = p, citizen = true, adult = true, skills = {AXE = 15, SHIELD = 10}}
  end
  local W, A = siege_world(units)
  W.unit(107).body = {wounds = kmock.vec{{id = 1}}}
  W.unit(108).counters2 = {thirst_timer = 40000, hunger_timer = 0}
  W.run(1300, {skip = 9})
  for _, id in ipairs(ids_of(A)) do              -- old code: 101 and 102 (the refuge, the best fighters) join A
    if not W.unit(id)._m.dead then T.ok(id < 100, 'refilled with ' .. id .. ' (a refuge, outside, hurt or thirsty one)') end
  end
  T.eq(alive(W, A), 5)
end)

T.test('Run 11 siege 3: the tools-first rule (fewer than 3 axes) does not leave the core without melee in a siege',
       function()
  -- old code: melee targets 0 with fewer than TOOLS_MIN axes: A and B are never refilled
  local W, A, B = siege_world()
  W.set_census('i', {tick = 0, w_axe = 1, w_pick = 5})
  W.run(1300, {skip = 9})
  T.eq(alive(W, A), 5, 'A at HOLD_MIN')
  T.eq(alive(W, B), 0, 'B has no target without axes: only the hold minimum')
end)

T.test('Run 11 siege 3: a squad at or above half its target gets no top-up in a siege; nobody in the core: a ' ..
       'kern.log line says why', function()
  local W = boot(30)
  W.run(3600, {skip = 9})
  local A = X.squad_of(W, 'A')
  W.K.set_mode('SIEGE', 'test')
  W.run(1300, {skip = 9})
  T.eq(alive(W, A), 5, 'below half (2 of 5): refilled')
  local ids = ids_of(A)
  W.kill(ids[#ids])
  W.kill(ids[#ids - 1])                            -- 3 of 5: at or above half
  local before = #logs(W, 'refill: squad A')
  W.run(1300, {skip = 9})
  T.eq({alive(W, A), #logs(W, 'refill: squad A')}, {3, before}, 'no top-up')
  -- everybody left moves into the refuge: A falls to 1 and nobody may come
  for _, u in ipairs(df.global.world.units.active) do
    if u.military.squad_id < 0 then W.move(u.id, 70, 70, Z - 6) end
  end
  W.kill(ids[#ids - 2])
  W.kill(ids[#ids - 3])
  W.run(1300, {skip = 9})
  T.eq(alive(W, A), 1)
  local l = logs(W, 'military: SIEGE: squad A 1 of 5 and no healthy civilian in the core to refill it')
  T.ok(#l == 1 and l[1]:find('in the refuge ', 1, true), l[1] or 'no line')
end)

T.test('Run 11 siege 3: in PEACE nothing changes (the population target, from anywhere)', function()
  local W = boot(30)
  W.run(3600, {skip = 9})
  T.eq(alive(W, X.squad_of(W, 'A')), 2)
  T.eq(#logs(W, 'refill'), 0)
end)

-- Run 11 siege 8 (Kilrudrabed y441: 10 soldiers at worn 58 %, no metal in ten years; the recruits without armor or a
-- weapon died first): the melee squads are filled only as far as the gear goes. A set = a true body armor, a melee
-- weapon (metal melee weapons, then the axes beyond the woodcutters' keep) and a shield (economy's census g_body,
-- g_weapon, w_axe, g_shield); the first melee squad keeps GEAR_FLOOR (2). While economy says metal is short, the
-- positions the gear cannot fill go to the crossbow squad as far as the free crossbows go. targets' `per` stays the
-- demand (economy orders the gear for it).
local GEAR = {tick = 0, w_pick = 20, w_axe = 4, g_weapon = 0, g_body = 10, g_shield = 10, g_xbow = 0}
local function gear_world(n, census, metal_short)
  local W = X.world{n = n}
  local mods = {X.runner('P5')}
  if metal_short ~= nil then
    mods[#mods + 1] = {name = 'economy', every = {ticks = 1200}, metal = function() return {short = metal_short} end}
  end
  X.load(W, {'military'}, mods, {'sense'})
  W.set_census('i', census)
  W.state()
  W.run(9, {skip = 9})
  W.run(3600, {skip = 9})
  return W
end
local function count(W, k) local s = X.squad_of(W, k); return s and alive(W, s) or 0 end

T.test('Run 11 siege 8: melee filled to the armor + weapon + shield sets (3 spare axes: 3 sets), the demand kept; ' ..
       'state mil.cap, kern.log', function()
  -- old code: A 3, B 3 (the population target), no gear value from targets
  local W = gear_world(50, GEAR)
  local M = X.mod('military')
  local n, per, _, _, g = M.targets(W.K)
  T.eq({n, per.A, per.B, per.C}, {8, 3, 3, 2}, 'the demand (economy orders the gear for it)')
  T.ok(g, 'a gear cap')
  T.eq({g.sets, g.melee, g.want, g.xbow, g.fill.A, g.fill.B, g.fill.C}, {3, 3, 6, 0, 3, 0, 2})
  T.eq({count(W, 'A'), count(W, 'B'), count(W, 'C')}, {3, 0, 2})
  T.eq(W.state().mil.cap, {sets = 3, melee = 3, want = 6, xbow = 0})
  T.eq(#logs(W, 'military: melee filled to 3 of 6: 3 gear sets (body armor 10, melee weapons 3, shields 10)'), 1)
  -- no set at all: the first squad keeps its leader and one
  local c0 = {}
  for k, v in pairs(GEAR) do c0[k] = v end
  c0.g_shield = 0
  W.set_census('i', c0)
  local _, _, _, _, g0 = M.targets(W.K)
  T.eq({g0.sets, g0.fill.A, g0.fill.B}, {0, 2, 0}, 'GEAR_FLOOR')
  -- enough gear: no cap
  local c1 = {}
  for k, v in pairs(GEAR) do c1[k] = v end
  c1.g_weapon = 6
  W.set_census('i', c1)
  T.eq(select(5, M.targets(W.K)), nil, 'the sets fill every melee position')
  -- an older census without the gear counts: no cap (unknown)
  W.set_census('i', {tick = 0, w_axe = 20, w_pick = 20})
  T.eq(select(5, M.targets(W.K)), nil)
end)

T.test('Run 11 siege 8: metal short: the positions the gear cannot fill go to the crossbows, as far as crossbows go', function()
  -- old code: C stays at its 2 positions, A and B at 3 each with no armor or weapon for half of them
  local c = {}
  for k, v in pairs(GEAR) do c[k] = v end
  c.g_xbow = 4
  local W = gear_world(50, c, true)
  local _, per, _, _, g = X.mod('military').targets(W.K)
  T.eq({per.C, g.xbow, g.fill.C}, {2, 3, 4}, '3 more crossbow positions in the demand, 2 crossbows free beyond C\'s own')
  T.eq({count(W, 'A'), count(W, 'B'), count(W, 'C')}, {3, 0, 4})
  T.eq(W.state().mil.cap, {sets = 3, melee = 3, want = 6, xbow = 3})
  T.eq(#logs(W, 'metal short: 3 more crossbow positions'), 1)
  -- metal not short: no shift
  local W2 = gear_world(50, c, false)
  local _, _, _, _, g2 = X.mod('military').targets(W2.K)
  T.eq({g2.xbow, g2.fill.C}, {0, 2})
end)

T.test('Run 11 siege 8: in a SIEGE the first melee squad is still refilled to HOLD_MIN beyond the gear; B stays capped',
       function()
  local W = gear_world(50, GEAR)
  local A = X.squad_of(W, 'A')
  T.eq(alive(W, A), 3)
  W.K.set_mode('SIEGE', 'test')
  kill_squad(W, A)
  W.run(1300, {skip = 9})
  T.eq(alive(W, A), 5, 'the core stations need bodies at the choke: HOLD_MIN from healthy core civilians')
  T.eq(count(W, 'B'), 0, 'no gear for B: not drafted')
  T.ok(#logs(W, 'military: SIEGE refill: squad A ') >= 1)
end)

T.done()
