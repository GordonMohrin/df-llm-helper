-- BUG-048 (Run 11 y487/y497 and Run 13 y507-y525: O1, B1 and B2 lost for years, "requeued=0" in PEACE, 36 and 24
-- citizens lost, the bridge_rebuild question never answered; Run 13 fell over an open O1). Checked here with the real
-- gate and seal (k_mock + tests/lua/seal_world.lua, fake reflex and runner): (a) a bridge that vanishes in PEACE with no
-- destroyer in sight is rebuilt (the PEACE retire pass used to drop its perimeter piece, so nothing waited); (b) a
-- manifest bridge the keeper never saw built (no quickfort text) gets its text from the footprint (the old post-siege
-- diff queued nothing: requeued=0, for ever); (c) after perimeter.stop_after losses to building destroyers (and
-- perimeter.vanish_after losses without one) the keeper replaces the bridge by a wall and a door through the runner,
-- reports it once and asks nothing; (d) the replaced bridge is no gate any more (state, siege, readiness); (e) a kernel
-- state from before (a held bridge, asked) converts; (f) a rebuild that nobody built in 60 days becomes the closure.
local T = require('testlib')
local SW = require('seal_world')
local json = require('dfllm.util.json')

local G = 9
local function evs(W, t) return W.find_events(t) end
local function run(W, n) W.run(n, {skip = 9}) end

local function man_of(fp)
  return {v = 2, bridges = {O1 = {role = 'outer', fp = fp, levers = {{25, 22, G}}}},
          burrows = {['Kern+'] = {role = 'kern'}}}
end

local function reloaded(W)
  local out = {}
  for dk, s in pairs(W.persist_raw) do
    out[dk == 'dfllm' and 'marker' or dk:gsub('^dfllm%.', '')] = json.decode(s)
  end
  return out
end

-- the gatehouse of test_bridge_rebuild.lua: o.fp = the bridge footprint in the west wall (x 20, default 20,25 1x1)
local function fort(o)
  o = o or {}
  local fp = o.fp or {20, 25, G, 20, 25, G}
  local W = SW.new{persist = o.persist or {manifest = man_of(fp)}}
  W.fp = fp
  if o.reflex then W.K.cfg.reflex = o.reflex end
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.fill(W, G, fp[1], fp[2], fp[4], fp[5], '.')
  if not o.no_o1 then W.o1 = SW.bridge(W, fp, false, 'O1') end
  W.lv = SW.lever(W, 25, 22, G, W.o1)
  SW.draw(W, G, {'C'}, 40, 26)
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.lock = nil
  W.load(SW.fake('reflex', {holding = function() return W.lock end}))
  W.cells = {}
  W.load(SW.fake('runner', {repair = function(K, cells, why, opts)
    W.cells[#W.cells + 1] = {cells = cells, why = why, peace = type(opts) == 'table' and opts.peace == true,
                             closure = type(opts) == 'table' and opts.closure == true}
    return true, 'rp' .. #W.cells
  end}))
  W.act_result('link_lever', function(lid, bid)
    local lv = W.buildings[lid]
    lv.linked_mechanisms = require('dfllm.util.k_mock').vec{{_ref = {getBuilding = function() return W.buildings[bid] end}}}
    return true, 7000 + bid
  end)
  package.loaded['dfllm.gate'] = nil
  W.load(require('dfllm.gate'))
  package.loaded['dfllm.seal'] = nil
  W.load(require('dfllm.seal'))
  return W
end

-- the fortcore pieces seal knows from its defense project (with the quickfort text of the bridge)
local function record(W, text)
  run(W, 300)
  local fp = W.fp
  W.K.call('seal', 'closing', 'fc1', 'fortcore', 'defense', {pos = {fp[1], fp[2], G}, cells = {{0, 0, 0, text}}})
  run(W, 300)
end

local function dragons(W, on)
  local list = {}
  for i = 1, on and 2 or 0 do
    local id = 500 + i
    if not W.unit(id) then W.add_unit{id = id, pos = {10 + i, 25, G}, invader = true, race = 'DRAGON'} end
    list[#list + 1] = {id = id, x = 10 + i, y = 25, z = G, bd = 1, dz = 1}
  end
  W.set_census('h', {tick = W.K.now().tick, vis = #list, bd = #list, list = list})
end

local function destroy(W)
  local b = W.o1
  W.buildings[b.id] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
  SW.fill(W, G, W.fp[1], W.fp[2], W.fp[4], W.fp[5], '.')
  W.o1 = nil
  SW.regroup(W)
end

local function rebuild(W)
  SW.fill(W, G, W.fp[1], W.fp[2], W.fp[4], W.fp[5], '.')
  W.o1 = SW.bridge(W, W.fp, false, 'O1')
  SW.regroup(W)
end

-- one siege with the dragons: the bridge destroyed, then RECOVERY and quiet PEACE
local function siege(W, o)
  o = o or {}
  W.K.set_mode('SIEGE', 'test')
  run(W, 200)
  dragons(W, o.dragons ~= false)
  run(W, 100)
  destroy(W)
  run(W, 600)
  dragons(W, false)
  W.K.set_mode('RECOVERY', 'test')
  run(W, 600)
  W.K.set_mode('PEACE', 'test')
  run(W, 400)
end

-- the closure standing: walls and a door on the footprint as quickfort would leave them
local function build_closure(W, cells)
  for _, c in ipairs(cells) do
    if c[4] == 'Cw' then SW.build_wall(W, c[1], c[2], c[3]) else SW.draw(W, c[3], {'+'}, c[1], c[2]) end
  end
  SW.regroup(W)
end

local function decisions(W)
  local r = {}
  for _, e in ipairs(evs(W, 'DECISION_NEEDED')) do if e.d.id == 'bridge_rebuild' then r[#r + 1] = e end end
  return r
end

---------------------------------------------------------------- (a) a bridge lost in PEACE
T.test('a bridge that vanishes in PEACE with no destroyer in sight is rebuilt in quiet PEACE (the retire pass used to ' ..
       'drop its piece: bridge.rebuild answered "no lost bridge waits"), and the text names that no destroyer was there',
       function()
  local W = fort()
  record(W, 'gw(1x1)')
  destroy(W)
  run(W, 2600)                                   -- gate finds it (BRIDGE_DESTROYED), a day later nothing may be dropped
  T.eq(#evs(W, 'BRIDGE_DESTROYED'), 1)
  T.eq(#W.cells, 1, 'queued at once, no 7-day wait')
  T.eq({W.cells[1].cells, W.cells[1].peace}, {{{20, 25, G, 'gw(1x1)'}}, true})
  T.ok(W.cells[1].why:find('no destroyer', 1, true), W.cells[1].why)
  local r = W.inbox('inspect', {what = 'defense'})
  T.ok(r.ok and r.data.bridges[1].rebuild.state == 'queued', T.show(r.data.bridges[1].rebuild))
  T.ok(r.data.bridges[1].rebuild.how == 'none', 'inspect says no destroyer: ' .. T.show(r.data.bridges[1].rebuild))
  run(W, 3 * 7 * 1200)                           -- the retire pass runs: the entry stays, nothing is queued twice
  T.eq(#W.cells, 1)
  r = W.inbox('bridge.rebuild', {bridge = 'O1'})
  T.ok(r.ok and r.msg:find('rebuild queued as rp1', 1, true), r.msg)
end)

T.test('a lost bridge waits for quiet PEACE: not during a PEACE lockdown, then at once', function()
  local W = fort()
  record(W, 'gw(1x1)')
  W.lock = 'arrival:siege'
  destroy(W)
  run(W, 2600)
  T.eq(#W.cells, 0, 'a lockdown: nothing')
  W.lock = nil
  run(W, 300)
  T.eq(#W.cells, 1)
end)

---------------------------------------------------------------- (b) no quickfort text
T.test('a manifest bridge the keeper never saw built (no closing record, a reclaimed fort) lost in a siege: the text ' ..
       'comes from the footprint and the repair is queued in PEACE (the old diff gave requeued=0 and never retried)',
       function()
  -- old code: PERIMETER_BROKEN requeued=0, wait=nil: the piece had no text, nothing waited, the bridge stayed lost
  local W = fort({fp = {20, 24, G, 20, 26, G}})
  run(W, 600)                                    -- no record(): only the manifest knows the bridge
  siege(W)
  local pb = evs(W, 'PERIMETER_BROKEN')
  T.eq(#pb, 1)
  T.eq({pb[1].d.requeued, pb[1].d.wait}, {0, {'O1'}}, 'waits for quiet PEACE')
  run(W, 300)
  T.eq(#W.cells, 1)
  T.eq({W.cells[1].cells, W.cells[1].peace}, {{{20, 24, G, 'gw(1x3)'}}, true}, 'the footprint is 1 wide, 3 long')
end)

---------------------------------------------------------------- (c) the closure after stop_after losses
T.test('after two losses to building destroyers the keeper replaces the bridge by a wall and a door (3x1: wall, door, ' ..
       'wall), once, with no question; the rebuilt bridge of the first loss stays a bridge', function()
  local W = fort({fp = {20, 24, G, 20, 26, G}})
  record(W, 'gw(1x3)')
  siege(W)
  T.eq(#W.cells, 1, 'the first loss is rebuilt')
  T.eq(W.cells[1].cells, {{20, 24, G, 'gw(1x3)'}})
  rebuild(W)
  run(W, 3000)
  siege(W)                                       -- the second loss to building destroyers
  T.eq(#decisions(W), 0, 'no question nobody answers')
  T.eq(#W.cells, 2)
  local c = W.cells[2]
  T.eq(c.peace, true)
  table.sort(c.cells, function(a, b) return a[2] < b[2] end)
  T.eq(c.cells, {{20, 24, G, 'Cw'}, {20, 25, G, 'd'}, {20, 26, G, 'Cw'}}, 'walls on the sides, the door in the middle')
  T.ok(c.why:find('wall + door', 1, true) and c.why:find('O1', 1, true), c.why)
  local pb = evs(W, 'PERIMETER_BROKEN')
  local rep
  for _, e in ipairs(pb) do if e.d.replaced then rep = e end end
  T.ok(rep ~= nil, 'reported')
  T.eq(rep.d.replaced, {'O1'})
  T.ok(rep.msg:find('replaced by wall + door', 1, true) and rep.msg:find('2x', 1, true), rep.msg)
  local ok, lost = W.K.call('seal', 'lost_gates')
  T.ok(ok and lost.O1 and lost.O1.cl == 'rp2', T.show(lost))
  run(W, 5 * 1200)
  T.eq(#W.cells, 2, 'queued once')
  T.eq(#decisions(W), 0)
  -- the builders finish it: the bridge is no gate any more
  build_closure(W, c.cells)
  run(W, 2600)
  ok, lost = W.K.call('seal', 'lost_gates')
  T.eq(lost, {}, 'standing: no blocker')
  local ok2, rep2 = W.K.call('seal', 'replaced')
  T.ok(ok2 and rep2.O1 ~= nil, T.show(rep2))
  T.eq(W.state().bridges.O1, 'replaced')
  local r = W.inbox('inspect', {what = 'defense'})
  T.ok(r.ok and r.data.bridges[1].rebuild.state == 'replaced', T.show(r.data.bridges[1].rebuild))
  r = W.inbox('bridge.rebuild', {bridge = 'O1'})
  T.ok(not r.ok and r.msg:find('replaced by wall + door', 1, true), r.msg)
  -- a reload keeps it
  local W2 = fort{fp = W.fp, persist = reloaded(W), no_o1 = true}
  SW.fill(W2, G, 20, 24, 20, 24, 'C'); SW.draw(W2, G, {'+'}, 20, 25); SW.fill(W2, G, 20, 26, 20, 26, 'C')
  SW.regroup(W2)
  run(W2, 600)
  local _, rep3 = W2.K.call('seal', 'replaced')
  T.ok(rep3 and rep3.O1 ~= nil, 'a reload keeps the replaced bridge')
  T.eq(#W2.cells, 0)
end)

T.test('a 1x1 bridge becomes a door; stop_after 0 always rebuilds; a high stop_after keeps rebuilding', function()
  local W = fort()
  record(W, 'gw(1x1)')
  siege(W); rebuild(W); run(W, 3000); siege(W)
  T.eq(#W.cells, 2)
  T.eq(W.cells[2].cells, {{20, 25, G, 'd'}})
  local W2 = fort{reflex = {v = 2, perimeter = {stop_after = 0}}}
  record(W2, 'gw(1x1)')
  siege(W2); rebuild(W2); run(W2, 3000); siege(W2)
  T.eq(#W2.cells, 2)
  T.eq(W2.cells[2].cells, {{20, 25, G, 'gw(1x1)'}}, 'stop_after 0: always rebuilt')
  local W3 = fort{reflex = {v = 2, perimeter = {stop_after = 3}}}
  record(W3, 'gw(1x1)')
  siege(W3); rebuild(W3); run(W3, 3000); siege(W3)
  T.eq(W3.cells[2].cells, {{20, 25, G, 'gw(1x1)'}}, 'the second loss is rebuilt under stop_after 3')
end)

---------------------------------------------------------------- the loop breaker for losses without a destroyer
T.test('a bridge that vanishes again and again with no destroyer (perimeter.vanish_after, 3) is replaced by a door ' ..
       'too: the rebuild loop has an end', function()
  local W = fort()
  record(W, 'gw(1x1)')
  for i = 1, 2 do
    destroy(W)
    run(W, 2600)
    T.eq(#W.cells, i, 'loss ' .. i .. ' rebuilt')
    T.eq(W.cells[i].cells, {{20, 25, G, 'gw(1x1)'}})
    rebuild(W)
    run(W, 3000)
  end
  destroy(W)
  run(W, 2600)
  T.eq(#W.cells, 3)
  T.eq(W.cells[3].cells, {{20, 25, G, 'd'}}, 'the third loss without a destroyer: a door')
  T.eq(#decisions(W), 0)
  local pb = evs(W, 'PERIMETER_BROKEN')
  T.ok(#pb == 1 and pb[1].d.replaced[1] == 'O1' and pb[1].msg:find('no destroyer', 1, true), T.show(pb))
end)

---------------------------------------------------------------- (e) the state of an older kernel
T.test('a held bridge and its DECISION_NEEDED from an older kernel (gq held/asked, bd 2) convert at the next quiet ' ..
       'PEACE: the closure is queued, nobody is asked again', function()
  local W = fort()
  record(W, 'gw(1x1)')
  siege(W)
  rebuild(W); run(W, 3000); siege(W)
  local p = reloaded(W)
  -- what the old kernel wrote: held, asked, no project
  for _, g in pairs(p['m.seal'].gq) do g.held, g.asked, g.proj, g.cl = 1, 2, nil, nil end
  local W2 = fort{persist = p, no_o1 = true}
  W2.K.set_mode('PEACE', 'test')
  run(W2, 2600)
  T.eq(#decisions(W2), 0)
  T.eq(#W2.cells, 1)
  T.eq(W2.cells[1].cells, {{20, 25, G, 'd'}})
end)

---------------------------------------------------------------- (f) a repair nobody builds
T.test('a rebuild that is not built within 60 days becomes the closure instead of being given up for good', function()
  local W = fort()
  record(W, 'gw(1x1)')
  destroy(W)
  run(W, 2600)
  T.eq(#W.cells, 1)
  run(W, 61 * 1200)                              -- the repair project never builds it
  T.eq(#W.cells, 2)
  T.eq(W.cells[2].cells, {{20, 25, G, 'd'}})
  T.ok(W.cells[2].why:find('not built', 1, true), W.cells[2].why)
end)

---------------------------------------------------------------- (g) BUG-081: the runner walled a door that stayed unbuilt
T.test('BUG-081: the closure stands when the runner replaced its stuck door by a wall (runner.stuck_walls); the closure is ' ..
       'asked for as a closure (opts.closure: walls first, the door next)', function()
  local W = fort({fp = {20, 24, G, 20, 26, G}})
  record(W, 'gw(1x3)')
  siege(W)
  rebuild(W)
  run(W, 3000)
  siege(W)
  T.eq(#W.cells, 2)
  T.eq(W.cells[2].closure, true, 'old code: the closure was an ordinary peace-only repair')
  for _, c in ipairs(W.cells[2].cells) do SW.build_wall(W, c[1], c[2], c[3]) end    -- the door tile holds a wall too
  SW.regroup(W)
  run(W, 2600)
  local ok, lost = W.K.call('seal', 'lost_gates')
  T.eq(lost, {}, 'a walled footprint is closed')
  local _, rep = W.K.call('seal', 'replaced')
  T.ok(rep and rep.O1 ~= nil, 'the bridge is replaced')
  T.eq(#W.cells, 2, 'not queued again')
end)

T.done()
