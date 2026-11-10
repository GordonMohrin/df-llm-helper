-- BUG-662 (Run 16c i3 Wallfree y400-y402, 16a i1 z125, 16b i2 z135): five aqshafts stopped as 'heavy aquifer at z14x (flow 0/7)', each one level
-- lower than the one before: the ring wall of a level that was only heavy by heavy_span was unbuilt for 2 days (no hard stone the builders
-- accept), the stop recorded that level as heavy (X.hv), which made the next level a ring level too. An unbuilt wall without water is a
-- stall (names the material) and after ring_stop a ring stop (AQ_RING_STOP, block ring_wall, no heavy level); water in the ring tile is
-- still the heavy stop; a ring wall that stands drops the ring_wall breach rows. BUG-663: a new shaft after bp.cancel starts clean.
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


local function breaches(W, why)
  local n = 0
  for _, b in ipairs(rt(W).dz or {}) do if b.why == why then n = n + 1 end end
  return n
end

T.test('BUG-662: water in the open ring tile (flow 4/7) while the wall is unbuilt is still the heavy stop, and records the level', function()
  local W = fresh{tag = 'b662flow'}
  know_heavy(W, 99)
  start(W)
  channel(W, ORTH[1], 99)
  H.runs(W, 1)
  T.ok(W.bld_at[key(AX + 1, AY, 99)], 'the wall is designated')
  W.tile(AX + 1, AY, 99).c, W.tile(AX + 1, AY, 99).flow = '~', 5
  H.runs(W, 1)
  T.eq(#ev(W, 'AQ_HEAVY'), 1)
  T.eq(ev(W, 'AQ_HEAVY')[1].d.why, 'flow')
  T.eq(#ev(W, 'AQ_RING_STOP'), 0)
  T.ok(rt(W).hvl and rt(W).hvl[1] == 99, 'a real heavy level is recorded')
end)

T.test('BUG-662: an unbuilt ring wall after ring_wait is a visible stall that names the cause, once', function()
  local W = fresh{tag = 'b662stall'}
  know_heavy(W, 99)
  start(W)
  channel(W, ORTH[1], 99)
  H.runs(W, 12)                                                  -- 6 days
  local n = 0
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.why == 'aq_stall:ring_wall' or e.d.why == 'aq_stall:no_boulders' then n = n + 1 end end
  T.eq(n, 1, T.show(ev(W, 'PROJECT_BLOCKED')))
  T.eq(#ev(W, 'AQ_HEAVY') + #ev(W, 'AQ_RING_STOP'), 0)
  T.ok(AQ.stall_text(rt(W), 'aq'):find('stall z99', 1, true), AQ.stall_text(rt(W), 'aq'))
  T.eq(AQ.stall_key(rt(W), 'aq'), rec(W, 'aq').levels['99'].stall.why)
end)

T.test('BUG-662: a ring wall that stands drops the ring_wall breach rows (the material exists), and the stop notes one', function()
  local W = fresh{tag = 'b662ok'}
  know_heavy(W, 99)
  rt(W).dz[#rt(W).dz + 1] = {pos = {AX + 9, AY, 98}, why = 'ring_wall', proj = 'old1', tpl = 'aqshaft', t = 0}
  rt(W).dz[#rt(W).dz + 1] = {pos = {AX + 9, AY + 3, 97}, why = 'ring_wall', proj = 'old2', tpl = 'aqshaft', t = 0}
  T.eq(breaches(W, 'ring_wall'), 2)
  start(W)
  channel(W, ORTH[1], 99)
  T.ok(until_(W, function() return W.bld_at[key(AX + 1, AY, 99)] ~= nil end, 4))
  H.build(W)
  H.runs(W, 1)
  T.eq(W.tile(AX + 1, AY, 99).c, 'C')
  T.eq(breaches(W, 'ring_wall'), 0, 'a ring wall stood: the old stops are dropped')
  T.eq(#(W.K.manifest().breaches or {}), 1, 'only the fortcore breach is left in the manifest')
end)

T.test('BUG-663: a new aqshaft after bp.cancel of the stalled one starts with a clean record (stall, ring, progress time)', function()
  local W = fresh{tag = 'b663'}
  know_heavy(W, 99)
  start(W)
  W.tile(AX + 1, AY, AT).hidden = true
  H.runs(W, 20)                                                  -- ring waits, stalled
  T.ok(rec(W, 'aq').levels['99'] ~= nil)
  W.inbox('bp.cancel', {proj = 'aq'})
  H.runs(W, 2)
  H.place(W, 'aq2', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 1)
  local r2 = rec(W, 'aq2')
  T.ok(r2 ~= nil and r2.levels['99'] == nil or r2.levels['99'].stall == nil, 'no stall inherited: ' .. T.show(r2 and r2.levels))
  local R2 = rt(W).p['aq2']
  T.ok(R2 and (W.K.now().tick - R2.ps) < 3 * 1200, 'its own progress time starts at its placement')
  local n = 0
  for _, e in ipairs(ev(W, 'PROJECT_BLOCKED')) do if e.d.proj == 'aq2' and e.d.why == 'stalled' then n = n + 1 end end
  T.eq(n, 0, 'no "no progress for N d" at once')
end)

T.done()
