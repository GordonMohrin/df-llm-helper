-- M2 / BUG-109 (Run 14 note 76: B1 lost, replaced by doors/walls, the route still open because the ramp beside them had no
-- wall stage; `bp.place tpl=seal` refused the door tiles "left out, kernel still finds route open"; R0 stayed). The
-- fixture of test_perimeter_keeper.lua (the bridge in the west wall at x 20, y 24-26; wall, door, wall as the closure)
-- plus a bypass: a ramp at 19,25 beside the door whose top (19,25,10) leads along a corridor at z 10 to a stair into the
-- fort. The closure stands and the entrance check still finds the way in; the keeper adds a second stage (a wall on the
-- ramp top, a door on the corridor tile above the door) until the check is clean (at most two rounds).
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


local function bypass(W)
  SW.fill(W, G + 1, 0, 0, 63, 63, ',')
  SW.fill(W, G + 1, 20, 20, 40, 30, '#')
  SW.draw(W, G, {'r'}, 19, 25)                 -- the ramp beside the door, outside the west wall
  SW.draw(W, G + 1, {'^'}, 19, 25)             -- its top
  SW.fill(W, G + 1, 20, 25, 22, 25, '.')       -- a corridor over the wall line ...
  SW.draw(W, G + 1, {'>'}, 23, 25)             -- ... and a stair down into the fort
  SW.draw(W, G, {'<'}, 23, 25)
  SW.regroup(W)
end

local function second_loss(W)
  record(W, 'gw(1x3)')
  siege(W)
  rebuild(W)
  run(W, 3000)
  siege(W)
  T.eq(#W.cells, 2, 'the closure is queued')
  return W.cells[2]
end

T.test('BUG-109 (note 76): the closure stands, the check finds the ramp beside it: a second stage (ramp top wall, door above ' ..
       'the door) is queued once and the route is closed when it stands (the bridge is replaced from the first, as before)', function()
  local W = fort({fp = {20, 24, G, 20, 26, G}})
  W.burrow('Kern+', {21, 21, G, 39, 29, G})
  local c = second_loss(W)
  bypass(W)
  build_closure(W, c.cells)                    -- wall, door, wall at x 20: the old rule called this replaced
  run(W, 5000)
  local ok, lost = W.K.call('seal', 'lost_gates')
  T.eq(lost, {}, 'the bridge is replaced at once: a siege sees a door, not a lost gate')
  T.ok(select(2, W.K.call('seal', 'replaced')).O1 ~= nil)
  T.eq(#W.cells, 3, 'the second stage is queued once')
  local d = W.inbox('inspect', {what = 'defense'})
  T.eq({d.data.bridges[1].rebuild.state, d.data.bridges[1].rebuild.follow}, {'replaced', {n = 1, proj = 'rp3', tiles = 2}})
  local x = W.cells[3]
  table.sort(x.cells, function(a, b) return a[4] > b[4] end)
  T.eq(x.cells, {{20, 25, G + 1, 'd'}, {19, 25, G + 1, 'Cw'}}, 'a door on the corridor tile above the door, a wall on the ramp top')
  T.eq({x.peace, x.closure}, {true, true})
  T.ok(x.why:find('way in beside', 1, true), x.why)
  run(W, 3 * 1200)
  T.eq(#W.cells, 3, 'not queued twice')
  W.inbox('inspect', {what = 'entrances', key = 'refresh'})
  local r = W.inbox('inspect', {what = 'refuge'})
  T.eq(r.data.burrows['Kern+'].sep, 0, 'R0: the route is open')
  -- a reload in the middle keeps the stage: it is not queued a second time, and it finishes when the walls stand
  local W2 = fort({fp = W.fp, persist = reloaded(W), no_o1 = true})
  W2.burrow('Kern+', {21, 21, G, 39, 29, G})
  SW.fill(W2, G, 20, 24, 20, 24, 'C'); SW.draw(W2, G, {'+'}, 20, 25); SW.fill(W2, G, 20, 26, 20, 26, 'C')
  bypass(W2)
  run(W2, 6000)
  T.eq(#W2.cells, 0, 'a reload does not queue the stage again')
  SW.build_wall(W2, 19, 25, G + 1)
  SW.draw(W2, G + 1, {'+'}, 20, 25)
  SW.regroup(W2)
  run(W2, 6000)
  W2.inbox('inspect', {what = 'entrances', key = 'refresh'})
  T.eq(W2.inbox('inspect', {what = 'refuge'}).data.burrows['Kern+'].sep, 1, 'after the reload the route is closed too')
  T.eq(#W2.cells, 0)
  -- the builders finish it
  SW.build_wall(W, 19, 25, G + 1)
  SW.draw(W, G + 1, {'+'}, 20, 25)
  SW.regroup(W)
  run(W, 6000)
  W.inbox('inspect', {what = 'entrances', key = 'refresh'})
  r = W.inbox('inspect', {what = 'refuge'})
  T.eq(r.data.burrows['Kern+'].sep, 1, 'the route is closed')
  T.eq(#W.cells, 3)
  -- a sealed closure is replaced and left at that; a gap far from the footprint is not the closure's business
  local W = fort({fp = {20, 24, G, 20, 26, G}})
  local c = second_loss(W)
  build_closure(W, c.cells)
  run(W, 5000)
  T.eq(select(2, W.K.call('seal', 'lost_gates')), {}, 'sealed: replaced at once')
  T.ok(select(2, W.K.call('seal', 'replaced')).O1 ~= nil)
  T.eq(#W.cells, 2, 'no second stage')
  -- a ramp route 10 tiles away is not the closure's business
  local W2 = fort({fp = {20, 24, G, 20, 26, G}})
  local c2 = second_loss(W2)
  SW.fill(W2, G + 1, 0, 0, 63, 63, ',')
  SW.fill(W2, G + 1, 20, 20, 40, 30, '#')
  SW.draw(W2, G, {'r'}, 41, 25)                -- outside the east wall
  SW.draw(W2, G + 1, {'^'}, 41, 25)
  SW.fill(W2, G + 1, 38, 25, 40, 25, '.')
  SW.draw(W2, G + 1, {'>'}, 37, 25)
  SW.draw(W2, G, {'<'}, 37, 25)
  SW.regroup(W2)
  build_closure(W2, c2.cells)
  run(W2, 5000)
  T.eq(#W2.cells, 2, 'the gap lies 20 tiles from the footprint: beyond ramp_near 3')
  T.ok(select(2, W2.K.call('seal', 'replaced')).O1 ~= nil, 'replaced as before')
end)

T.test('BUG-109: the second stage is tried twice at most; then the bridge counts as replaced and what stays open is the ' ..
       'player\'s (kern.log says so)', function()
  local W = fort({fp = {20, 24, G, 20, 26, G}})
  W.burrow('Kern+', {21, 21, G, 39, 29, G})
  local c = second_loss(W)
  bypass(W)
  build_closure(W, c.cells)
  run(W, 5000)
  T.eq(#W.cells, 3, 'round 1')
  SW.build_wall(W, 19, 25, G + 1)
  SW.draw(W, G + 1, {'+'}, 20, 25)
  SW.fill(W, G + 1, 21, 26, 22, 26, '.')       -- the corridor has a second row: another way beside the door
  SW.draw(W, G + 1, {'.'}, 20, 26)
  SW.regroup(W)
  run(W, 8000)
  T.eq(#W.cells, 4, 'round 2 for the new gap')
  T.ok(select(2, W.K.call('seal', 'replaced')).O1 ~= nil, 'replaced all along')
  SW.draw(W, G + 1, {'+'}, 20, 26)             -- the door of round 2 stands, a third row opens yet another way
  SW.fill(W, G + 1, 21, 27, 22, 27, '.')
  SW.draw(W, G + 1, {'.'}, 20, 27)
  SW.regroup(W)
  run(W, 8000)
  T.eq(#W.cells, 4, 'no third round')
  local told
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('stays open after 2 extra stages', 1, true) then told = l.msg end end
  T.ok(told ~= nil, 'kern.log says what stays open')
end)

T.done()
