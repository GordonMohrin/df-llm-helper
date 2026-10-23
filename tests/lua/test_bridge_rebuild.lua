-- BUG-030 rebuild policy (Run 11 site98, y434-y438: cave dragons, building destroyers, destroyed the outer drawbridge
-- O1 114,79,142 in all five sieges; the perimeter keeper re-queued it in RECOVERY every time: PERIMETER_BROKEN -> an
-- `rp` repair project, the builders out on the footprint, the next siege broke it again). Checked here: gate's loss
-- history per manifest bridge (count, with building destroyers in sight, races, years, rebuilds, items, lever links;
-- persisted), seal's bridge queue (a lost bridge is queued again only in quiet PEACE, never in SIEGE, BREACH, ALERT,
-- RECOVERY or a lockdown, as a peace-only repair project), the stop rule (destroyed perimeter.stop_after times by
-- building destroyers: replaced by a wall and a door, BUG-048; it used to be a DECISION_NEEDED bridge_rebuild nobody
-- answered), the player's order (verb bridge.rebuild), a walled footprint, `inspect defense`. k_mock (strict) + tests/lua/seal_world.lua with
-- the real gate and seal, fake reflex (lockdown) and runner (repair) modules.
local T = require('testlib')
local SW = require('seal_world')
local json = require('dfllm.util.json')

local G = 9
local FP = {20, 25, G, 20, 25, G}
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = FP, levers = {{25, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}

local function evs(W, t) return W.find_events(t) end
local function run(W, n) W.run(n, {skip = 9}) end
local function losses(W)
  local ok, L = W.K.call('gate', 'losses', 'O1')
  T.ok(ok, 'gate.losses')
  return L
end
local function reloaded(W)
  local out = {}
  for dk, s in pairs(W.persist_raw) do
    out[dk == 'dfllm' and 'marker' or dk:gsub('^dfllm%.', '')] = json.decode(s)
  end
  return out
end
local function decisions(W)
  local r = {}
  for _, e in ipairs(evs(W, 'DECISION_NEEDED')) do if e.d.id == 'bridge_rebuild' then r[#r + 1] = e end end
  return r
end
local function bridge_cells(W)
  local r = {}
  for _, c in ipairs(W.cells) do
    for _, x in ipairs(c.cells) do if x[4]:sub(1, 1) == 'g' then r[#r + 1] = c end end
  end
  return r
end

-- the gatehouse: a field ',' x0-63 y0-63 (outside, to the map edge), fort walls x20-40 y20-30, the hall x21-39
-- y21-29; O1 at 20,25 in the west wall (lever 25,22), a fortcore wall piece at 40,26. o.gate: a fake gate module
-- (else the real one); o.persist: a reload; o.no_o1: O1 is not on the map
local function fort(o)
  o = o or {}
  local W = SW.new{persist = o.persist or {manifest = MAN}}
  if o.reflex then W.K.cfg.reflex = o.reflex end
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'.'}, 20, 25)
  if not o.no_o1 then W.o1 = SW.bridge(W, FP, false, 'O1') end
  W.lv = SW.lever(W, 25, 22, G, W.o1)
  if o.wall ~= false then SW.draw(W, G, {'C'}, 40, 26) end
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.lock = nil
  W.load(SW.fake('reflex', {holding = function() return W.lock end}))
  W.cells = {}
  W.load(SW.fake('runner', {repair = function(K, cells, why, opts)
    W.cells[#W.cells + 1] = {cells = cells, why = why, peace = type(opts) == 'table' and opts.peace == true}
    return true, 'rp' .. #W.cells
  end}))
  -- gate links a rebuilt bridge to its lever (act.link_lever): the lever then targets it
  W.act_result('link_lever', function(lid, bid)
    local lv = W.buildings[lid]
    lv.linked_mechanisms = require('dfllm.util.k_mock').vec{{_ref = {getBuilding = function() return W.buildings[bid] end}}}
    return true, 7000 + bid
  end)
  if o.gate then W.load(o.gate)
  else
    package.loaded['dfllm.gate'] = nil
    W.load(require('dfllm.gate'))
  end
  package.loaded['dfllm.seal'] = nil
  W.load(require('dfllm.seal'))
  return W
end

-- the fortcore pieces seal knows from its defense project: O1 (gw) and the wall
local function record(W)
  run(W, 300)
  W.K.call('seal', 'closing', 'fc1', 'fortcore', 'defense', {pos = {20, 25, G}, cells = {{0, 0, 0, 'gw(1x1)'}}})
  W.K.call('seal', 'closing', 'fc1', 'fortcore', 'defense', {pos = {40, 26, G}, cells = {{0, 0, 0, 'Cw'}}})
  SW.build_wall(W, 40, 26, G)
  run(W, 300)
end

-- building destroyers (two dragons) in sight on the field, or none (sense's census.h)
local function dragons(W, on)
  local list = {}
  for i = 1, on and 2 or 0 do
    local id = 500 + i
    if not W.unit(id) then W.add_unit{id = id, pos = {10 + i, 25, G}, invader = true, race = 'DRAGON'} end
    list[#list + 1] = {id = id, x = 10 + i, y = 25, z = G, bd = 1, dz = 1}
  end
  W.set_census('h', {tick = W.K.now().tick, vis = #list, bd = #list, list = list})
end

-- DF removes a destroyed building; the footprint is plain floor again
local function destroy(W)
  local b = W.o1
  W.buildings[b.id] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
  SW.draw(W, G, {'.'}, 20, 25)
  W.o1 = nil
  SW.regroup(W)
end

-- built again (by the repair project): a complete bridge with its construction items (3 granite blocks)
local function rebuild(W)
  SW.draw(W, G, {'.'}, 20, 25)
  W.o1 = SW.bridge(W, FP, false, 'O1')
  local blk = {getType = function() return 3 end}
  W.o1.contained_items = {{use_mode = 2, item = blk}, {use_mode = 2, item = blk}, {use_mode = 2, item = blk},
                          {use_mode = 0, item = {getType = function() return 9 end}}}
  SW.regroup(W)
end

local function stub_materials()
  df.item_type = {[3] = 'BLOCKS', [9] = 'MECHANISM'}
  dfhack.matinfo = {decode = function() return {toString = function() return 'granite' end} end}
end

-- one siege with the dragons: O1 (and the wall) destroyed, then RECOVERY
local function siege(W, opts)
  opts = opts or {}
  W.K.set_mode('SIEGE', 'test')
  run(W, 200)
  dragons(W, opts.dragons ~= false)
  run(W, 100)
  destroy(W)
  if opts.wall then SW.draw(W, G, {'.'}, 40, 26); SW.regroup(W) end
  run(W, 600)
  dragons(W, false)
  W.K.set_mode('RECOVERY', 'test')
  run(W, 600)
end

---------------------------------------------------------------- gate: the loss history
T.test('gate: every loss of a manifest bridge is counted (with building destroyers in sight: bd, their races, the ' ..
       'year), BRIDGE_DESTROYED carries the count; a rebuild, its items and its lever link are counted too; a loss ' ..
       'without destroyers in sight is no bd; the record survives a reload', function()
  -- old code: gate.losses does not exist, BRIDGE_DESTROYED has no count: nothing tells the 5th loss from the 1st
  local W = fort()
  stub_materials()
  record(W)
  siege(W)
  local e = evs(W, 'BRIDGE_DESTROYED')
  T.eq(#e, 1)
  T.eq({e[1].d.n, e[1].d.bd, e[1].d.destroyers, e[1].d.races, e[1].d.mode}, {1, 1, 1, {'DRAGON'}, 'SIEGE'})
  T.ok(e[1].msg:find('O1 destroyed: no bridge on its footprint at 20,25,9', 1, true)
       and e[1].msg:find('lost 1x, 1 with building destroyers in sight (DRAGON)', 1, true), e[1].msg)
  local L = losses(W)
  T.eq({L.n, L.bd, L.reb, L.it, L.lk, L.races, #L.ev, L.ev[1].y, L.ev[1].m, L.ev[1].bd}, {1, 1, 0, 0, 0, {'DRAGON'}, 1,
       3, 'SIEGE', 1})
  W.K.set_mode('PEACE', 'test')
  rebuild(W)
  run(W, 2600)                                      -- the footprint is looked at once a game day
  local reb = {}
  for _, g in ipairs(evs(W, 'GATE')) do if g.d.state == 'rebuilt' then reb[#reb + 1] = g end end
  T.eq(#reb, 1, 'GATE rebuilt')
  L = losses(W)
  T.eq({L.n, L.reb, L.lk}, {1, 1, 1}, 'rebuilt once, its lever linked once')
  -- the next loss in an ALERT, nobody with the raws in sight for days: a loss, not one to building destroyers
  W.K.set_mode('ALERT', 'test')
  run(W, 3000)
  destroy(W)
  run(W, 700)
  e = evs(W, 'BRIDGE_DESTROYED')
  T.eq(#e, 2)
  T.eq({e[2].d.n, e[2].d.bd, e[2].d.destroyers, e[2].d.mode}, {2, 1, 0, 'ALERT'})
  L = losses(W)
  T.eq({L.n, L.bd, L.it, L.mat, #L.ev, L.ev[2].bd}, {2, 1, 3, 'granite blocks', 2, 0},
       'the lost bridge held 3 granite blocks')
  -- a reload keeps it
  local W2 = fort{persist = reloaded(W), no_o1 = true}
  run(W2, 300)
  T.eq(losses(W2), L)
  T.eq(W2.state().bridges.O1, 'destroyed')
end)

---------------------------------------------------------------- seal: the bridge queue (the Run 11 replay)
T.test('Run 11 replay: O1 destroyed by dragons: the wall is re-queued in RECOVERY, O1 only in quiet PEACE (a ' ..
       'peace-only repair); destroyed a second time: a door instead (BUG-048), never a question; bridge.rebuild ' ..
       'orders the rebuild and the count starts again',
       function()
  -- old code: RECOVERY re-queued O1 together with the wall ({{20,25,9,'gw(1x1)'}, {40,26,9,'Cw'}}), after every
  -- siege, with no question to the player
  local W = fort()
  stub_materials()
  record(W)
  siege(W, {wall = true})
  local pb = evs(W, 'PERIMETER_BROKEN')
  T.eq(#pb, 1)
  T.eq({pb[1].d.n, pb[1].d.requeued, pb[1].d.wait, pb[1].d.held}, {2, 1, {'O1'}, nil})
  T.ok(pb[1].msg:find('1 re-queued as rp1; bridge O1 after the fight (quiet PEACE)', 1, true), pb[1].msg)
  T.eq(#W.cells, 1)
  T.eq({W.cells[1].cells, W.cells[1].peace}, {{{40, 26, G, 'Cw'}}, false}, 'only the wall in RECOVERY')
  W.K.set_mode('PEACE', 'test')
  run(W, 300)
  T.eq(#W.cells, 2)
  T.eq({W.cells[2].cells, W.cells[2].peace}, {{{20, 25, G, 'gw(1x1)'}}, true}, 'O1 in PEACE, a peace-only repair')
  T.ok(W.cells[2].why:find('bridge O1 after the fight', 1, true), W.cells[2].why)
  T.eq(#decisions(W), 0, 'the first loss is rebuilt without a question')
  run(W, 3000)
  T.eq(#W.cells, 2, 'queued once')
  -- the repair builds it; a week later siege 2 breaks it again
  rebuild(W)
  run(W, 9000)
  siege(W)
  pb = evs(W, 'PERIMETER_BROKEN')
  T.eq(#pb, 2)
  T.eq({pb[2].d.n, pb[2].d.requeued, pb[2].d.wait}, {1, 0, {'O1'}})
  -- BUG-048 (DECISIONS 3): the answer is no question; before the player could answer (the fort is not in PEACE yet) he
  -- orders the rebuild: the count starts again
  local r = W.inbox('bridge.rebuild', {bridge = 'O1'})
  T.ok(r.ok and r.msg:find('rebuild queued for the next quiet PEACE (mode RECOVERY now)', 1, true), r.msg)
  T.ok(r.msg:find('replaced by wall + door after 2 more losses to building destroyers', 1, true), r.msg)
  W.K.set_mode('PEACE', 'test')
  run(W, 300)
  T.eq(#W.cells, 3, 'the answer rebuilds it')
  T.eq({W.cells[3].cells, W.cells[3].peace}, {{{20, 25, G, 'gw(1x1)'}}, true})
  T.eq(#decisions(W), 0, 'bridge_rebuild is never asked')
  local ok, lost = W.K.call('seal', 'lost_gates')
  T.eq(lost, {})
  -- the third loss is rebuilt again (one since the answer), the fourth is replaced by a door, nobody is asked
  rebuild(W)
  run(W, 9000)
  siege(W)
  W.K.set_mode('PEACE', 'test')
  run(W, 300)
  T.eq({#W.cells, #decisions(W)}, {4, 0})
  rebuild(W)
  run(W, 9000)
  siege(W)
  W.K.set_mode('PEACE', 'test')
  run(W, 300)
  T.eq({#W.cells, #decisions(W)}, {5, 0})
  T.eq(W.cells[5].cells, {{20, 25, G, 'd'}}, 'the fourth: a door in place of the gate')
  ok, lost = W.K.call('seal', 'lost_gates')
  T.ok(ok and lost.O1 and lost.O1.bd == 4 and lost.O1.cl == 'rp5', T.show(lost))
  r = W.inbox('inspect', {what = 'defense'})
  local o1 = r.data.bridges[1]
  T.eq({o1.lost.n, o1.lost.bd, o1.rebuild.state, o1.rebuild.stop_after}, {4, 4, 'closing', 2})
  T.ok(r.msg:find('O1 destroyed/- 0lev lost 4x (4 bd) closing', 1, true), r.msg)
  r = W.inbox('bridge.rebuild', {bridge = 'O1'})
  T.ok(not r.ok and r.msg:find('its wall + door is queued as rp5', 1, true), r.msg)
  T.eq(#bridge_cells(W), 3, 'three bridges built, the fourth loss a door')
end)

-- a fake gate: O1 lost W.L (gate.losses), state 'unknown' with the tick it was destroyed while it is gone
local function fake_gate(W0)
  local g = SW.fake('gate', {})
  function g.losses(K, name) return name == 'O1' and g.L or nil end
  function g.state(K, b)
    if b == nil then return {} end
    return 'unknown', nil, 5
  end
  return g
end

T.test('never during a fight: a lost bridge waits through ALERT and a PEACE lockdown; queued once the lockdown ends',
       function()
  local g = fake_gate()
  g.L = {n = 1, bd = 1, reb = 0, it = 0, lk = 0, races = {'DRAGON'}, ev = {{t = 5, y = 3, m = 'SIEGE', bd = 1}}}
  local W = fort{gate = g}
  record(W)
  siege(W)
  T.eq(#W.cells, 0, 'RECOVERY: nothing for the bridge')
  W.K.set_mode('ALERT', 'test')                     -- an ambush right after the siege
  run(W, 1200)
  T.eq(#W.cells, 0, 'ALERT: nothing')
  W.lock = 'arrival:siege'                          -- a lockdown in PEACE (an arrival report)
  W.K.set_mode('PEACE', 'test')
  run(W, 2600)
  T.eq(#W.cells, 0, 'a lockdown: nothing')
  W.lock = nil
  run(W, 300)
  T.eq(#W.cells, 1)
  T.eq({W.cells[1].cells, W.cells[1].peace}, {{{20, 25, G, 'gw(1x1)'}}, true})
  T.eq(#evs(W, 'PERIMETER_BROKEN'), 1, 'reported once (at RECOVERY)')
  T.eq(evs(W, 'PERIMETER_BROKEN')[1].d.wait, {'O1'})
end)

T.test('a footprint the player walled is retired (never rebuilt); stop_after 0 always rebuilds; the verb refuses a ' ..
       'bridge that is not in the manifest; the queue and the answers survive a reload', function()
  local g = fake_gate()
  g.L = {n = 1, bd = 1, reb = 0, it = 0, lk = 0, races = {}, ev = {}}
  local W = fort{gate = g}
  record(W)
  siege(W)
  SW.build_wall(W, 20, 25, G)                      -- the player chose the wall
  W.K.set_mode('PEACE', 'test')
  run(W, 2600)
  T.eq(#W.cells, 0)
  local p = W.inbox('inspect', {what = 'perimeter'}).data
  T.eq(p.bridges, nil, 'no lost bridge left')
  -- stop_after 0: rebuilt after five losses to building destroyers
  local g2 = fake_gate()
  g2.L = {n = 5, bd = 5, reb = 4, it = 12, lk = 4, races = {'DRAGON'}, ev = {}}
  local W2 = fort{gate = g2, reflex = {v = 2, perimeter = {stop_after = 0}}}
  record(W2)
  siege(W2)
  W2.K.set_mode('PEACE', 'test')
  run(W2, 300)
  T.eq({#W2.cells, #decisions(W2)}, {1, 0})
  -- BUG-048: the default (2): the door, no question; the verb's order and the queue across a reload (a bridge that
  -- still waits for quiet PEACE)
  local g3 = fake_gate()
  g3.L = {n = 2, bd = 2, reb = 1, it = 3, lk = 1, races = {'DRAGON'}, ev = {}}
  local W3 = fort{gate = g3}
  record(W3)
  siege(W3)
  local saved = reloaded(W3)
  local r = W3.inbox('bridge.rebuild', {bridge = 'X9'})
  T.ok(not r.ok and r.msg:find('X9 is no manifest bridge', 1, true), r.msg)
  W3.K.set_mode('PEACE', 'test')
  run(W3, 300)
  T.eq({#W3.cells, #decisions(W3)}, {1, 0})
  T.eq(W3.cells[1].cells, {{20, 25, G, 'd'}}, 'a door in place of the gate')
  local g4 = fake_gate()
  g4.L = g3.L
  local W4 = fort{gate = g4, persist = saved, no_o1 = true}
  W4.K.set_mode('ALERT', 'test')
  run(W4, 2600)
  T.eq({#W4.cells, #decisions(W4)}, {0, 0}, 'waits for quiet PEACE, nobody asked')
  local ok, lost = W4.K.call('seal', 'lost_gates')
  T.ok(ok and lost.O1 ~= nil and lost.O1.cl == nil, T.show(lost))
  W4.K.set_mode('SIEGE', 'test')                    -- answered during a fight: queued for the next quiet PEACE
  run(W4, 100)
  r = W4.inbox('bridge.rebuild', {bridge = 'O1'})
  T.ok(r.ok and r.msg:find('rebuild queued for the next quiet PEACE (mode SIEGE now)', 1, true), r.msg)
  T.eq(#W4.cells, 0)
  W4.K.set_mode('RECOVERY', 'test')
  run(W4, 300)
  T.eq(#W4.cells, 0)
  W4.K.set_mode('PEACE', 'test')
  run(W4, 300)
  T.eq({#W4.cells, W4.cells[1] and W4.cells[1].peace}, {1, true})
  local W5 = fort{gate = g4, persist = reloaded(W4), no_o1 = true}
  run(W5, 300)
  local o1 = W5.inbox('inspect', {what = 'defense'}).data.bridges[1]
  T.eq({o1.name, o1.state, o1.lost.bd, o1.rebuild.ans, o1.rebuild.state, o1.rebuild.proj},
       {'O1', 'destroyed', 2, 2, 'queued', 'rp1'}, 'the order and the queued repair survive a reload')
  T.eq(#W5.cells, 0, 'not queued twice')
end)

T.done()
