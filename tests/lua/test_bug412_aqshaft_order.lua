-- BUG-412 (Gordon 04.11.2026: "ich moechte generell dass durch aquifier gegraben wird, so sicher wie moeglich"): the per-level
-- method of the aquifer shaft. Order: only the level's shaft tile is dug; the seal of a level that looks like an aquifer is
-- designated WITH the dig (the pre-ring: stone walls smoothed, soil arms dug), the next level only after every side tile stands
-- sealed and the flow was watched; a shaft that cannot go on says why (plug stone missing, no mason, nobody reaches it).
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
local function until_(W, fn, max)
  for _ = 1, max or 20 do
    if fn() then return true end
    H.runs(W, 1)
  end
  return fn()
end

local AX, AY, AT = 50, 50, 100
local function shaft_doc(depth, dry)
  local stages = {}
  for i = 0, depth - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0,
          params = {x = AX, y = AY, top = AT, dry_levels = dry or 2, depth = depth, mode = 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end
local ORTH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function aquifer_level(W, z, soil)
  for _, o in ipairs(ORTH) do
    W.tile(AX + o[1], AY + o[2], z).aq = true
    if soil then W.soil[(AX + o[1]) .. ',' .. (AY + o[2]) .. ',' .. z] = true end
  end
end
local function ring_dig(W, z) local n = 0; for _, o in ipairs(ORTH) do if W.tile(AX + o[1], AY + o[2], z).dig ~= '' then n = n + 1 end end; return n end

T.test('BUG-412 order: pre-ring with the dig, one level open, the next only after seal + watch', function()
  local W = fresh{tag = 'b412order'}
  aquifer_level(W, 99)
  H.place(W, 'aq', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)                                         -- z100 (the top stair) is dug: dry
  T.ok(until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 4), 'z99 designated')
  T.eq(ring_dig(W, 99), 4, 'the 4 side walls of the aquifer level are designated WITH its dig (pre-ring)')
  for _, o in ipairs(ORTH) do T.eq(W.tile(AX + o[1], AY + o[2], 99).dig, 's') end
  T.eq(rec(W, 'aq').levels['99'].pre, 1)
  T.eq(W.tile(AX, AY, 98).dig, '', 'nothing is designated one level deeper')
  H.runs(W, 2)
  T.eq(W.tile(AX, AY, 98).dig, '', 'still not, while the tile is not dug')
  H.dig(W)                                         -- the miner opens z99 and smooths the walls
  T.ok(until_(W, function() return #ev(W, 'AQ_LEVEL_SEALED') == 1 end, 4), 'sealed')
  T.eq(ev(W, 'AQ_LEVEL_SEALED')[1].d.n, 4)
  T.eq(W.tile(AX, AY, 98).dig, '', 'watched for a day before the next level')
  T.ok(until_(W, function() return W.tile(AX, AY, 98).dig == 'i' end, 6), 'then z98')
  T.eq(rec(W, 'aq').levels['99'].state, 'passed')
end)

T.test('BUG-412 order: soil arms are designated with the dig and walled before the next level', function()
  local W = fresh{tag = 'b412soil'}
  aquifer_level(W, 100, true)
  H.place(W, 'aq', shaft_doc(3, 1))
  H.runs(W, 1)
  for _, o in ipairs(ORTH) do T.eq(W.tile(AX + o[1], AY + o[2], 100).dig, 'd', 'arm designated with the top dig') end
  H.dig(W)
  H.runs(W, 1)
  T.eq(rec(W, 'aq').levels['100'].state, 'seal')
  for _, o in ipairs(ORTH) do T.ok(W.bld_at[(AX + o[1]) .. ',' .. (AY + o[2]) .. ',100'], 'a wall is placed on each arm') end
  T.eq(W.tile(AX, AY, 99).dig, '', 'no next level before the walls stand')
  H.build(W)
  T.ok(until_(W, function() return #ev(W, 'AQ_LEVEL_SEALED') == 1 end, 4))
end)

T.test('BUG-412 stall: no wall material for the plug holds the shaft below its top, once, with the command', function()
  local W = fresh{tag = 'b412stone'}
  local mat = {nil, "no rock, no mason's workshop"}
  W.load{name = 'economy', every = {ticks = 1200}, mat_for = function() return mat[1], mat[2] end}
  H.place(W, 'aq', shaft_doc(4))
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 3)
  T.eq(W.tile(AX, AY, 99).dig, '', 'z99 is not designated without a plug reserve')
  local b = {}
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why:find('^aq_stall') then b[#b + 1] = e end end
  T.eq(#b, 1, 'announced once')
  T.eq({b[1].cls, b[1].d.proj, b[1].d.tpl, b[1].d.why}, {'A', 'aq', 'aqshaft', 'aq_stall:no_mason'})
  T.ok(b[1].d.cmd and b[1].d.cmd:find('inspect', 1, true), 'a command')
  T.ok(row(W, 'aq')[4]:find('^stall z99: no mason'), T.show(row(W, 'aq')))
  H.runs(W, 4)
  local n = 0
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why:find('^aq_stall') then n = n + 1 end end
  T.eq(n, 1, 'no repeat')
  mat[1], mat[2] = 'rock', nil
  T.ok(until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 4), 'the stall lifts when walls can be made')
  T.eq(row(W, 'aq')[4], '')
end)

T.test('BUG-412 stall: a soil seal whose walls nobody builds says no_mason after the stall time', function()
  local W = fresh{tag = 'b412mason'}
  aquifer_level(W, 100, true)
  H.place(W, 'aq', shaft_doc(3, 1))
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 1)                                     -- arms dug, walls placed, nobody builds
  H.dig(W)
  H.runs(W, 8)                                     -- 4 game days
  local b = {}
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why:find('^aq_stall') then b[#b + 1] = e end end
  T.eq(#b, 1)
  T.eq(b[1].d.why, 'aq_stall:no_mason')
  T.ok(row(W, 'aq')[4]:find('stall z100', 1, true), T.show(row(W, 'aq')))
  H.build(W)
  T.ok(until_(W, function() return rec(W, 'aq').levels['100'].state == 'watch' end, 4), 'the seal completes')
  T.eq(rec(W, 'aq').levels['100'].stall, nil, 'the stall is gone')
end)

T.test('BUG-412 stall: smoothing nobody does says no_smoother', function()
  local W = fresh{tag = 'b412smooth'}
  aquifer_level(W, 100)
  H.place(W, 'aq', shaft_doc(3, 1))
  H.runs(W, 1)
  W.tile(AX, AY, 100).c, W.tile(AX, AY, 100).dig = '.', ''     -- only the top is dug, the walls stay rough
  H.runs(W, 8)
  local b = {}
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why:find('^aq_stall') then b[#b + 1] = e end end
  T.eq(#b, 1)
  T.eq(b[1].d.why, 'aq_stall:no_smoother')
end)

T.test('BUG-412 stall: a designated level nobody reaches says unreachable', function()
  local W = H.world{tag = 'b412reach', census = {u = {cit = 2, adults = 2, ids = {1, 2}}}}
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  for _, x in ipairs({8, 9}) do W.tile(x, 10, 100).c, W.tile(x, 10, 100).g = '.', 1562 end
  W.add_unit{id = 1, citizen = true, pos = {8, 10, 100}}
  W.add_unit{id = 2, citizen = true, pos = {9, 10, 100}}
  W.tile(AX, AY, AT).c, W.tile(AX, AY, AT).g = '#', 1
  W.load(runner)
  W.state()
  H.place(W, 'aq', shaft_doc(3, 1))
  H.runs(W, 12)                                    -- 6 game days, nobody digs
  local b = {}
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why == 'aq_stall:unreachable' then b[#b + 1] = e end end
  T.eq(#b, 1, 'unreachable announced once by the shaft itself')
  T.ok(b[1].d.cmd:find('bp.cancel proj=aq', 1, true), b[1].d.cmd)
end)

T.done()
