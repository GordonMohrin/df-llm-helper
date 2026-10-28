-- BUG-129 (Run 14, site90): a seal's walls lie far apart (one opening in the west, one in the east, one 26 levels
-- down), and its one box spanned the whole map. runner.boxes now names the clusters of a project's tiles as `parts`
-- (a running project from its stages, a finished seal, plug, repair or explore from the clusters kept with its box), so
-- the audit export reads the walls, not the map between them. `done` marks a kept box (bp.cancel cannot undo it).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local geom = require('dfllm.util.geom')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end

local function boxes(W)
  local r = {}
  for _, e in ipairs(select(2, W.K.call('runner', 'boxes'))) do r[e.id] = e end
  return r
end

-- a seal with three walls far apart: chunks at x 10, x 150 and (x 60, z 74)
local function far_seal()
  local d = H.dig_doc(3, {tpl = 'seal', params = {}, class = 'defense', label = 'dig'})
  d.stages[1].chunks[2].pos = {150, 120, 100}
  d.stages[1].chunks[3].pos = {60, 60, 74}
  return d
end

T.test('BUG-129: geom.clusters groups tiles into boxes (gap), at most max boxes', function()
  local tl = {{10, 10, 100}, {11, 10, 100}, {14, 10, 100}, {150, 120, 100}, {60, 60, 74}, {60, 61, 74}}
  T.eq(geom.clusters(tl, {6, 6, 1}, 8),
       {{10, 10, 100, 14, 10, 100}, {150, 120, 100, 150, 120, 100}, {60, 60, 74, 60, 61, 74}})
  T.eq(geom.clusters(tl, {6, 6, 1}, 2),
       {{10, 10, 100, 150, 120, 100}, {60, 60, 74, 60, 61, 74}}, 'over max: the cheapest pair merged')
  T.eq(geom.clusters({}, {6, 6, 1}, 8), {})
end)

T.test('BUG-129: boxes names the parts of a running seal and keeps them when it is done', function()
  local W = fresh{tag = 'parts'}
  T.ok(H.place(W, 's1', far_seal()).ok)
  T.ok(H.place(W, 'b1', H.dig_doc(1, {tpl = 'bedrooms', params = {}, class = 'living', label = 'dig', x = 30})).ok)
  H.settle(W)
  local e = boxes(W)
  T.eq(e.s1.b, {10, 10, 74, 154, 120, 100})
  T.eq(e.s1.parts, {{10, 10, 100, 14, 10, 100}, {150, 120, 100, 154, 120, 100}, {60, 60, 74, 64, 60, 74}})
  T.eq({e.s1.done, e.b1.parts, e.b1.done}, {nil, nil, nil}, 'one cluster: no parts')
  W.frame(1); H.settle(W)
  for _ = 1, 6 do H.runs(W, 1); H.dig(W) end
  H.runs(W, 4)
  T.eq(H.proj(W, 's1').done, 1)
  e = boxes(W)
  T.eq(e.s1.parts, {{10, 10, 100, 14, 10, 100}, {150, 120, 100, 154, 120, 100}, {60, 60, 74, 64, 60, 74}},
       'kept with its box')
  T.eq(e.s1.done, true)
  T.eq(W.K.persist.get('m.runner').kp.s1, e.s1.parts)
end)

T.done()
