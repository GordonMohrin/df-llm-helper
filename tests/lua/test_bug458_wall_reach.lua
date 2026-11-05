-- BUG-458 (Run 16d i4 Orbblock y375-y377): the seal's door spots became walls ('doors stuck at 95,69,137, 95,71,137: walls
-- instead', the doors 'waits for door x1 (0 free, 5 ordered)'), and the only surface farm, the manager and the broker
-- stayed outside: 'farm: none on the citizens' group', idle_why noreach 15, no order validated for 145-234 days, 23 starved.
-- seal.wall_cuts floods the main walk group with the tiles closed and names every citizen, farm, well, depot, workshop and
-- office it no longer reaches; the runner holds the wall back and asks for the door; seal.locked_out and the runner's
-- LOCKED_OUT decision find walls that already shut citizens out, bp.cancel reopen takes our wall down. Every test fails
-- on 453f8fe (no wall_cuts, no reach check, no locked_out).
local T = require('testlib')
local SW = require('seal_world')
local H = require('runner_world')
local runner = require('dfllm.runner')

local G = 9

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end

-- the fort x20-40 y20-30 (rough walls, floor inside) on open ground; two door spots in its wall: 30,30 (south) and 35,20
-- (north). Citizens 1 and 2 inside; `out`: a citizen at 10,10, a well at 50,50 and a farm plot at 45,45, all outside.
local function fort(out)
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'.'}, 30, 30)
  SW.draw(W, G, {'.'}, 35, 20)
  local cits = {{1, 25, 25, G}, {2, 26, 26, G}}
  if out then
    SW.draw(W, G, {'W'}, 50, 50)
    SW.building(W, 'FARM_PLOT', 'FarmPlot', 45, 45, G)
    cits[#cits + 1] = {3, 10, 10, G}
  end
  SW.regroup(W)
  SW.citizens(W, cits)
  W.load(SW.fake('gate', {state = function(K, b) if b == nil then return {} end return 'down' end, fire = function() end}))
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  W.load(seal())
  return W
end

local function cuts(W, tiles)
  local ok, r = W.K.call('seal', 'wall_cuts', tiles)
  T.ok(ok, 'seal.wall_cuts is called: ' .. tostring(r))
  return r
end
local function kinds(r)
  local k = {}
  for _, c in ipairs(r.cuts or {}) do k[#k + 1] = c.kind end
  table.sort(k)
  return table.concat(k, ',')
end

T.test('BUG-458: walls on both door spots shut the farm, the well and the citizen outside; one spot left open cuts nothing',
       function()
  local W = fort(true)
  local r = cuts(W, {{30, 30, G}, {35, 20, G}})
  T.eq({r.known, r.n, r.partial}, {true, 3, false})
  T.eq(kinds(r), 'citizen,farm,well')
  -- one wall only: the other spot is a way (a door tile is walkable)
  r = cuts(W, {{30, 30, G}})
  T.eq({r.known, r.n}, {true, 0})
  r = cuts(W, {{35, 20, G}})
  T.eq({r.known, r.n}, {true, 0})
end)

T.test('BUG-458: nothing outside to cut off (all citizens and places inside): the walls are the seal\'s purpose', function()
  local W = fort(false)
  local r = cuts(W, {{30, 30, G}, {35, 20, G}})
  T.eq({r.known, r.n}, {true, 0})
end)

T.test('BUG-458: the flood runs out of tiles: nothing is proven (partial), not a clean bill', function()
  local W = fort(true)
  W.mods.seal.M.CFG.bfs_max = 40
  local r = cuts(W, {{30, 30, G}})
  T.eq(r.known, true)
  T.eq(r.partial, true)
  T.ok(r.n >= 1, T.show(r))
end)

T.test('BUG-458: no citizen: unknown, not a clean bill; no tile: unknown', function()
  local W = fort(true)
  local ok, r = W.K.call('seal', 'wall_cuts', {})
  T.ok(ok)
  T.eq(r.known, false)
end)

T.test('BUG-458: walls that stand (our fallback): seal.locked_out names the citizen and the places outside and the tiles ' ..
       'beside which the groups part', function()
  local W = fort(true)
  SW.build_wall(W, 30, 30, G)
  SW.build_wall(W, 35, 20, G)
  local ok, r = W.K.call('seal', 'locked_out', {{30, 30, G}, {35, 20, G}, {22, 22, G}})
  T.ok(ok)
  T.eq({r.known, r.n}, {true, 1})
  T.eq(r.cits[1].id, 3)
  local pk = {}
  for _, p in ipairs(r.places) do pk[#pk + 1] = p.kind end
  table.sort(pk)
  T.eq(pk, {'farm', 'well'})
  table.sort(r.at)
  T.eq(r.at, {'30,30,9', '35,20,9'}, 'the tile 22,22 inside the fort parts nothing')
  -- an open door spot: nobody locked out
  local W2 = fort(true)
  SW.build_wall(W2, 30, 30, G)
  local ok2, r2 = W2.K.call('seal', 'locked_out', {{30, 30, G}})
  T.ok(ok2)
  T.eq({r2.known, r2.n, #r2.places, #r2.at}, {true, 0, 0, 0}, 'one way left: the group is one')
end)

---------------------------------------------------------------- the runner
local DAY = 1200
local SX, SY, Z = 114, 73, 143
local AT = SX .. ',' .. SY .. ',' .. Z
local SEAL = 'c1a1ab60b6183f0601'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function stuck(W, runs) for _ = 1, runs or 7 do H.runs(W, 1) end end
local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end

-- o: cuts (the wall_cuts answer), lo (the locked_out answer), esc (esc_days)
local function rworld(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  require('dfllm.aqshaft').CFG.on = true
  local W = H.world{tag = o.tag, map_size = {16, 16, 160},
                    cfg = o.esc and {baseline = {v = 2, runner = {seal_first = {esc_days = o.esc}}}} or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX - 2, SY, Z, SX + 2, SY)
  W.tile(SX, SY + 1, Z).c = '#'
  W.bs = {[AT] = {id = 900, kind = 'Door', job = 4711, susp = true, work = false, who = 'buildingplan', planned = true,
                  line = 'job 4711 suspended by buildingplan: waits for door x1 (0 free, 5 ordered)'}}
  W.cuts = o.cuts
  W.lo = o.lo
  W.door_calls = {}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z) return W.bs[x .. ',' .. y .. ',' .. z] end,
          state = function() return {stock = W.ctl.stock} end,
          seal_doors = function(K, n) W.door_calls[#W.door_calls + 1] = n; return 1 end})
  W.load({name = 'seal', every = {ticks = 50},
          opening_ways = function() return {known = true, routes = 2, here = true, here_closable = false, others = 1, age = 0} end,
          wall_cuts = function(K, tiles) W.asked = tiles; return W.cuts end,
          locked_out = function(K, tiles) return W.lo end})
  W.load(runner)
  W.state()
  return W
end

local function seal_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = AT .. ' floor'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end

local CUT = {known = true, n = 2, total = 9, visited = 40, partial = false,
             cuts = {{kind = 'farm', x = 98, y = 75, z = 138, id = 5}, {kind = 'citizen', x = 112, y = 72, z = 138, id = 26272}}}

T.test('BUG-458: the wall fallback holds when the wall would cut the farm and the manager off: the door stays, the reason is ' ..
       'said once, a door task is asked for (economy.seal_doors), no SEAL_WALLED, no quickfort undo', function()
  local W = rworld{tag = 'b458a', cuts = CUT}
  H.place(W, SEAL, seal_doc())
  stuck(W, 20)
  T.eq(#W.find_events('SEAL_WALLED'), 0, 'old code: the door became a wall after 5 days')
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0)
  T.eq(logs(W, 'door ' .. AT .. ' stays a door: a wall would cut off 2 (farm 98,75,138, citizen 112,72,138)'), 1,
       'one kern.log line')
  T.ok(#W.door_calls >= 1 and W.door_calls[1] == 1, 'the door is asked for as a workshop task: ' .. T.show(W.door_calls))
  T.eq(W.asked[1], {SX, SY, Z}, 'the tile to be closed is the question')
  -- the cut is gone (the farm is reachable another way): the wall is allowed again
  W.cuts = {known = true, n = 0, cuts = {}, total = 9, visited = 40, partial = false}
  stuck(W, 4)
  T.eq(#W.find_events('SEAL_WALLED'), 1)
end)

T.test('BUG-458: a reach check that ran out of tiles (partial) or does not know the citizens holds the wall back too', function()
  local W = rworld{tag = 'b458b', cuts = {known = true, n = 1, total = 3, visited = 60000, partial = true,
                                          cuts = {{kind = 'depot', x = 1, y = 2, z = 3, id = 1}}}}
  H.place(W, SEAL, seal_doc())
  stuck(W, 14)
  T.eq(#W.find_events('SEAL_WALLED'), 0)
  T.eq(logs(W, 'stays a door: a wall cannot be proven safe: the reach check ran out of tiles'), 1)
  local W2 = rworld{tag = 'b458c', cuts = {known = false, why = 'no citizen on a walk group'}}
  H.place(W2, SEAL, seal_doc())
  stuck(W2, 14)
  T.eq(#W2.find_events('SEAL_WALLED'), 0)
  T.eq(logs(W2, "stays a door: a wall cannot be proven safe: the citizens' reach is not known"), 1)
end)

T.test('BUG-458: seal_stalled after esc_days: no wall command where the wall would cut citizens off; the door as a task and ' ..
       'by hand (order.add ConstructDoor)', function()
  local W = rworld{tag = 'b458d', cuts = CUT, esc = 6}
  H.place(W, SEAL, seal_doc())
  stuck(W, 24)
  local a
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'seal_stalled' then a = a or e end end
  T.ok(a, 'asked')
  T.eq(a.d.cmd, nil, 'old code: bp.cancel then bp.place close=wall')
  T.ok(a.d.how:find('^no wall %(a wall would cut off 2'), a.d.how)
  T.ok(a.d.how:find('order.add', 1, true) and a.d.how:find('ConstructDoor', 1, true), a.d.how)
  T.ok(#a.d.how <= 200, #a.d.how)
end)

T.test('BUG-458: walls that stand and shut citizens out: DECISION_NEEDED locked_out with the citizens, the places, the tiles ' ..
       'and the reopen command; again only after 30 days; bp.cancel reopen takes our wall down (quickfort undo), never ' ..
       'another wall', function()
  local W = rworld{tag = 'b458e', cuts = {known = true, n = 0, cuts = {}, total = 2, visited = 4, partial = false}}
  H.place(W, SEAL, seal_doc())
  stuck(W, 14)
  T.eq(#W.find_events('SEAL_WALLED'), 1, 'the wall went up (nothing to cut off then)')
  W.lo = {known = true, n = 2, cits = {{id = 26272, x = 112, y = 72, z = 138}}, places = {{kind = 'farm', x = 98, y = 75, z = 138}},
          at = {AT}}
  stuck(W, 2)
  local ev = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'locked_out' then ev[#ev + 1] = e end end
  T.eq(#ev, 1, 'asked once')
  local d = ev[1].d
  T.eq({ev[1].cls, d.n, d.at, d.units, d.places, d.proj}, {'A', 2, {AT}, {26272}, {'farm 98,75,138'}, SEAL})
  T.eq(d.cmd, 'dfllm cmd bp.cancel \'{"proj":"' .. SEAL .. '","reopen":"' .. AT .. '"}\'')
  T.ok(ev[1].msg:find('LOCKED OUT: our wall at ' .. AT .. ' shuts 2 citizen(s)', 1, true), ev[1].msg)
  stuck(W, 6)
  local again = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'locked_out' then again = again + 1 end end
  T.eq(again, 1, 'not on every look')
  -- a wall that is not ours
  local r = W.inbox('bp.cancel', {proj = SEAL, reopen = '1,2,3'})
  T.eq(r.ok, false)
  T.ok(r.msg:find('not a wall the kernel built', 1, true), r.msg)
  T.eq(#H.qf_calls(W, 'build', 'undo'), 1, 'only the undo of the planned door before it was walled')
  -- ours
  r = W.inbox('bp.cancel', {proj = SEAL, reopen = AT})
  T.eq(r.ok, true, r.msg)
  local undo = H.qf_calls(W, 'build', 'undo')
  T.eq(#undo, 2)
  T.eq(undo[2].pos, {SX, SY, Z})
  T.ok(logs(W, 'wall at ' .. AT .. ' taken down by bp.cancel reopen') == 1)
  -- the record is gone: the same tile again is refused
  r = W.inbox('bp.cancel', {proj = SEAL, reopen = AT})
  T.eq(r.ok, false)
end)

T.test('BUG-458: nobody outside, no place outside: no locked_out question', function()
  local W = rworld{tag = 'b458f', cuts = {known = true, n = 0, cuts = {}, total = 2, visited = 4, partial = false}}
  H.place(W, SEAL, seal_doc())
  stuck(W, 14)
  W.lo = {known = true, n = 0, cits = {}, places = {}, at = {}}
  stuck(W, 4)
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do T.ok(e.d.id ~= 'locked_out', 'no question') end
end)

T.test('BUG-458: bp.place of a seal with a constructed wall that would cut the farm and the manager off is refused, with the doors ' ..
       'as the way; a seal of doors, a wall that cuts nothing and an unknown reach are placed', function()
  local W = rworld{tag = 'b458g', cuts = CUT}
  local doc = seal_doc()
  doc.stages[1].chunks[1].cells[1][4] = 'Cw'
  doc.materials = {wall = 1}
  local r = H.place(W, SEAL, doc)
  T.eq(r.ok, false, 'old code: queued')
  T.ok(r.msg:find('refused: the seal walls (1) would cut 2 off the main walk group (farm 98,75,138, citizen 112,72,138)', 1, true), r.msg)
  T.ok(r.msg:find('close with doors', 1, true), r.msg)
  -- doors: no objection
  local W2 = rworld{tag = 'b458h', cuts = CUT}
  r = H.place(W2, SEAL, seal_doc())
  T.eq(r.ok, true, r.msg)
  -- walls that cut nothing: placed
  local Wn = rworld{tag = 'b458i1', cuts = {known = true, n = 0, cuts = {}, total = 3, visited = 9, partial = false}}
  local d2 = seal_doc()
  d2.stages[1].chunks[1].cells[1][4] = 'Cw'
  d2.materials = {wall = 1}
  r = H.place(Wn, SEAL, d2)
  T.eq(r.ok, true, tostring(r.msg))
  -- review: an unknown reach and a partial flood fail closed, as the runner's fallback does
  for i, cuts in ipairs({{known = false, why = 'x'}, {known = true, n = 1, cuts = {}, partial = true}}) do
    local W3 = rworld{tag = 'b458j' .. i, cuts = cuts}
    local d3 = seal_doc()
    d3.stages[1].chunks[1].cells[1][4] = 'Cw'
    d3.materials = {wall = 1}
    r = H.place(W3, SEAL, d3)
    T.eq(r.ok, false, 'case ' .. i .. ': ' .. tostring(r.msg))
    T.ok(r.msg:find('cannot be proven safe', 1, true) and r.msg:find('close with doors', 1, true), r.msg)
  end
  -- a repair closure with walls is checked too
  local W4 = rworld{tag = 'b458k', cuts = CUT}
  local d4 = seal_doc()
  d4.tpl, d4.class = 'repair', 'defense'
  d4.stages[1].chunks[1].cells[1][4] = 'Cw'
  d4.materials = {wall = 1}
  r = H.place(W4, 'rp458', d4)
  T.eq(r.ok, false, tostring(r.msg))
  T.ok(r.msg:find('refused: the repair walls (1) would cut 2', 1, true), r.msg)
end)

T.test('BUG-458 review: the second wall path (door_walls: quickfort refused the door) holds the same reach check: the ' ..
       'door stays, a door task is asked for; with nothing to cut the wall goes up', function()
  local W = rworld{tag = 'b458l', cuts = CUT}
  W.unsuitable[AT] = true
  H.place(W, SEAL, seal_doc())
  stuck(W, 3)
  T.eq(logs(W, 'door unsuitable at ' .. SX .. ',' .. SY .. ',' .. Z .. ': wall instead'), 0, 'old code: a wall instead')
  T.eq(logs(W, 'stays a door: a wall would cut off 2 (farm 98,75,138, citizen 112,72,138)') >= 1, true)
  T.ok(#W.door_calls >= 1, 'the door is asked for as a workshop task')
  local W2 = rworld{tag = 'b458m', cuts = {known = true, n = 0, cuts = {}, total = 2, visited = 4, partial = false}}
  W2.unsuitable[AT] = true
  H.place(W2, SEAL, seal_doc())
  stuck(W2, 3)
  T.eq(logs(W2, 'door unsuitable at ' .. SX .. ',' .. SY .. ',' .. Z .. ': wall instead'), 1, 'nothing to cut: the wall instead')
  -- an unknown reach holds the wall back too
  local W3 = rworld{tag = 'b458n', cuts = {known = false, why = 'no citizen on a walk group'}}
  W3.unsuitable[AT] = true
  H.place(W3, SEAL, seal_doc())
  stuck(W3, 3)
  T.eq(logs(W3, ': wall instead'), 0)
end)

T.test('BUG-458 review: LOCKED_OUT also finds a wall that came in through bp.place close=wall (no sw / dw record, the project done), and reopen takes it down',
       function()
  local W = rworld{tag = 'b458o', cuts = {known = true, n = 0, cuts = {}, total = 2, visited = 4, partial = false}}
  local d = seal_doc()
  d.stages[1].chunks[1].cells[1][4] = 'Cw'
  d.materials = {wall = 1}
  local r = H.place(W, SEAL, d)
  T.eq(r.ok, true, tostring(r.msg))
  stuck(W, 14)
  T.ok(W.bld_at[AT], 'the wall is under construction')
  W.buildings[W.bld_at[AT]], W.bld_at[AT] = nil, nil           -- built: a finished construction is no building, the snapshot shows 'C'
  W.tile(SX, SY, Z).c = 'C'
  W.lo = {known = true, n = 1, cits = {{id = 7, x = 112, y = 72, z = 138}}, places = {{kind = 'farm', x = 98, y = 75, z = 138}},
          at = {AT}}
  stuck(W, 4)
  local ev = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'locked_out' then ev[#ev + 1] = e end end
  T.eq(#ev, 1, 'old code: only the sw / dw records were looked at')
  T.eq(ev[1].d.at, {AT})
  T.eq(H.proj(W, SEAL).done, 1, 'the project is done: forget() dropped its records and the document, the wall stays')
  r = W.inbox('bp.cancel', {proj = SEAL, reopen = AT})
  T.eq(r.ok, true, tostring(r.msg))
  r = W.inbox('bp.cancel', {proj = SEAL, reopen = AT})
  T.eq(r.ok, false, 'the record is gone with the wall')
end)
T.done()
