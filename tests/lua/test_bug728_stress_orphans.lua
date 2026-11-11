-- BUG-728 (Run 16b i2 Whirledrampart y430: a child at stress 99,880 smothered two bedridden patients in the hospital, babies starved after
-- their mothers died of thirst there): care names the citizens at raw stress >= care.XS.stress (DECISION_NEEDED stress_extreme: who, where,
-- the needs that ease it), takes them off the Orderlies detail (water adds no caregiver of this kind), and names the babies whose mother is
-- dead (DECISION_NEEDED orphan_babies); each once per set (util/cadence).
local T = require('testlib')
local CW = require('care_world')

local function world(opts)
  opts = opts or {}
  local W, care = CW.world{cit = 8}
  local function stress(id, v) W.unit(id).status = {current_soul = {personality = {stress = v}}} end
  for i = 1, 8 do stress(i, 1000) end
  stress(1, opts.low and 70000 or 99880)
  W.unit(1)._m.adult = false                                   -- a child
  W.unit(1)._m.name = 'Dwarven Child Zon'
  W.unit(3)._m.baby, W.unit(3)._m.adult = true, false           -- a baby, its mother 4
  W.unit(3).relationship_ids = {Mother = 4}
  W.unit(5)._m.baby, W.unit(5)._m.adult = true, false           -- a baby whose mother 6 lives
  W.unit(5).relationship_ids = {Mother = 6}
  if not opts.alive then W.unit(4)._m.dead = true end
  return W, care
end

local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end

T.test('BUG-728: a child at stress 99,880 is named (DECISION stress_extreme), kept from the carer pool', function()
  local W, care = world()
  CW.day(W, 1)
  local d = decisions(W, 'stress_extreme')
  T.eq(#d, 1)
  T.ok(d[1].d.q:find('Dwarven Child Zon (1, child, stress 99880', 1, true), d[1].d.q)
  T.ok(d[1].d.q:find('Orderlies', 1, true) and d[1].d.q:find('temple', 1, true), d[1].d.q)
  T.eq(d[1].d.n, 1)
  T.ok(d[1].d.cmds[1]:find('inspect what=unit key=1', 1, true), d[1].d.cmds[1])
  T.eq(package.loaded['dfllm.care'].stress_ids(), {[1] = true})
  CW.day(W, 1)
  T.eq(#decisions(W, 'stress_extreme'), 1, 'not repeated for the same set')
end)

T.test('BUG-728: under the limit nobody is named and no detail changes', function()
  local W = world{low = true}
  CW.day(W, 1)
  T.eq(#decisions(W, 'stress_extreme'), 0)
  T.eq(package.loaded['dfllm.care'].stress_ids(), {})
end)

T.test('BUG-728: a baby whose mother is dead is reported (orphan_babies), one whose mother lives is not', function()
  local W = world()
  CW.day(W, 1)
  local d = decisions(W, 'orphan_babies')
  T.eq(#d, 1)
  T.eq(d[1].d.n, 1)
  T.ok(d[1].d.q:find('ids 3', 1, true) and not d[1].d.q:find('5', 1, true), d[1].d.q)
  local W2 = world{alive = true}
  CW.day(W2, 1)
  T.eq(#decisions(W2, 'orphan_babies'), 0, 'the mother lives')
end)

T.test('BUG-728 water: the citizens care names at extreme stress leave the Orderlies detail, once a week while they stay so', function()
  local water = require('dfllm.water')
  local calls, logs = {}, 0
  local K = {call = function(mod, fn) if mod == 'care' and fn == 'stress_ids' then return true, {[1] = true, [9] = true} end end,
             act = {work_detail = function(name, id, on) calls[#calls + 1] = {name, id, on}; return true end},
             persist = {touch = function() end}, log = function() logs = logs + 1 end}
  local p = {}
  water.xs_off(K, p, 1000)
  table.sort(calls, function(a, b) return a[2] < b[2] end)
  T.eq(calls, {{'Orderlies', 1, false}, {'Orderlies', 9, false}})
  water.xs_off(K, p, 1000 + 1200)
  T.eq(#calls, 2, 'not again within a week')
  water.xs_off(K, p, 1000 + water.XS_REPEAT)
  T.eq(#calls, 4, 'again after a week')
  K.call = function() return true, {} end
  water.xs_off(K, p, 1000 + 3 * water.XS_REPEAT)
  T.eq(next(p.xo), nil, 'the records of citizens calm for two weeks go')
end)

T.done()
