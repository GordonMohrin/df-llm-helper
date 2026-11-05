-- BUG-437 (Run 16a i1 Syrupobeyed y378: three citizens, two of them thirsty past 23000, killed by our own stone-fall traps in the hall):
-- care's DEATH by trap for a citizen is counted in state traps.ck and raises DECISION_NEEDED trap_friendly (A), once a day.
local T = require('testlib')
local F = require('wp8_world')
local C = require('dfllm.util.contract')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function day(W) W.run(1200, {skip = 100}); settle(W) end

local MAN = {v = 2, zones = {Z2 = {{10, 20, 5, 14, 20, 5}}},
             traps = {{id = 'Z2', kind = 'stone', tiles = {{11, 20, 5}, {12, 20, 5}, {13, 20, 5}}}}}

local function world()
  local W = F.world{persist = {manifest = MAN}}
  df.trap_type = require('dfllm.util.k_mock').enum({'Lever', 'PressurePlate', 'CageTrap', 'StoneFallTrap', 'WeaponTrap', 'TrackStop'})
  df.item_cagest = {is_instance = function(_, it) return type(it) == 'table' and it._cage == true end}
  W.set_census('u', F.census_u({}, {caged = {}}))
  for x = 11, 13 do
    F.building(W, 'TRAP', {centerx = x, centery = 20, z = 5, trap_type = df.trap_type.StoneFallTrap, ready_timeout = 0,
                           contained_items = {}, getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end})
  end
  W.load(fresh('traps'))
  day(W)
  return W
end

local function death(W, unit, by, citizen)
  W.K.emit('DEATH', 'B', 'citizen ' .. unit .. ' found dead', {unit = unit, by = by, citizen = citizen, cause = 'killed',
                                                              pos = {12, 20, 5}, thirst = 30000, hunger = 100, dtype = 'TRAP'})
  settle(W)
end

local function asks(W)
  local r = {}
  for _, ev in ipairs(W.find_events('DECISION_NEEDED')) do if ev.d.id == 'trap_friendly' then r[#r + 1] = ev end end
  return r
end

T.test('a citizen killed by our own trap: ck in the state, DECISION_NEEDED trap_friendly (A) with the tile and the options', function()
  local W = world()
  T.eq(W.state().traps.ck, nil)
  death(W, 26667, 'trap', 1)
  local a = asks(W)
  T.eq(#a, 1)
  T.eq({a[1].cls, a[1].d.n, a[1].d.unit, a[1].d.pos}, {'A', 1, 26667, {12, 20, 5}})
  T.ok(a[1].d.q:find('12,20,5', 1, true) and a[1].d.q:find('cage traps', 1, true) and #a[1].d.q <= 200, a[1].d.q)
  day(W)
  T.eq(W.state().traps.ck, 1)
  T.eq(C.check_state(W.state()), {})
end)

T.test('the same unit twice, an animal, a death by something else: no second count; a second citizen after a day asks again', function()
  local W = world()
  death(W, 1, 'trap', 1)
  death(W, 1, 'trap', 1)
  death(W, 2, 'trap', 0)                           -- not a citizen
  death(W, 3, 'woolly mammoth', 1)                 -- not a trap
  T.eq(#asks(W), 1)
  death(W, 4, 'trap', 1)                           -- inside the day: counted, no new question
  T.eq(#asks(W), 1)
  W.run(1300, {skip = 100}); settle(W)
  death(W, 5, 'trap', 1)
  local a = asks(W)
  T.eq({#a, a[2].d.n}, {2, 3})
  day(W)
  T.eq(W.state().traps.ck, 3)
end)

T.done()
