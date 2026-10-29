-- BUG-191, BUG-192, BUG-194 (FR-95 live test 1, instance i4, kernel b805745): the aquifer pass in a live fort.
-- BUG-191: shaft c1a1858c02562d7101 had z128 designated, yielded its runner slot (BUG-037, no progress), the miners dug z128
-- and it flooded (7/7); the level was never noticed (no `opened`, no AQ_HEAVY, no plug for 139+ days): the measure pass
-- returned before dig_step and check_level wants `opened`. Now an aqshaft with an open or designated level keeps its slot,
-- and every pass (measure-only too) notices a dug level read-only and samples its flow.
-- BUG-192: a damp tile found by lost() in a project that already observed was never added to r.pts: never smoothed.
-- BUG-194: dig_step counted a top level on a floor as opened while its `j` job was still pending.
-- Every test fails on 9da84d6.
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
local function rec(W, id) return W.K.persist.get('m.runner').aq[id] end
local function ev(W, t) return W.find_events(t) end
local function row(W, id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end

local AX, AY, AT = 50, 50, 100
local function shaft_doc(depth)
  local stages = {}
  for i = 0, (depth or 4) - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0,
          params = {x = AX, y = AY, top = AT, dry_levels = 2, depth = depth or 4, mode = 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end

-- the live case: the dry top level done, z99 designated, then nobody digs for 8 days while another project waits
local function stalled_shaft(W)
  runner.CFG.active = 1
  H.place(W, 'aq', shaft_doc())
  H.runs(W, 1)
  H.dig(W)                                           -- z100 dug (dry): z99 is designated next
  for _ = 1, 3 do H.runs(W, 1) end
  T.eq(W.tile(AX, AY, 99).dig, 'i', 'z99 designated')
  H.place(W, 'old', H.dig_doc(1, {x = 10}))         -- a project waiting for the one slot
  for _ = 1, 16 do H.runs(W, 1) end                  -- 8 days: the miners never come
end

T.test('BUG-191: an aqshaft with a designated level never yields its slot (no "slot yielded")', function()
  local W = fresh{tag = 'b191hold'}
  stalled_shaft(W)
  T.eq(row(W, 'aq')[4], '', T.show(row(W, 'aq')))
  T.ok(row(W, 'old')[4]:find('queued', 1, true), T.show(row(W, 'old')))
  T.eq(W.tile(10, 10, 100).dig, '', 'the waiting project got no slot')
  T.ok(AQ.holds(W.K.persist.get('m.runner'), 'aq'))
end)

T.test('BUG-191: the designated level the miners dig and that floods is noticed: AQ_HEAVY and the plug', function()
  local W = fresh{tag = 'b191flood'}
  stalled_shaft(W)
  local t = W.tile(AX, AY, 99)
  t.c, t.dig, t.flow = '~', '', 7                    -- dug as a stair, then 7/7 water in it
  for _ = 1, 6 do H.runs(W, 1) end
  T.eq(H.proj(W, 'aq').blocked, 'breach:heavy_aquifer')
  local h = ev(W, 'AQ_HEAVY')
  T.eq(#h, 1)
  T.eq({h[1].d.z, h[1].d.flow, h[1].d.why}, {99, 7, 'flow'})
  T.eq(#ev(W, 'CAVERN_PLUG'), 1)
  T.ok(rec(W, 'aq').levels['99'].opened)
end)

-- a fake host for A.work (what runner's Q.aqx hands it)
local function host(tiles)
  local X = {rt = {aq = {}}, ev = {}, qfn = 0, plugs = 0, t = 5000}
  X.now = function() return X.t end
  X.room, X.dirty, X.flush = function() return true end, function() end, function() end
  X.tile = function(x, y, z) return tiles[x .. ',' .. y .. ',' .. z] end
  X.qf = function() X.qfn = X.qfn + 1; return true, {dig_designated = 1} end
  X.emit = function(t, c, m, d) X.ev[#X.ev + 1] = {type = t, cls = c, d = d} end
  X.log, X.moved, X.level = function() end, function() end, function() end
  X.block = function(P, why) P.blocked = why end
  X.plug = function() X.plugs = X.plugs + 1; return 'pl1' end
  X.mat = function() return 'rock' end
  X.next, X.finish = function(P) P.stage = P.stage + 1 end, function(P) P.done = 1 end
  return X
end

T.test('BUG-191: a measure-only or held pass notices the dug level read-only and stops a heavy aquifer', function()
  for _, how in ipairs({{true, false}, {false, true}}) do
    local X = host{[AX .. ',' .. AY .. ',' .. 99] = {c = '~', dig = '', flow = 7}}
    local P, d = {id = 'aq', tpl = 'aqshaft', stage = 1, blocked = ''}, shaft_doc()
    local r = AQ.shaft(X, P, d)
    r.levels['99'] = {state = 'dig', des = 1, samples = {}, seal_tiles = {}, material = ''}
    T.eq(AQ.work(X, P, d, how[1], how[2]), 'done')
    T.eq(P.blocked, 'breach:heavy_aquifer')
    T.eq({#X.ev, X.ev[1].type, X.ev[1].cls, X.plugs, X.qfn}, {1, 'AQ_HEAVY', 'A', 1, 0}, 'nothing designated')
  end
  -- a dry dug level: opened and sampled, nothing else changes in a measure pass
  local X = host{[AX .. ',' .. AY .. ',' .. 99] = {c = 'X', dig = ''}}
  local P, d = {id = 'aq', tpl = 'aqshaft', stage = 1, blocked = ''}, shaft_doc()
  local r = AQ.shaft(X, P, d)
  r.levels['99'] = {state = 'dig', des = 1, samples = {}, seal_tiles = {}, material = ''}
  AQ.work(X, P, d, true, false)
  local L = r.levels['99']
  T.eq({L.state, L.opened, L.samples, X.qfn, P.blocked}, {'dig', 5000, {0}, 0, ''})
  -- still a wall (not dug yet): not opened
  X = host{[AX .. ',' .. AY .. ',' .. 99] = {c = '#', dig = 'i'}}
  r = AQ.shaft(X, P, d)
  r.levels['99'] = {state = 'dig', des = 1, samples = {}, seal_tiles = {}, material = ''}
  AQ.work(X, P, d, true, false)
  T.eq({r.levels['99'].opened, #r.levels['99'].samples}, {nil, 0})
end)

T.test('BUG-194: a top level on a floor is not opened while its dig job is pending', function()
  local W = fresh{tag = 'b194'}
  H.place(W, 'aq', shaft_doc())
  H.runs(W, 1)
  local t = W.tile(AX, AY, AT)
  T.eq(t.dig, 'j')
  t.c = '.'                                          -- a floor with the down stair still to dig
  H.runs(W, 3)
  T.eq(rec(W, 'aq').levels['100'].opened, nil)
  T.eq(W.tile(AX, AY, 99).dig, '', 'the next level waits for the top stair')
  T.eq(rec(W, 'aq').levels['100'].state, 'dig')
  H.dig(W)
  local ok = false
  for _ = 1, 3 do
    H.runs(W, 1)
    if W.tile(AX, AY, 99).dig == 'i' then ok = true; break end
  end
  T.ok(ok, 'dug: the next level opens')
end)

T.test('BUG-192: a damp tile lost() finds in a project that already observes is smoothed around too', function()
  local W = fresh{tag = 'b192'}
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = 12, y = 10, z = 100}})
  W.frame(1)
  T.eq(#ev(W, 'AQ_OBSERVE'), 1)
  W.tile(14, 10, 100).dig = ''                       -- DF cancelled another damp tile, no report found for it
  H.runs(W, 1)
  T.eq(W.tile(14, 10, 100).dig, 'd', 'designated again with the damp marker')
  local pts = {}
  for _, p in ipairs(rec(W, 'c1').pts) do pts[#pts + 1] = p[1] .. ',' .. p[2] .. ',' .. p[3] end
  T.eq(pts, {'12,10,100', '14,10,100'})
  T.eq(#ev(W, 'AQ_OBSERVE'), 1, 'no second AQ_OBSERVE')
  H.dig(W)
  H.runs(W, 3)
  T.eq(W.tile(14, 9, 100).dig, 's', 'the wall beside the second damp tile is smoothed')
  T.eq(W.tile(15, 10, 100).dig, 's')
end)

T.done()
