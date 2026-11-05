-- BUG-494 (Run 16b i2 Brotherarrow y372-y375: a Hibbertopterus pack at the brook drowned five citizens, `threat 0 vis`, no
-- PREDATOR): a large or predatory wild unit in or beside water is a WATER BEAST: census.w, WATER_PREDATOR (A) with race,
-- size, position, reach and the sortie, the fishers held home; no hostile, no lockdown. BUG-495: inspect what=unit knows a
-- non-citizen (sense.describe); PREDATOR / INTRUDER name race, size and reach (tests/lua/test_reflex.lua).
local T = require('testlib')
local S = require('siege_world')

local BROOK = {x = 70, y = 20, z = S.Z}

-- citizens: one in Kern+, one at the brook (11 tiles west of the beast's tile); a wild unit 300 in the water
local function world(spec)
  spec = spec or {}
  local units = {S.cit(1, 60, 70), S.cit(2, 60, spec.far and 90 or 20),
                 {id = 300, pos = {BROOK.x, BROOK.y, S.Z}, animal = true, race = 'HIBBERTOPTERUS', tame = spec.tame,
                  merchant = spec.merchant}}
  local W = S.world{units = units}
  df.creature_raw = {find = function() return {caste = {[0] = {flags = {LARGE_PREDATOR = spec.pred == true}}}} end}
  W.unit(300).race, W.unit(300).caste = 1, 0
  W.unit(300).body = {size_info = {size_cur = spec.size or 150000}}
  W.unit(300).flags1, W.unit(300).flags2 = spec.f1 or {}, {}
  W.tiles = W.tiles or {}
  local function tile(x, y, des) W.tiles[x .. ',' .. y .. ',' .. S.Z] = {des = des} end
  for x = 58, 72 do
    for y = 19, 21 do tile(x, y, {outside = true, hidden = false, flow_size = 0}) end
  end
  if spec.dry ~= true then
    tile(BROOK.x, BROOK.y, {outside = true, hidden = false, flow_size = spec.flow or 3, liquid_type = spec.liquid or 0})
  end
  -- the citizens' walk group 7; the water tile itself is none (0)
  dfhack.maps.getWalkableGroup = function(pos)
    if pos.x == BROOK.x and pos.y == BROOK.y and pos.z == S.Z then return 0 end
    return 7
  end
  local mil = S.military()
  mil.sortie_squad = function() return 'A', 5 end
  S.load(W, {mil})
  if spec.near then package.loaded['dfllm.sense'].WATER.near = spec.near end
  S.run(W, 300)
  return W
end

T.test('BUG-494 sense: a big wild unit in brook water is a water beast, WATER_PREDATOR once, no hostile, no lockdown', function()
  local W = world()
  local w = W.K.census.w
  T.eq({w.n, w.hold, w.near}, {1, 1, 10}, 'one beast, fishers held, 10 tiles from the citizen at the brook')
  local e = w.list[1]
  T.eq({e.id, e.sz, e.rn, e.wt, e.rc}, {300, 150000, 'HIBBERTOPTERUS', 'water 3/7', 2}, 'reachable from the bank')
  T.eq({W.K.mode(), W.K.census.h.vis}, {'PEACE', 0}, 'a brook is no entrance: no hostile, no alert')
  local ev = W.find_events('WATER_PREDATOR')
  T.eq(#ev, 1, 'announced once')
  T.eq({ev[1].cls, ev[1].d.id, ev[1].d.race, ev[1].d.sz, ev[1].d.reach, ev[1].d.fish, ev[1].d.wet},
       {'A', 300, 'HIBBERTOPTERUS', 150000, 2, 1, 'water 3/7'})
  T.eq(ev[1].d.pos, {BROOK.x, BROOK.y, S.Z})
  T.eq(ev[1].d.dc, 10)
  T.ok(ev[1].d.cmd:find('"target":[70,20,10]', 1, true) and ev[1].d.cmd:find('squad.sortie', 1, true), ev[1].d.cmd)
  S.run(W, 1200)
  T.eq(#W.find_events('WATER_PREDATOR'), 1, 'not again within the rearm window')
end)

T.test('BUG-494 sense: a LARGE_PREDATOR of small body counts; a small plain animal, a dry tile, a tame or merchant unit do not',
       function()
  T.eq(world{pred = true, size = 20000}.K.census.w.n, 1, 'the raws say large predator')
  T.eq(world{size = 20000}.K.census.w.n, 0, 'a fish-sized animal is wildlife')
  T.eq(world{dry = true}.K.census.w.n, 0, 'on dry ground it is the walk-group rule\'s business (PREDATOR)')
  T.eq(world{tame = true}.K.census.w.n, 0, 'tame')
  T.eq(world{merchant = true}.K.census.w.n, 0, 'a caravan animal')
  T.eq(world{f1 = {caged = true}}.K.census.w.n, 0, 'caged')
  T.eq(world{flow = 0}.K.census.w.n, 0, 'a bed without water')
  T.eq(world{liquid = 1}.K.census.w.n, 0, 'magma is no water')
  local W = world()
  T.eq(#W.find_events('WATER_PREDATOR'), 1)
end)

T.test('BUG-494 sense: the fishers stay home for WATER.hold ticks after the beast left; a beast far from every citizen waits',
       function()
  local W = world()
  T.eq(W.K.census.w.hold, 1)
  W.unit(300).pos = {x = 10, y = 90, z = S.Z}                 -- gone (far, dry)
  S.run(W, 1200)
  T.eq({W.K.census.w.n, W.K.census.w.hold}, {0, 1}, 'still held: seen 1200 ticks ago')
  S.run(W, 1500)
  T.eq(W.K.census.w.hold, 0, 'released after 2400 quiet ticks')
  local W2 = world{far = true, near = 30}                                 -- the citizen at the brook walked home: 70 tiles, Kern+ is 50 away, near = 30
  S.run(W2, 1500)
  T.eq(W2.K.census.w.hold, 0, 'nobody near: no hold')
end)

T.test('BUG-495 sense.describe / inspect what=unit: a non-citizen is described with race, size, water, reach, distance', function()
  local W = world()
  local ok, a, msg, d = W.K.call('sense', 'describe', 300)
  T.ok(ok and a == true, tostring(msg))
  T.eq({d.id, d.race, d.sz, d.wild, d.wet, d.reach, d.dc}, {300, 'HIBBERTOPTERUS', 150000, 1, 'water 3/7', 2, 10})
  T.ok(msg:find('HIBBERTOPTERUS', 1, true) and msg:find('150000 cm3', 1, true) and msg:find('reachable from the bank', 1, true), msg)
  local ok2, a2 = W.K.call('sense', 'describe', 99999)
  T.eq({ok2, a2}, {true, false}, 'a unit that is gone')
end)

T.done()
