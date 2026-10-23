-- BUG-064 (Run 13/14 notes 43 and 55: bridges, levers and workshops vanished in PEACE; the kernel said BRIDGE_DESTROYED
-- '0 building destroyers' while DF's reports said "X toppled by <dwarf>": stressed citizens in a tantrum, a ghost):
-- gate names the culprit care found for a bridge that vanished. Fails on f17e2b3 (no tby, no text).
local T = require('testlib')
local SW = require('seal_world')

local G = 9
local FP = {20, 25, G, 20, 25, G}
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = FP, levers = {{25, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}

local function run(W, n) W.run(n, {skip = 9}) end

local function fort(care)
  local W = SW.new{persist = {manifest = MAN}}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'.'}, 20, 25)
  W.o1 = SW.bridge(W, FP, false, 'O1')
  W.lv = SW.lever(W, 25, 22, G, W.o1)
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.load(SW.fake('reflex', {holding = function() return nil end}))
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  if care then W.load(care) end
  package.loaded['dfllm.gate'] = nil
  W.load(require('dfllm.gate'))
  return W
end

local function destroy(W)
  local b = W.o1
  W.buildings[b.id] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
  SW.draw(W, G, {'.'}, 20, 25)
  W.o1 = nil
  SW.regroup(W)
end

T.test('BRIDGE_DESTROYED names the dwarf the reports blamed (care.toppled) instead of leaving "0 building destroyers"', function()
  local asked
  local W = fort(SW.fake('care', {toppled = function(K, x, y, z)
    asked = {x, y, z}
    return {by = 'Kel Becordastot', unit = 77, ghost = 0, cat = 0, stress = 61000, what = 'Bridge', t = 1}
  end}))
  run(W, 300)
  destroy(W)
  run(W, 2600)
  local e = W.find_events('BRIDGE_DESTROYED')
  T.eq(#e, 1)
  T.eq(asked, {20, 25, G})
  T.ok(e[1].msg:find('O1 destroyed (toppled by Kel Becordastot, stress category 0): no bridge on its footprint', 1, true), e[1].msg)
  T.eq({e[1].d.destroyers, e[1].d.bd, e[1].d.tby, e[1].d.tunit, e[1].d.tcat, e[1].d.tghost}, {0, 0, 'Kel Becordastot', 77, 0, nil})
  T.ok(#e[1].msg <= 200)
end)

T.test('a ghost is named as one; without care, or when care saw nobody, the text is the old one', function()
  local W = fort(SW.fake('care', {toppled = function() return {by = 'Ghostly Mason', unit = -1, ghost = 1} end}))
  run(W, 300)
  destroy(W)
  run(W, 2600)
  local e = W.find_events('BRIDGE_DESTROYED')[1]
  T.ok(e.msg:find('(toppled by Ghostly Mason, a ghost)', 1, true), e.msg)
  T.eq({e.d.tby, e.d.tunit, e.d.tghost}, {'Ghostly Mason', nil, 1})
  local W2 = fort()
  run(W2, 300)
  destroy(W2)
  run(W2, 2600)
  local e2 = W2.find_events('BRIDGE_DESTROYED')[1]
  T.ok(e2.msg:find('O1 destroyed: no bridge on its footprint', 1, true) and e2.d.tby == nil, e2.msg)
  local W3 = fort(SW.fake('care', {toppled = function() return nil end}))
  run(W3, 300)
  destroy(W3)
  run(W3, 2600)
  T.eq(W3.find_events('BRIDGE_DESTROYED')[1].d.tby, nil)
end)

T.done()
