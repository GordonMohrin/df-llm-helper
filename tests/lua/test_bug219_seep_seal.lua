-- BUG-219 (live round 4): observe mode smoothed only the walls beside the reported damp tile. DF reports damp for a
-- tile with an aquifer neighbour (diagonals too); the tiles dug after the report sat beside rough aquifer walls no
-- report named and seeped (AQ_SEEP 'seepage 1/7 at 46,67,124', 45,67 and 47,67 still rough). Now A.wet adds a newly
-- wet own tile to r.pts (dedupe, at most obs_pts), so A.tick smooths its rough stone walls too.
-- Every test fails on 5e9e719.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function pts(r)
  local out = {}
  for _, p in ipairs(r.pts) do out[#out + 1] = p[1] .. ',' .. p[2] .. ',' .. p[3] end
  return out
end

T.test('BUG-219: a later dug tile that seeps is smoothed around too, not only the reported damp tile', function()
  local W = fresh{tag = 'b219'}
  H.place(W, 'c1', H.dig_doc(1))                     -- 10..14,10,100
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = 11, y = 10, z = 100}})
  W.frame(1)
  T.eq(#W.find_events('AQ_OBSERVE'), 1)
  H.dig(W)
  local t = W.tile(14, 10, 100)
  t.c, t.flow = 'w', 1                               -- 1/7 seepage on a tile no report named
  H.runs(W, 3)
  T.eq(#W.find_events('AQ_SEEP'), 1)
  T.eq(W.tile(11, 9, 100).dig, 's', 'the reported damp tile is sealed as before')
  T.eq(W.tile(14, 9, 100).dig, 's', 'the wall beside the seeping tile is smoothed')
  T.eq(W.tile(14, 11, 100).dig, 's')
  T.eq(W.tile(15, 10, 100).dig, 's')
  T.eq(W.tile(13, 10, 100).dig, '', 'an own tile is never smoothed')
end)

-- a fake host for A.wet / A.tick
local function host(tiles)
  local X = {rt = {aq = {}}, ev = {}, qf_calls = {}, t = 5000}
  X.now = function() return X.t end
  X.dirty, X.level, X.log = function() end, function() end, function() end
  X.tile = function(x, y, z) return tiles[x .. ',' .. y .. ',' .. z] end
  X.emit = function(t, c, m, d) X.ev[#X.ev + 1] = {type = t, cls = c, d = d} end
  X.own = function() return {['20,20,90'] = true} end
  X.live = function() return true end
  X.qf = function(o) X.qf_calls[#X.qf_calls + 1] = o; return true end
  return X
end

T.test('BUG-219: A.wet adds a wet tile once (dedupe), keeps obs_pts and leaves a report point alone', function()
  local tiles = {['20,20,90'] = {c = 'w', dig = ''}, ['21,20,90'] = {c = '#', dig = ''},
                 ['19,20,90'] = {c = '#', dig = ''}, ['20,19,90'] = {c = '#', dig = '', soilmat = true}}
  local X = host(tiles)
  local P = {id = 'c9', tpl = 'fortcore'}
  T.ok(AQ.observe(X, P, {30, 30, 90}, 'report'))
  AQ.wet(X, P, {20, 20, 90, 'd'}, 1)
  AQ.wet(X, P, {20, 20, 90, 'd'}, 1)                 -- a second sample of the same tile
  AQ.wet(X, P, {30, 30, 90, 'd'}, 1)                 -- the reported tile seeps too: no duplicate
  local r = X.rt.aq.c9
  T.eq(pts(r), {'30,30,90', '20,20,90'})
  T.eq(#X.ev, 3, 'AQ_OBSERVE + one AQ_SEEP per new wet tile')
  AQ.tick(X)
  T.eq(#X.qf_calls, 1, 'one quickfort call: the seeping tile (the report tile is not revealed here)')
  local d = X.qf_calls[1].data[0]
  T.eq({X.qf_calls[1].pos, d[0][1], d[0][-1], d[-1]}, {{20, 20, 90}, 's', 's', nil}, 'stone walls smoothed, soil wall left')
  T.eq(r.pts[2][4], 'soil')
  -- the cap: a full r.pts takes no more wet tiles
  AQ.CFG.obs_pts = 2
  AQ.wet(X, P, {40, 40, 90, 'd'}, 1)
  T.eq(#r.pts, 2)
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
end)

T.done()
