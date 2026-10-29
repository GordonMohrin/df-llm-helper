-- Live L3 drill KPI 'outside at T+1,200' (DESIGN §11 R2, §14): every citizen outside Kern+ at T+1,200 counts,
-- also one still walking home (2 tiles closer to the entry than at T+1,100, 10 closer than at T0) or waiting at a
-- raised outer/inner bridge: in a real siege O1 rises at T+450 and that citizen stands outside with the attackers,
-- and a passed drill raises the pop cap (R2). DRILL_RESULT reports those as `walking` (diagnostic only), plus the
-- outer bridge's raise time, the lever-job take and the pullers (gate.kpi).
-- Real drill on the WP5 reflex + WP6 military/readiness on k_mock (strict), like test_drill.lua.
local T = require('testlib')
local X = require('wp6_world')
local S = X.S
local Z = X.Z

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world(extra)
  local units = X.citizens(30, 1, {skills = SKILLS})
  for _, u in ipairs(extra or {}) do units[#units + 1] = u end
  local W = X.world{units = units}
  W.runner = X.runner('P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  X.mod('drill').SETTLE = 1e9
  X.run(W, 1200)                               -- military sets up the squads
  X.equip_all(W)
  X.run(W, 50)
  return W
end
local function start(W) return X.call(W, 'drill', 'start', 'test') end
local function result(W)
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  return r[1], X.call(W, 'drill', 'results').last[1]
end

T.test('a citizen walking home at T+1,200 still counts as outside (fails the drill) and is reported as walking', function()
  local W = world{X.cit(99, {pos = {20, 20, Z}})}
  start(W)
  X.run(W, 2500, {at = {{1130, function(W) W.move(99, 26, 25, Z) end}}})    -- 6 tiles closer to B1 (51,40)
  local ev, rec = result(W)
  T.eq({ev.d.pass, ev.d.outside, ev.d.walking}, {0, 1, 1}, ev.msg)
  T.eq({rec.pass, rec.outside, rec.fails}, {0, 1, {'outside:1'}})
  T.ok(ev.msg:find('outside 1 %(1 walking home%)'), ev.msg)
end)

T.test('a citizen locked out at the raised O1 is reported as walking and still counts', function()
  local W = world{X.cit(99, {pos = {51, 6, Z}})}       -- 4 tiles outside O1 (y 10), off the footprint margin
  start(W)
  X.run(W, 2500, {at = {{700, function(W) W.move(99, 51, 8, Z) end}}})   -- to the raised gate
  local ev = result(W)
  T.eq({ev.d.pass, ev.d.outside, ev.d.walking}, {0, 1, 1}, ev.msg)
  X.run(W, 600, {at = {{1, function(W) W.move(99, 51, 2, Z) end}}})   -- steps back: O1 may come down

  T.eq(S.bstate(W, 'O1'), 'down', 'lowered again after the drill')
end)

T.test('a citizen who headed home and stopped where the raised gate cut the path is reported as walking', function()
  local W = world{X.cit(99, {pos = {20, 20, Z}})}                         -- 31 tiles from B1 at T0
  start(W)
  X.run(W, 2500, {at = {{500, function(W) W.move(99, 36, 30, Z) end}}})   -- 15 closer by T+500, then still
  local ev = result(W)
  T.eq({ev.d.pass, ev.d.outside, ev.d.walking}, {0, 1, 1}, ev.msg)
end)

T.test('a citizen who stays out there fails the drill and is not walking', function()
  local W = world{X.cit(99, {pos = {20, 20, Z}})}
  start(W)
  X.run(W, 2500)
  local ev, rec = result(W)
  T.eq({ev.d.pass, ev.d.outside, ev.d.walking}, {0, 1, 0}, ev.msg)
  T.eq(rec.fails, {'outside:1'})
end)

T.test('one walking home, one staying out: both count, one is walking', function()
  local W = world{X.cit(98, {pos = {20, 20, Z}}), X.cit(99, {pos = {15, 15, Z}})}
  start(W)
  X.run(W, 2500, {at = {{1130, function(W) W.move(99, 22, 22, Z) end}}})
  local ev, rec = result(W)
  T.eq({ev.d.pass, ev.d.outside, ev.d.walking}, {0, 2, 1}, ev.msg)
  T.eq(rec.fails, {'outside:2'})
end)

T.test('everyone inside: the drill passes, nobody walking', function()
  local W = world()
  start(W)
  X.run(W, 2500)
  local ev, rec = result(W)
  T.eq({ev.d.pass, ev.d.outside, ev.d.walking}, {1, 0, 0}, ev.msg)
  T.eq({rec.pass, rec.fails}, {1, {}})
end)

T.test('DRILL_RESULT reports the outer raise time, the lever-job take and the pullers; persist keeps its fields', function()
  local W = world()
  start(W)
  X.run(W, 2500)
  local ev, rec = result(W)
  local k = X.call(W, 'gate', 'kpi')
  T.eq(ev.d.outer, k.last_raise_ticks.O1)
  T.ok(ev.d.outer >= 0 and ev.d.outer <= 900, 'outer ' .. ev.d.outer)
  T.ok(ev.d.take >= 0 and ev.d.take <= 300, 'take ' .. ev.d.take)
  T.eq(ev.d.pullers, 0, 'no lever rooms in this world')
  T.ok(ev.msg:find('outer ' .. ev.d.outer .. ' %(goal 600%)'), ev.msg)
  local keys = {}
  for key in pairs(rec) do keys[#keys + 1] = key end
  table.sort(keys)
  T.eq(keys, {'dbl', 'fails', 'outside', 'pass', 'raised', 'tick', 'worn'}, 'persist drill: CONTRACTS §10 fields only')
end)

T.done()
