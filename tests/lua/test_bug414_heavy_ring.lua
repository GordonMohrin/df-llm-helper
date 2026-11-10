-- BUG-414 (Gordon 04.11.2026: every fort under the aquifer, a heavy layer too): a level known to be heavy is not opened by a
-- miner standing in it. Its 4 side tiles are walled from ABOVE first (channel on the dry level, a constructed wall on the open
-- ramp), one tile at a time; only then is the shaft tile dug. Water above, a wall not built in time, a thick layer: contained.
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
local function rt(W) return W.K.persist.get('m.runner') end
local function rec(W, id) return rt(W).aq[id] end
local function ev(W, t) return W.find_events(t) end
local function until_(W, fn, max)
  for _ = 1, max or 20 do
    if fn() then return true end
    H.runs(W, 1)
  end
  return fn()
end

local AX, AY, AT = 50, 50, 100
local function shaft_doc(depth, dry, extra)
  local stages = {}
  for i = 0, depth - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  local params = {x = AX, y = AY, top = AT, dry_levels = dry or 2, depth = depth, mode = 'auto'}
  for k, v in pairs(extra or {}) do params[k] = v end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0, params = params,
          stages = stages, manifest = {v = 2}, materials = {}}
end
local ORTH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function key(x, y, z) return x .. ',' .. y .. ',' .. z end
-- a breach heavy_aquifer record (a fortcore that stopped there) makes z99 and its neighbours heavy-known
local function know_heavy(W, z)
  rt(W).dz = {{pos = {AX + 20, AY, z}, why = 'heavy_aquifer', proj = 'oldcore', tpl = 'fortcore', t = 0}}
end
local function tops_designated(W, z)
  local n = 0
  for _, o in ipairs(ORTH) do if W.tile(AX + o[1], AY + o[2], z + 1).dig ~= '' then n = n + 1 end end
  return n
end
local function start(W, depth)
  H.place(W, 'aq', shaft_doc(depth or 5))
  H.runs(W, 1)
  H.dig(W)                                         -- z100 (the top stair) is dug
  until_(W, function() return rec(W, 'aq').levels['99'] ~= nil end, 6)
  H.runs(W, 1)
end
-- the miner channels the ring top of piece o and DF leaves an open ramp in the heavy level below it
local function channel(W, o, z)
  T.eq(W.tile(AX + o[1], AY + o[2], z + 1).dig, 'h', 'channel designated on the dry level above')
  H.dig(W)
  W.tile(AX + o[1], AY + o[2], z).c = '_'
end

T.test('BUG-414 ring: a known heavy level is walled from above, one tile at a time, before the shaft tile is dug', function()
  local W = fresh{tag = 'b414ring'}
  know_heavy(W, 99)
  start(W)
  T.eq(tops_designated(W, 99), 1, 'one ring tile at a time')
  T.eq(W.tile(AX, AY, 99).dig, '', 'the shaft tile is not designated')
  for _, o in ipairs(ORTH) do T.eq(W.tile(AX + o[1], AY + o[2], 99).dig, '', 'no wall of the heavy level is smoothed') end
  for i, o in ipairs(ORTH) do
    T.eq(tops_designated(W, 99), 1)
    channel(W, o, 99)
    T.ok(until_(W, function() return W.bld_at[key(AX + o[1], AY + o[2], 99)] ~= nil end, 4), 'wall designated on the ramp ' .. i)
    T.eq(W.tile(AX, AY, 99).dig, '', 'the shaft tile waits for the ring')
    H.build(W)
    H.runs(W, 1)
    T.eq(W.tile(AX + o[1], AY + o[2], 99).c, 'C')
  end
  T.ok(until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 4), 'all 4 stand: the shaft tile is designated')
  T.eq(rec(W, 'aq').levels['99'].ring.done, 1)
  H.dig(W)
  T.ok(until_(W, function() return #ev(W, 'AQ_LEVEL_SEALED') == 1 end, 6), 'the dug level is sealed at once (4 walls stand)')
  local e = ev(W, 'AQ_LEVEL_SEALED')[1]
  T.eq({e.d.how, e.d.n}, {'ring', 4})
  T.eq(#ev(W, 'AQ_HEAVY'), 0)
end)

T.test('BUG-414 ring: a level that is not known heavy keeps the usual method (no ring, the pre-ring with the dig)', function()
  local W = fresh{tag = 'b414plain'}
  for _, o in ipairs(ORTH) do W.tile(AX + o[1], AY + o[2], 99).aq = true end
  start(W, 4)
  T.eq(W.tile(AX, AY, 99).dig, 'i')
  T.eq(rec(W, 'aq').levels['99'].ring, nil)
  T.eq(tops_designated(W, 99), 0)
end)

T.test('BUG-414 ring: p.heavy = off keeps the usual method on a known heavy level', function()
  local W = fresh{tag = 'b414off'}
  know_heavy(W, 99)
  H.place(W, 'aq', shaft_doc(4, 2, {heavy = 'off'}))
  H.runs(W, 1)
  H.dig(W)
  until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 6)
  T.eq(W.tile(AX, AY, 99).dig, 'i')
  T.eq(rec(W, 'aq').levels['99'].ring, nil)
end)

T.test('BUG-414 ring: p.heavy = all rings every level below the top', function()
  local W = fresh{tag = 'b414all'}
  H.place(W, 'aq', shaft_doc(4, 2, {heavy = 'all'}))
  H.runs(W, 1)
  H.dig(W)
  until_(W, function() return rec(W, 'aq').levels['99'] ~= nil end, 6)
  H.runs(W, 1)
  T.eq(W.tile(AX, AY, 99).dig, '')
  T.eq(tops_designated(W, 99), 1)
end)

T.test('BUG-414 safety: water on the dry level above while a ring tile is open stops the shaft and plugs it', function()
  local W = fresh{tag = 'b414leak'}
  know_heavy(W, 99)
  start(W)
  channel(W, ORTH[1], 99)
  H.runs(W, 1)
  T.ok(W.bld_at[key(AX + 1, AY, 99)], 'the wall is designated')
  W.tile(AX, AY, 100).c, W.tile(AX, AY, 100).flow = 'w', 2               -- the heavy level climbed out of its ring tile
  H.runs(W, 1)
  T.eq(#ev(W, 'AQ_HEAVY'), 1)
  T.eq(ev(W, 'AQ_HEAVY')[1].d.why, 'ring_leak')
  T.ok(rec(W, 'aq').heavy, 'stopped for good')
  T.eq(W.tile(AX, AY, 99).dig, '', 'the shaft tile is never designated')
  T.ok(rt(W).hvl and rt(W).hvl[1] == 99, 'the level is recorded heavy')
end)

T.test('BUG-414/662 safety: a ring wall that nobody builds is a stall after ring_wait, a ring stop (not heavy) after ring_stop', function()
  local W = fresh{tag = 'b414late'}
  know_heavy(W, 99)
  start(W)
  channel(W, ORTH[1], 99)
  H.runs(W, 1)
  T.ok(W.bld_at[key(AX + 1, AY, 99)], 'the wall is designated, nobody builds')
  H.runs(W, 3)
  T.eq(#ev(W, 'AQ_HEAVY'), 0, 'not yet: ring_wait is 2 days')
  H.runs(W, 3)
  T.eq(#ev(W, 'AQ_HEAVY'), 0, 'BUG-662: no water, so never a heavy aquifer')
  T.eq(#ev(W, 'AQ_RING_STOP'), 0, 'a stall first: ring_stop is 30 days')
  T.eq(W.tile(AX, AY, 99).dig, '')
  local hv = rt(W).hvl and #rt(W).hvl or 0
  T.eq(hv, 0, 'no heavy level is recorded for an unbuilt wall')
  H.runs(W, 70)                                                  -- 35 days
  T.eq(#ev(W, 'AQ_HEAVY'), 0)
  T.eq(#ev(W, 'AQ_RING_STOP'), 1)
  T.eq(ev(W, 'AQ_RING_STOP')[1].d.why, 'ring_late')
  T.eq(H.proj(W, 'aq').blocked, 'ring_wall')
  T.eq(rt(W).hvl and #rt(W).hvl or 0, 0, 'still no heavy level (the next shaft is not pushed one level lower)')
  local rw = 0
  for _, b in ipairs(rt(W).dz or {}) do if b.why == 'ring_wall' then rw = rw + 1 end end
  T.eq(rw, 1, 'the stop is a manifest breach ring_wall')
end)

T.test('BUG-414 safety: a channel quickfort refuses stops the shaft (apply_fail) with nothing open', function()
  local W = fresh{tag = 'b414refuse'}
  know_heavy(W, 99)
  W.no_channel = {[key(AX + 1, AY, 100)] = true}
  start(W)
  H.runs(W, 4)
  T.eq(W.tile(AX + 1, AY, 100).dig, '')
  T.eq(W.tile(AX, AY, 99).dig, '')
  local P = H.proj(W, 'aq')
  T.ok(P.blocked == 'apply_fail', P.blocked)
end)

T.test('BUG-414 stall: nobody channels the ring tile: said once, with the command', function()
  local W = fresh{tag = 'b414stall'}
  know_heavy(W, 99)
  start(W)
  H.runs(W, 8)                                     -- 4 days, nobody digs
  local b = {}
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why:find('^aq_stall') then b[#b + 1] = e end end
  T.eq(#b, 1)
  T.eq(b[1].d.why, 'aq_stall:ring_dig')
  T.ok(b[1].d.cmd:find('inspect', 1, true))
  T.eq(#ev(W, 'AQ_HEAVY'), 0, 'a channel not dug yet is no danger: nothing is open')
end)

T.test('BUG-414 thick layer: a known heavy level under a ringed one stops before it is opened', function()
  local W = fresh{tag = 'b414thick'}
  know_heavy(W, 98)                                -- z98 and z99 and z97 are heavy-known (span 1)
  start(W, 6)
  for i, o in ipairs(ORTH) do
    channel(W, o, 99)
    H.runs(W, 1)
    H.build(W)
    H.runs(W, 1)
  end
  T.ok(until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 6))
  H.dig(W)
  -- sealed at once; the next level z98 is exactly the recorded one and its ring tops are constructed walls
  T.ok(until_(W, function() return #ev(W, 'AQ_HEAVY') == 1 end, 12), 'stopped before opening z98')
  local e = ev(W, 'AQ_HEAVY')[1]
  T.eq({e.d.why, e.d.z}, {'stacked', 98})
  T.eq(W.tile(AX, AY, 98).dig, '', 'nothing opened')
  T.ok(rec(W, 'aq').heavy)
end)

T.test('BUG-414 runner: a heavy stop records its level for the next shaft (m.runner hvl)', function()
  local W = fresh{tag = 'b414hvl'}
  H.place(W, 'aq', shaft_doc(4))
  H.runs(W, 1)
  H.dig(W)
  until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 6)
  H.dig(W)                                         -- z99 dug, the usual method
  W.tile(AX, AY, 99).c, W.tile(AX, AY, 99).flow = '~', 7
  H.runs(W, 2)
  T.eq(#ev(W, 'AQ_HEAVY'), 1)
  T.ok(rt(W).hvl and rt(W).hvl[1] == 99, T.show(rt(W).hvl))
  local W2 = fresh{tag = 'b414hvl2'}
  rt(W2).hvl = {99}
  start(W2)
  T.eq(tops_designated(W2, 99), 1, 'the next shaft rings z99')
  T.eq(tops_designated(W2, 98), 0)
end)

T.done()
