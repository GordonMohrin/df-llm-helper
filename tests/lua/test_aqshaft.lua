-- FR-95 (Run 2/4/6/9/14: every fort that met an aquifer parked at breach:damp or flooded): the aquifer pass.
-- tpl aqshaft = a lined shaft, one level at a time: DIG (the damp marker on) -> SEAL (stone: the 4 orthogonal walls
-- smoothed, priority 1; soil: a plus shape dug and constructed walls on its 4 arms) -> WATCH (the centre tile's flow for
-- one game day); the next level only once the seal stands and the flow is <= 1. A flow >= 4/7 or a rising flow in our
-- own dug tiles is a heavy aquifer: the project stops for good (breach:heavy_aquifer), the shaft is plugged
-- (CAVERN_PLUG), AQ_HEAVY (A). A damp report on any other dig starts OBSERVE mode instead of a permanent park.
-- The aquifer flag is read on revealed tiles only (snapshot.tile `aq`; hidden tiles answer nil).
-- k_mock + runner_world (fake quickfort, snapshot.tile with aq/soilmat, dwarf simulators).
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
local function last_dig(W, x, y, z)
  local out
  for _, c in ipairs(H.qf_calls(W, 'dig')) do
    if c.pos and c.pos[1] == x and c.pos[2] == y and c.pos[3] == z then out = c end
  end
  return out
end
local function cell(c) return c and c.data[0] and c.data[0][0] and c.data[0][0][0] end
-- run until fn() is true (at most max runs)
local function until_(W, fn, max)
  for _ = 1, max or 20 do
    if fn() then return true end
    H.runs(W, 1)
  end
  return fn()
end

-- the aqshaft document as dfpilot/bp emits it (tests/test_fr95_aquifer.py pins the Python side)
local AX, AY, AT = 50, 50, 100
local function shaft_doc(o)
  o = o or {}
  local depth = o.depth or 6
  local stages = {}
  for i = 0, depth - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0,
          params = {x = AX, y = AY, top = AT, dry_levels = o.dry or 2, depth = depth, mode = o.mode or 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end
local ORTH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function aquifer_level(W, z, soil)
  for _, o in ipairs(ORTH) do
    W.tile(AX + o[1], AY + o[2], z).aq = true
    if soil then W.soil[(AX + o[1]) .. ',' .. (AY + o[2]) .. ',' .. z] = true end
  end
end

T.test('light aquifer in stone: dig with the damp marker, smooth the 4 walls, watch a day, pass after 2 dry levels', function()
  local W = fresh{tag = 'aqstone'}
  aquifer_level(W, 99)
  H.place(W, 'aq1', shaft_doc())
  H.runs(W, 1)
  local c0 = last_dig(W, AX, AY, AT)
  T.ok(c0, 'the top level is designated')
  T.eq({cell(c0), c0.marker}, {'j', {damp = true}})
  T.eq(W.tile(AX, AY, 99).dig, '', 'one level open at a time: z99 waits for z100')
  H.dig(W)
  T.ok(until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 3), 'the dry top level leads on to z99')
  T.eq(rec(W, 'aq1').levels['100'].state, 'dry')
  H.dig(W)
  H.runs(W, 1)
  local L = rec(W, 'aq1').levels['99']
  T.eq({L.state, L.material}, {'seal', 'stone'})
  for _, o in ipairs(ORTH) do T.eq(W.tile(AX + o[1], AY + o[2], 99).dig, 's', 'smoothing designated') end
  local sm = last_dig(W, AX, AY, 99)                -- one quickfort call for the 4 walls, relative to the centre
  T.eq({sm.priority, sm.data[0][0][1], sm.data[0][0][-1], sm.data[0][1][0], sm.data[0][-1][0]}, {1, 's', 's', 's', 's'},
       'the seal digs at priority 1')
  H.runs(W, 2)
  T.eq(W.tile(AX, AY, 98).dig, '', 'no next level while the seal is open')
  T.eq(H.proj(W, 'aq1').blocked, '', 'sealing is progress, never blocked')
  H.dig(W)                                           -- the engravers smooth the 4 walls
  T.ok(until_(W, function() return #ev(W, 'AQ_LEVEL_SEALED') == 1 end, 3), 'AQ_LEVEL_SEALED')
  local s = ev(W, 'AQ_LEVEL_SEALED')[1]
  T.eq({s.cls, s.d.proj, s.d.z, s.d.how, s.d.n}, {'B', 'aq1', 99, 'stone', 4})
  T.eq(rec(W, 'aq1').levels['99'].state, 'watch')
  H.runs(W, 1)
  T.eq(W.tile(AX, AY, 98).dig, '', 'the watch holds the next level for a day')
  T.ok(until_(W, function() return W.tile(AX, AY, 98).dig == 'i' end, 4), 'after a dry day the next level opens')
  local L99 = rec(W, 'aq1').levels['99']
  T.eq(L99.state, 'passed')
  T.ok(#L99.samples >= 2, T.show(L99.samples))
  T.eq(W.K.manifest().aquifer_levels, {99})
  H.dig(W)
  T.ok(until_(W, function() return W.tile(AX, AY, 97).dig == 'i' end, 3))
  H.dig(W)
  T.ok(until_(W, function() return #ev(W, 'AQ_PASS_DONE') == 1 end, 3), 'two dry levels below the aquifer: passed')
  local p = ev(W, 'AQ_PASS_DONE')[1]
  T.eq({p.d.proj, p.d.top, p.d.bot, p.d.lv}, {'aq1', 100, 97, {99}})
  T.eq(H.proj(W, 'aq1').done, 1)
  T.eq(W.tile(AX, AY, 96).dig, '', 'nothing dug below the pass')
  T.eq(#ev(W, 'BREACH_STOP'), 0)
  for _, t in ipairs({'AQ_LEVEL_SEALED', 'AQ_PASS_DONE'}) do
    for _, e in ipairs(ev(W, t)) do T.ok(#require('dfllm.util.json').encode(e.d) < 200, t .. ' d < 200 bytes') end
  end
end)

T.test('soil walls: a plus shape is dug and constructed walls go on the 4 arms', function()
  local W = fresh{tag = 'aqsoil'}
  aquifer_level(W, 100, true)
  H.place(W, 'aq2', shaft_doc{depth = 3, dry = 1})
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 1)
  local L = rec(W, 'aq2').levels['100']
  T.eq({L.state, L.material}, {'seal', 'soil'})
  for _, o in ipairs(ORTH) do T.eq(W.tile(AX + o[1], AY + o[2], 100).dig, 'd', 'the arm is dug') end
  local arm = last_dig(W, AX, AY, 100)
  T.eq({arm.data[0][0][1], arm.marker}, {'d', {damp = true}})
  H.dig(W)
  H.runs(W, 1)
  for _, o in ipairs(ORTH) do T.ok(W.bld_at[(AX + o[1]) .. ',' .. (AY + o[2]) .. ',100'], 'a wall is placed on each arm') end
  T.eq(#ev(W, 'AQ_LEVEL_SEALED'), 0)
  H.build(W)
  T.ok(until_(W, function() return #ev(W, 'AQ_LEVEL_SEALED') == 1 end, 3))
  T.eq(ev(W, 'AQ_LEVEL_SEALED')[1].d.how, 'soil')
  T.ok(until_(W, function() return W.tile(AX, AY, 99).dig == 'i' end, 4))
  H.dig(W)
  T.ok(until_(W, function() return H.proj(W, 'aq2').done == 1 end, 4))
  T.eq(ev(W, 'AQ_PASS_DONE')[1].d.lv, {100})
end)

T.test('heavy aquifer: 7/7 in the shaft stops it for good, plugs it, AQ_HEAVY (A)', function()
  local W = fresh{tag = 'aqheavy'}
  aquifer_level(W, 100)
  H.place(W, 'aq3', shaft_doc{depth = 4})
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 1)
  local t = W.tile(AX, AY, 100)
  t.c, t.flow = '~', 7
  H.runs(W, 1)
  local P = H.proj(W, 'aq3')
  T.eq(P.blocked, 'breach:heavy_aquifer')
  local h = ev(W, 'AQ_HEAVY')
  T.eq(#h, 1)
  T.eq({h[1].cls, h[1].d.proj, h[1].d.z, h[1].d.flow, h[1].d.why}, {'A', 'aq3', 100, 7, 'flow'})
  local cp = ev(W, 'CAVERN_PLUG')
  T.eq(#cp, 1)
  T.eq({cp[1].d.phase, cp[1].d.why}, {'queued', 'heavy_aquifer'})
  T.eq(rec(W, 'aq3').heavy, true)
  H.runs(W, 3)
  T.eq(#ev(W, 'AQ_HEAVY'), 1, 'once')
  T.eq(W.tile(AX, AY, 99).dig, '', 'never dug deeper')
  T.eq((select(2, W.K.call('runner', 'cavern_open'))), 0, 'a heavy aquifer is no open cavern (R0 caverns)')
end)

T.test('heavy aquifer: a rising flow (1, 2, 3) is heavy too, before it reaches 4/7', function()
  local W = fresh{tag = 'aqrise'}
  aquifer_level(W, 100)
  H.place(W, 'aq4', shaft_doc{depth = 4})
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 1)
  local t = W.tile(AX, AY, 100)
  for _, f in ipairs({1, 2, 3}) do
    t.c, t.flow = 'w', f
    H.runs(W, 1)
  end
  T.eq(H.proj(W, 'aq4').blocked, 'breach:heavy_aquifer')
  T.eq(ev(W, 'AQ_HEAVY')[1].d.why, 'rising')
  T.eq(#ev(W, 'AQ_SEEP'), 1, 'the first water was a seep (B)')
  T.eq(ev(W, 'AQ_SEEP')[1].cls, 'B')
end)

T.test('a damp report beside the shaft marks that level (sealed even without a revealed aquifer flag)', function()
  local W = fresh{tag = 'aqdamp'}
  H.place(W, 'aq5', shaft_doc{depth = 3})
  H.runs(W, 1)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX + 1, y = AY, z = AT}})
  W.frame(1)
  T.eq(H.proj(W, 'aq5').blocked, '', 'the shaft is never parked on a damp report')
  T.eq(#ev(W, 'BREACH_STOP'), 0)
  H.dig(W)
  H.runs(W, 1)
  T.eq(rec(W, 'aq5').levels['100'].state, 'seal')
end)

T.test('observe mode: a damp report on a dig is no park; the designation comes back with the damp marker', function()
  local W = fresh{tag = 'obs'}
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = 12, y = 10, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'c1').blocked, '', 'observe, not breach:damp')
  T.eq(#ev(W, 'BREACH_STOP'), 0)
  local o = ev(W, 'AQ_OBSERVE')
  T.eq(#o, 1)
  T.eq({o[1].cls, o[1].d.proj, o[1].d.pos, o[1].d.src}, {'B', 'c1', {12, 10, 100}, 'report'})
  T.eq(rec(W, 'c1').mode, 'observe')
  W.tile(12, 10, 100).dig = ''                       -- DF cancelled the damp stone
  H.runs(W, 1)
  T.eq(W.tile(12, 10, 100).dig, 'd', 'designated again')
  local c = H.qf_calls(W, 'dig')
  T.eq(c[#c].marker, {damp = true}, 'with the damp marker (DFHack dig: damp dig mode)')
  H.dig(W)
  W.tile(12, 11, 100).c = 'w'                        -- 2/7 seepage on one of our own dug tiles: digging goes on
  H.runs(W, 2)
  T.eq(H.proj(W, 'c1').done, 1)
  T.eq(#ev(W, 'BREACH_STOP'), 0)
  -- the damp tile is dug: its natural rough walls outside the project are smoothed (observe and seal)
  T.eq(W.tile(12, 9, 100).dig, 's')
  T.eq(W.K.manifest().aquifer_levels, {100})
end)

T.test('observe mode: water >= 4/7 in our own dug tiles is a heavy aquifer (final), not a park', function()
  local W = fresh{tag = 'obsheavy'}
  H.place(W, 'c1', H.dig_doc(3))
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 12, y = 10, z = 100}})
  W.frame(1)
  H.dig(W, 5)
  local t = W.tile(11, 10, 100)
  t.c, t.flow = '~', 5
  H.runs(W, 1)
  local P = H.proj(W, 'c1')
  T.eq(P.blocked, 'breach:heavy_aquifer')
  T.eq(ev(W, 'AQ_HEAVY')[1].d.why, 'flow')
  local cp = ev(W, 'CAVERN_PLUG')
  T.eq({#cp, cp[1].d.phase}, {1, 'none'}, 'no shaft: walled by hand')
  -- a later damp report never takes it back into observe mode
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 12, y = 11, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'c1').blocked, 'breach:heavy_aquifer')
end)

T.test('observe off (legacy): a damp report still parks the dig at breach:damp', function()
  local W = fresh{tag = 'obsoff'}
  AQ.CFG.on = false
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 12, y = 10, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'c1').blocked, 'breach:damp')
  T.eq(#ev(W, 'AQ_OBSERVE'), 0)
end)

T.test('a project parked at breach:damp (an older kernel) is resumed in observe mode at boot', function()
  local W = fresh{tag = 'resume1'}
  AQ.CFG.on = false
  H.place(W, 'fc', H.dig_doc(2, {tpl = 'fortcore'}))
  H.runs(W, 2)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 12, y = 10, z = 100}})
  W.frame(1)
  T.eq(H.proj(W, 'fc').blocked, 'breach:damp')
  local persist, map = H.reloaded(W), W.map
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  local W2 = H.world{tag = 'resume2', persist = persist}
  W2.map = map
  W2.load(runner)
  T.eq(H.proj(W2, 'fc').blocked, '', 'resumed')
  T.eq(W2.K.persist.get('m.runner').aq.fc.mode, 'observe')
  local o = W2.find_events('AQ_OBSERVE')
  T.eq({#o, o[1].d.src}, {1, 'resume'})
  H.runs(W2, 2)
  T.eq(W2.tile(10, 10, 100).dig, 'd', 'its dig designated again (it was undone at the stop)')
end)

T.test('fortcore aquifer=pass waits for a passed shaft, then digs in observe mode', function()
  local W = fresh{tag = 'fcpass'}
  H.place(W, 'fc', H.dig_doc(1, {tpl = 'fortcore', z = 90, params = {stage = 1, aquifer = 'pass'}}))
  H.runs(W, 2)
  T.eq(W.tile(10, 10, 90).dig, '', 'no dig below the aquifer before the shaft passed')
  local function row(id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end
  T.ok(row('fc')[4]:find('aquifer', 1, true), T.show(row('fc')))
  H.place(W, 'aq6', shaft_doc{depth = 2, dry = 1})
  for _ = 1, 4 do H.runs(W, 1); H.dig(W) end
  T.ok(until_(W, function() return H.proj(W, 'aq6').done == 1 end, 4), 'the shaft passed (no aquifer met)')
  T.ok(until_(W, function() return W.tile(10, 10, 90).dig == 'd' end, 3), 'the fortcore digs below the passed shaft')
  T.eq(rec(W, 'fc').mode, 'observe')
end)

T.done()
