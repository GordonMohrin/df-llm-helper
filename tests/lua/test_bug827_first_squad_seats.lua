-- BUG-827 (Run 17 i1/i3/i4, 24.11.): the growth ladder's first step needs 3+ armed members in the first melee squad, but at pop 30
-- (15 % = 5 soldiers, 2 for the crossbows) M.targets gave squad A ceil(3/2) = 2 seats, and M.gear_fill capped the melee squads at
-- GEAR_FLOOR 2: "first squad: 0 of 2 members hold a real weapon (need 3+)" for good (the cap 30 never lifts). The first melee squad now
-- gets growth.armed_min seats in targets and in the gear floor. i3 numbers: 30 adults, body armor 2, weapons 4, shields 14.
local T = require('testlib')
local X = require('wp6_world')

local function world(o)
  local W = X.world{units = X.citizens(o.n, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_census('i', {tick = 0, g_weapon = o.g_weapon or 4, g_body = o.g_body or 2, g_shield = 14, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex = {v = 2, growth = o.growth or {on = true}}
  return W
end

local function seats(W)
  local out = {}
  for _, s in pairs(W.squads) do
    local n = 0
    for _, p in ipairs(s.positions) do if p.occupant >= 0 then n = n + 1 end end
    out[s.alias] = n
  end
  return out
end

T.test('BUG-827: pop 30, 2 body armors: the first melee squad gets 3 seats (growth.armed_min), the second the rest', function()
  local W = world{n = 30}
  W.run(1200 * 6, {skip = 9}); W.state()
  local n, per, _, _, gear = X.mod('military').targets(W.K)
  T.ok(per.A >= 3, 'squad A target ' .. T.show(per) .. ' n ' .. tostring(n))
  T.ok(gear == nil or gear.fill.A >= 3, 'gear fill ' .. T.show(gear))
  local s = seats(W)
  T.ok((s.A or 0) >= 3, 'squad A seated: ' .. T.show(s))
end)

T.test('BUG-827: growth off keeps the old split (A 2, B 1 at pop 30)', function()
  local W = world{n = 30, growth = {on = false}}
  W.run(1200 * 6, {skip = 9}); W.state()
  local _, per = X.mod('military').targets(W.K)
  T.ok(per.A <= 2, 'squad A target ' .. T.show(per))
end)

T.test('BUG-827: a small fort (pop 12) is not bent: no extra soldiers below 2/3 of the base cap', function()
  local W = world{n = 12}
  W.run(1200 * 6, {skip = 9}); W.state()
  local n, per = X.mod('military').targets(W.K)
  T.ok(n <= 3, 'soldiers ' .. n .. ' ' .. T.show(per))
end)

T.test('BUG-829: state mil.kit names the first squad (sq members, sqw armed, wb backed) next to the ladder text', function()
  local W = world{n = 30}
  W.run(1200 * 6, {skip = 9})
  local s = W.state()
  T.ok(s.mil and s.mil.kit, 'mil.kit ' .. T.show(s.mil))
  T.ok(s.mil.kit.sq >= 3 and s.mil.kit.sqw == 0 and s.mil.kit.wb == 0, T.show(s.mil.kit))
  T.eq(s.ready.gh.halt, 'squad')
  T.ok(s.ready.gh.need:find('first squad: 0 of ' .. s.mil.kit.sq, 1, true), s.ready.gh.need)
end)
