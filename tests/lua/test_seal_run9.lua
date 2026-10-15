-- seal, the live findings of the Run 9 save (STATUS §0h): FR-59 stored drink, food and seeds (barrels, bins, bags)
-- count for reach, the refuge audit and CUTOFF; FR-63 a stair is read again before it is reported and every stair
-- pair DF walks is accepted; FR-60 the perimeter of a fort without a manifest (sealed openings, perimeter.record);
-- FR-62 the work per frame and per real second, skipped unchanged inputs and an urgent check that pre-empts a
-- background job. k_mock (strict) + tests/lua/seal_world.lua.
local T = require('testlib')
local SW = require('seal_world')

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end
local function has(list, pat)
  for _, s in ipairs(list or {}) do if tostring(s):find(pat, 1, true) then return true end end
  return false
end

---------------------------------------------------------------- the store fort (z 5)
-- room A x2-8 y2-8 (beds, the stockpile; Kern+), corridor y5 x9-11, room B x12-18 y2-8; citizens 1-2 in A, 3-5 in B
local Z = 5
local function fort(opts)
  opts = opts or {}
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}
  local W = SW.new{persist = {manifest = man}}
  SW.fill(W, Z, 0, 0, 20, 10, '#')
  SW.fill(W, Z, 2, 2, 8, 8, '.')
  SW.fill(W, Z, 12, 2, 18, 8, '.')
  SW.fill(W, Z, 9, 5, 11, 5, '.')
  SW.draw(W, Z, {'bb'}, 3, 3)
  if opts.draw then opts.draw(W) end
  SW.regroup(W)
  SW.citizens(W, {{1, 4, 4, Z}, {2, 5, 5, Z}, {3, 14, 4, Z}, {4, 15, 5, Z}, {5, 16, 6, Z}})
  W.burrow('Kern+', {2, 2, Z, 8, 8, Z})
  if opts.stock ~= false then
    -- Run 9: every drink stood in barrels, none on the floor
    for _, p in ipairs({{6, 6}, {7, 6}, {6, 7}}) do
      local b = SW.container(W, 'BARREL', p[1], p[2], Z)
      for _ = 1, 2 do SW.store(SW.item(W, 'DRINK', p[1], p[2], Z, 10), b) end
    end
    local pot = SW.container(W, 'BARREL', 7, 7, Z)               -- prepared meals in a barrel
    SW.store(SW.item(W, 'FOOD', 7, 7, Z, 15), pot)
    SW.store(SW.item(W, 'PLANT', 7, 7, Z, 15), pot)
    local bin = SW.container(W, 'BIN', 16, 7, Z)                 -- seed bags in a bin (two levels)
    for _ = 1, 2 do SW.store(SW.item(W, 'SEEDS', 16, 7, Z, 5), SW.container(W, 'BOX', 16, 7, Z, nil, bin)) end
    -- not stock: a forbidden barrel, a forbidden drink in a good barrel, a bag in a forbidden bin, a barrel a
    -- hauler carries, a waterskin a dwarf wears
    SW.store(SW.item(W, 'DRINK', 6, 8, Z, 100), SW.container(W, 'BARREL', 6, 8, Z, {forbid = true}))
    SW.store(SW.item(W, 'DRINK', 6, 6, Z, 40, {forbid = true}), SW.container(W, 'BARREL', 5, 8, Z))
    local fbin = SW.container(W, 'BIN', 17, 7, Z, {forbid = true})
    SW.store(SW.item(W, 'SEEDS', 17, 7, Z, 50), SW.container(W, 'BOX', 17, 7, Z, nil, fbin))
    local carried = SW.container(W, 'BARREL', 14, 4, Z, nil, {unit = W.unit(3)})
    SW.store(SW.item(W, 'DRINK', 14, 4, Z, 7), carried)
    SW.store(SW.item(W, 'DRINK', 15, 5, Z, 3), {unit = W.unit(4)})
  end
  if opts.more then opts.more(W) end
  local M = seal()
  W.load(M)
  return W, M
end

---------------------------------------------------------------- FR-59
T.test('FR-59: stored drink, food and seeds count (barrels, bins, bags), once per stack unit; carried, worn and ' ..
       'forbidden-container stock does not', function()
  local W = fort()
  W.run(300, {skip = 9})
  local d = inspect(W, 'reach')
  T.eq({d.classes.drink.n, d.classes.drink.main, d.classes.food.n, d.classes.seeds.n, d.classes.seeds.main},
       {60, 60, 30, 10, 10})
  T.eq(d.cut, {food = 0, drink = 0, bed = 0})
  T.ok(not has(d.flags, 'drink') and not has(d.flags, 'food') and not has(d.flags, 'seeds'), table.concat(d.flags, '|'))
  T.eq(d.items.drop, {drink = 0, food = 0, seeds = 0})
  -- the refuge audit sees the barrels in Kern+ (live: "drink 0<7" with 1362 drinks inside)
  local r, msg = inspect(W, 'refuge')
  local k = r.burrows['Kern+']
  T.eq({k.drink, k.food, k.beds, k.ok, k.why}, {60, 30, 2, 1, ''})
  T.ok(msg:find('alert PEACE: Kern+', 1, true), msg)
  local ok, pick = W.K.call('seal', 'alert_burrow', 'ALERT', 'Kern+')
  T.eq({ok, pick}, {true, 'Kern+'})
  T.eq(#evs(W, 'REFUGE_FAIL'), 0)
  T.eq(W.hidden_wg, 0)
end)

T.test('FR-59: CUTOFF fires for stock that only exists in barrels; the blame names the wall', function()
  local W = fort()
  W.run(300, {skip = 9})
  T.eq(#evs(W, 'CUTOFF'), 0)
  SW.build_wall(W, 10, 5, Z)
  W.run(600, {skip = 9})
  local ev = evs(W, 'CUTOFF')
  T.eq(#ev, 1)
  T.eq({ev[1].d.cls, ev[1].d.n, ev[1].d.pos, ev[1].d.why}, {'food', 3, {10, 5, Z}, 'wall'})
  local d = inspect(W, 'reach')
  T.eq(d.cut, {food = 3, drink = 3, bed = 3})
  T.ok(has(d.flags, "drink: none on the citizens' group") and not has(d.flags, 'seeds'), table.concat(d.flags, '|'))
end)

T.test('FR-59/62: the census is skipped while the item vectors keep their sizes; a new barrel is seen by the next ' ..
       'census or at once with key refresh', function()
  local W = fort()
  W.run(300, {skip = 9})
  local d0 = inspect(W, 'reach')
  W.run(9 * 1200, {skip = 9})                    -- 9 quiet days: the weekly census finds nothing changed
  local d1 = inspect(W, 'reach')
  T.eq(d1.items.tick, d0.items.tick, 'no new census')
  T.ok((d1.runs.items_skip or 0) >= 1 and (d1.runs.audit_skip or 0) >= 1, require('dfllm.util.json').encode(d1.runs))
  -- a new barrel of drink in room B: the item vectors grew
  local b = SW.container(W, 'BARREL', 15, 7, Z)
  SW.store(SW.item(W, 'DRINK', 15, 7, Z, 25), b)
  local d2 = inspect(W, 'reach', 'refresh')
  T.eq(d2.classes.drink.n, 85, 'refresh re-reads the stock now')
  local W2 = fort()
  W2.run(300, {skip = 9})
  SW.store(SW.item(W2, 'DRINK', 15, 7, Z, 25), SW.container(W2, 'BARREL', 15, 7, Z))
  W2.run(8 * 1200, {skip = 9})
  local d3 = inspect(W2, 'reach')
  T.eq(d3.classes.drink.n, 85, 'the weekly census')
  T.ok(d3.items.tick > d0.items.tick)
end)

---------------------------------------------------------------- FR-63
T.test('FR-63: every stair pair DF walks is accepted; hidden counterparts are never read', function()
  local W = fort{stock = false, draw = function(W)
    SW.draw(W, Z, {'>'}, 3, 8); SW.draw(W, Z - 1, {'<'}, 3, 8)       -- up stair below a down stair
    SW.draw(W, Z, {'X'}, 4, 8); SW.draw(W, Z - 1, {'<'}, 4, 8)       -- up stair below an up/down stair
    SW.draw(W, Z, {'>'}, 5, 8); SW.draw(W, Z - 1, {'X'}, 5, 8)       -- up/down stair below a down stair
    SW.draw(W, Z, {'<'}, 6, 8); SW.draw(W, Z + 1, {'>'}, 6, 8)       -- down stair above an up stair
    SW.draw(W, Z, {'<'}, 8, 7); SW.draw(W, Z + 1, {'X'}, 8, 7)       -- up/down stair above an up stair
    SW.draw(W, Z, {'>'}, 2, 8); SW.draw(W, Z - 1, {'?'}, 2, 8)       -- hidden below: flagged, never read
  end}
  W.run(400, {skip = 9})
  local d = inspect(W, 'reach')
  local got = {}
  for _, s in ipairs(d.stairs) do got[#got + 1] = table.concat({s[1], s[2], s[3], s[4], s[5]}, ' ') end
  T.eq(got, {'2 8 5 down stair below unrevealed'})
  T.eq(W.hidden_wg, 0)
end)

T.test('FR-63: a flagged stair is read again before it is reported (live Run 9: the stairs below were dug since ' ..
       'the scan)', function()
  local W = fort{stock = false, draw = function(W)
    SW.draw(W, Z, {'>'}, 7, 8)                                      -- the shaft head, rock below (revealed)
    SW.draw(W, Z - 1, {'#'}, 7, 8)
  end}
  W.run(400, {skip = 9})
  local d = inspect(W, 'reach')
  T.eq(#d.stairs, 1)
  T.eq({d.stairs[1][4], d.stairs[1][5]}, {'down stair', 'no stair below'})
  T.ok(has(d.flags, 'stairs: 1 without counterpart (down stair at 7,8,5)'), table.concat(d.flags, '|'))
  -- the miners dig the shaft down (no new scan for 14 days)
  SW.draw(W, Z - 1, {'X'}, 7, 8)
  SW.draw(W, Z - 2, {'<'}, 7, 8)
  SW.regroup(W)
  W.run(100, {skip = 9})
  d = inspect(W, 'reach')
  T.eq(#d.stairs, 0)
  T.ok(not has(d.flags, 'stairs:'), table.concat(d.flags, '|'))
  T.ok(d.scan.tick < W.K.now().tick - 100, 'the scan itself is older')
end)

---------------------------------------------------------------- FR-60 (no manifest)
-- field ',' x0-63 y0-63; fort walls x20-40 y20-30 (natural rock), hall x21-39 y21-29; the opening at 20,25
local G = 9
local function gate_fort(opts)
  opts = opts or {}
  local W = SW.new{}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {opts.open or '.'}, 20, 25)
  if opts.draw then opts.draw(W) end
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.runner = {cells = {}}
  W.load(SW.fake('runner', {repair = function(K, cells)
    W.runner.cells[#W.runner.cells + 1] = cells
    return true, 'rp1'
  end}))
  for k, v in pairs(opts.raw or {}) do W.persist_raw[k] = v end    -- a load of the same save
  local M = seal()
  W.load(M)
  return W, M
end

local function siege(W, destroy)
  W.K.set_mode('SIEGE', 'test')
  W.run(200, {skip = 9})
  if destroy then destroy(); SW.regroup(W) end
  W.K.set_mode('RECOVERY', 'test')
  W.run(300, {skip = 9})
end

T.test('FR-60: a wall the player builds into an opening is recorded when the check finds it sealed; lost in a ' ..
       'siege -> re-queued + PERIMETER_BROKEN', function()
  local W = gate_fort()
  W.run(400, {skip = 9})
  local e, msg = inspect(W, 'entrances')
  T.ok(msg:find('LEAK at 20,25,9 (floor no door)', 1, true), msg)
  local p = inspect(W, 'perimeter')
  T.eq({p.n, p.open}, {0, 1})
  SW.build_wall(W, 20, 25, G)                      -- walled up by hand, no project, no manifest
  W.run(300, {skip = 9})
  e = inspect(W, 'entrances')
  T.eq(e.sealed, true)
  p = inspect(W, 'perimeter')
  T.eq({p.n, p.by.wall, p.open, p.pieces[1]}, {1, 1, 0, {'20,25,9', 'wall', 'entrance'}})
  siege(W, function() SW.draw(W, G, {'.'}, 20, 25) end)
  local ev = evs(W, 'PERIMETER_BROKEN')
  T.eq(#ev, 1)
  T.eq({ev[1].d.pos, ev[1].d.kinds, ev[1].d.requeued}, {{20, 25, G}, {'wall'}, 1})
  T.eq(W.runner.cells, {{{20, 25, G, 'Cw'}}})
end)

T.test('FR-60: a bridge raised over the opening is a gate piece (by its footprint); destroyed in a siege it is ' ..
       'reported, never re-queued', function()
  -- the bridge spans the moat in front of the opening (outside); the doors and bridges on an opening's inside tile
  -- are learned in PEACE already
  local W = gate_fort{draw = function(W)
    SW.draw(W, G, {'#', '=', '#'}, 19, 24, {outside = true})      -- rock on both sides: no diagonal step past it
  end}
  W.run(400, {skip = 9})
  T.eq({inspect(W, 'perimeter').open, inspect(W, 'perimeter').n}, {1, 0})
  local br = W.dyn[SW.key(19, 25, G)]
  br.gate_flags.raised = true                     -- an unmanaged lever pull
  SW.regroup(W)
  W.run(300, {skip = 9})
  local p = inspect(W, 'perimeter')
  T.eq({p.n, p.by.bridge, p.pieces[1]}, {1, 1, {'19,25,9', 'bridge', 'entrance'}})
  siege(W, function()
    W.dyn[SW.key(19, 25, G)] = nil
    local v = df.global.world.buildings.other.BRIDGE
    for i = #v - 1, 0, -1 do if v[i] == br then v:erase(i) end end
    SW.draw(W, G, {','}, 19, 25)
  end)
  local ev = evs(W, 'PERIMETER_BROKEN')
  T.eq(#ev, 1)
  T.eq({ev[1].d.kinds, ev[1].d.requeued}, {{'bridge'}, 0})
  T.eq(W.runner.cells, {}, 'a bridge is never re-queued')
end)

T.test('FR-60: a recorded wall the player removes in PEACE is retired, never rebuilt', function()
  local W = gate_fort()
  W.run(400, {skip = 9})
  SW.build_wall(W, 20, 25, G)
  W.run(300, {skip = 9})
  T.eq(inspect(W, 'perimeter').n, 1)
  SW.draw(W, G, {'.'}, 20, 25)                     -- opened again by the player
  SW.regroup(W)
  W.run(300, {skip = 9})
  siege(W)
  T.eq(#evs(W, 'PERIMETER_BROKEN'), 0)
  T.eq(W.runner.cells, {})
  T.eq(inspect(W, 'perimeter').n, 0)
end)

T.test('FR-60/62: the known openings and the edge tiles survive a load; the opening walled up after it is ' ..
       'recorded', function()
  local W = gate_fort()
  W.run(400, {skip = 9})
  local e0 = inspect(W, 'reach').edges
  T.eq(inspect(W, 'perimeter').open, 1)
  W.unload()
  local W2 = gate_fort{raw = W.persist_raw}
  W2.run(50, {skip = 9})
  local d = inspect(W2, 'reach')
  T.eq(d.edges, e0, 'no edge scan after the load')
  T.eq(d.runs.edges, nil)
  T.eq(inspect(W2, 'perimeter').open, 1)
  SW.build_wall(W2, 20, 25, G)
  W2.run(300, {skip = 9})
  local p = inspect(W2, 'perimeter')
  T.eq({p.n, p.pieces[1]}, {1, {'20,25,9', 'wall', 'entrance'}})
end)

T.test('FR-60: perimeter.record on a fort sealed from the start records the constructed walls between the hall ' ..
       'and the field, not the inner ones', function()
  local W = gate_fort{open = 'C', draw = function(W)
    for y = 21, 29 do SW.draw(W, G, {'C'}, 20, y) end              -- the west wall is masonry
    SW.draw(W, G, {'C', 'C', 'C'}, 30, 21)                         -- an inner partition
  end}
  W.run(400, {skip = 9})
  local e = inspect(W, 'entrances')
  T.eq({e.sealed, inspect(W, 'perimeter').n}, {true, 0})
  local r = W.inbox('perimeter.record', {})
  T.ok(r.ok, r.msg)
  T.eq(r.data.queued, 1)
  W.run(100, {skip = 9})
  local p, msg = inspect(W, 'perimeter')
  T.eq({p.n, p.by.wall, p.rec.added, p.rec.sealed}, {9, 9, 9, 1})
  T.ok(msg == '9 perimeter pieces', msg)
  for _, piece in ipairs(p.pieces) do
    T.ok(piece[1]:match('^20,') and piece[3] == 'seal', piece[1])
  end
end)

---------------------------------------------------------------- FR-62
T.test('FR-62: in PEACE a construction change re-uses the last BFS while no known opening changed', function()
  local W = gate_fort()
  W.run(400, {skip = 9})
  local n0 = #evs(W, 'SEAL')
  for i = 1, 3 do
    SW.build_wall(W, 30, 21 + i, G)                -- unrelated walls inside the hall, a day apart
    W.run(1300, {skip = 9})
  end
  local d = inspect(W, 'reach')
  T.ok((d.runs.bfs_skip or 0) >= 2, require('dfllm.util.json').encode(d.runs))
  T.eq(#evs(W, 'SEAL'), n0, 'a re-used answer is no news')
  SW.build_wall(W, 20, 25, G)                      -- the opening itself: the cheap check sees it, the BFS runs
  W.run(300, {skip = 9})
  T.eq(inspect(W, 'entrances').sealed, true)
end)

T.test('FR-62: an urgent request (a lever pull) replaces a slow background run of the same job; ' ..
       'perimeter.record survives it', function()
  local W, M = gate_fort()
  W.load(SW.fake('gate', {state = function(K, b) if b == nil then return {} end return 'down' end,
                          fire = function(K, s) K.emit('GATE', 'C', 'G ' .. s, {bridge = 'G', state = s}) end}))
  W.run(400, {skip = 9})
  M.CFG.bfs_every, M.CFG.rate, M.CFG.min_slice = 0, 100, 50       -- every check walks; the background crawls
  SW.build_wall(W, 30, 22, G)                      -- an unrelated wall: a background check with a BFS
  local busy
  for _ = 1, 200 do
    W.run(9, {skip = 9})
    busy = inspect(W, 'reach').busy
    if has(busy, 'seal') then break end
  end
  T.ok(has(busy, 'seal'), 'the background check runs')
  local n0 = #evs(W, 'SEAL')
  T.ok(W.inbox('perimeter.record', {}).ok)
  W.K.call('gate', 'fire', 'up')
  W.run(200, {skip = 9})
  local s = evs(W, 'SEAL')
  T.eq(#s, n0 + 1, 'one answer, the urgent one')
  T.ok(s[#s].d.why == 'lever' or s[#s].d.why == 'record', s[#s].d.why)
  local d = inspect(W, 'reach')
  T.eq(d.runs.dropped, 1)
  local p = inspect(W, 'perimeter')
  T.eq(p.queued, 0)
  T.ok(p.rec ~= nil, 'the record request was kept and served')
end)

-- a fort the size of Run 9's core: 128 x 128 x 30 map, the surface field, five 40 x 40 halls on z20-24 joined by a
-- stair to the surface, 5 citizens, 20 beds, 2,980 stock items (barrels, bags in bins, floor stacks, fruit outside)
local function big_fort()
  local W = SW.new{map_size = {8, 8, 30}}
  W.ms_per_frame = 10                              -- 100 frames/s at 5 ticks a frame: 500 ticks/s (PEACE)
  SW.fill(W, 25, 0, 0, 127, 127, ',')
  for z = 20, 24 do
    SW.fill(W, z, 39, 39, 80, 80, '#')
    SW.fill(W, z, 40, 40, 79, 79, '.')
    SW.draw(W, z, {'X'}, 60, 60)
  end
  SW.draw(W, 25, {'X'}, 60, 60, {outside = true})
  for i = 0, 19 do SW.draw(W, 23, {'b'}, 41 + i, 41) end
  SW.regroup(W)
  SW.citizens(W, {{1, 50, 50, 20}, {2, 51, 50, 21}, {3, 52, 50, 22}, {4, 53, 50, 23}, {5, 54, 50, 24}})
  for i = 0, 99 do                                 -- 100 barrels, 10 drink stacks of 1 each
    local x, y = 40 + i % 20, 60 + i // 20
    local b = SW.container(W, 'BARREL', x, y, 20)
    for _ = 1, 10 do SW.store(SW.item(W, 'DRINK', x, y, 20, 1), b) end
  end
  for i = 0, 299 do                                -- 300 floor tiles, 5 plant stacks each
    for _ = 1, 5 do SW.item(W, 'PLANT', 40 + i % 30, 70 + i // 30, 21, 2) end
  end
  for i = 0, 9 do                                  -- 10 bins, 5 bags each, 10 seed stacks per bag
    local bin = SW.container(W, 'BIN', 60 + i, 45, 22)
    for _ = 1, 5 do
      local bag = SW.container(W, 'BOX', 60 + i, 45, 22, nil, bin)
      for _ = 1, 10 do SW.store(SW.item(W, 'SEEDS', 60 + i, 45, 22, 1), bag) end
    end
  end
  for i = 0, 179 do SW.item(W, 'PLANT_GROWTH', (i * 7) % 128, (i * 13) % 128, 25, 1) end   -- fallen fruit
  -- every DF read seal may do, counted
  local n = 0
  local function count(tbl, names)
    for _, name in ipairs(names) do
      local f = tbl[name]
      tbl[name] = function(...) n = n + 1; return f(...) end
    end
  end
  count(dfhack.maps, {'getTileFlags', 'getWalkableGroup', 'getTileType', 'isTileVisible'})
  count(dfhack.items, {'getPosition', 'getContainer', 'getHolderUnit', 'getHolderBuilding'})
  count(dfhack.burrows, {'isAssignedTile', 'isAssignedBlockTile', 'listBlocks', 'findByName'})
  count(dfhack.buildings, {'findAtTile'})
  W.reads = function() return n end
  local M = seal()
  W.load(M)
  return W, M
end

T.test('FR-62: the work per frame and per real second is bounded on a Run 9 sized fort; the results still ' ..
       'come', function()
  local W, M = big_fort()
  local C = M.CFG
  local max_f, per_s, s_reads = 0, {}, 0
  local frames = 100 * 120                         -- 120 s real time = 60,000 ticks = 50 days
  for f = 1, frames do
    local r0 = W.reads()
    W.frame(5)
    local d = W.reads() - r0
    if d > max_f then max_f = d end
    s_reads = s_reads + d
    if f % 100 == 0 then per_s[#per_s + 1] = s_reads; s_reads = 0 end
  end
  -- one frame: the slice cap (a work unit is about one DF read; one last step may overshoot a little)
  T.ok(max_f <= C.work * 1.25, 'most reads in one frame: ' .. max_f)
  -- per second, once the first results are in (boot runs at the urgent rate): the background rate
  local worst, sum = 0, 0
  for i = 21, #per_s do worst = math.max(worst, per_s[i]); sum = sum + per_s[i] end
  local avg = sum / (#per_s - 20)
  T.ok(worst <= C.rate * 1.25, 'most reads in one second: ' .. worst)
  T.ok(avg <= C.rate * 0.5, 'average reads per second: ' .. avg)
  -- and the answers are there
  local d = inspect(W, 'reach')
  T.eq({d.classes.drink.n, d.classes.food.n, d.classes.seeds.n, d.classes.bed.n}, {1000, 3000 + 180, 500, 20})
  T.eq(d.cit.n, 5)
  T.ok(d.edges.n > 0 and d.edges.n <= 32, 'one edge tile per run, not the whole border: ' .. d.edges.n)
  T.ok(d.runs.items_skip >= 1 and d.runs.audit_skip >= 1, require('dfllm.util.json').encode(d.runs))
  T.eq(d.scan.partial, 0)
  local e = inspect(W, 'entrances')
  T.ok(e.routes == 1 and e.first.pos[1] == 60 and e.first.pos[2] == 60, require('dfllm.util.json').encode(e.first))
  T.eq(W.hidden_wg, 0)
end)

T.test('FR-62: an urgent check (a lever pull) pre-empts a background scan and finishes first', function()
  local W, M = big_fort()
  W.load(SW.fake('gate', {state = function(K, b) if b == nil then return {} end return 'down' end,
                          fire = function(K, s) K.emit('GATE', 'C', 'G ' .. s, {bridge = 'G', state = s}) end}))
  W.load(SW.fake('runner', {done = function(K)
    K.emit('PROJECT_DONE', 'B', 'p1 done', {proj = 'p1', tpl = 'walls'})
  end}))
  for _ = 1, 100 * 10 do W.frame(5) end            -- boot settles
  W.K.call('runner', 'done')
  local busy
  for _ = 1, 100 * 30 do                           -- the scan it asks for starts after CFG.scan_min
    W.frame(5)
    busy = inspect(W, 'reach').busy
    if has(busy, 'scan') then break end
  end
  T.ok(has(busy, 'scan'), 'a background scan runs')
  local n0 = #evs(W, 'SEAL')
  W.K.call('gate', 'fire', 'up')
  local frames, during
  for f = 1, 600 do
    W.frame(5)
    if #evs(W, 'SEAL') > n0 then
      frames, during = f, has(inspect(W, 'reach').busy, 'scan')
      break
    end
  end
  T.ok(frames and frames <= 300, 'the lever check took ' .. tostring(frames) .. ' frames')
  T.ok(during, 'the scan was parked, not finished first')
  T.eq(evs(W, 'SEAL')[n0 + 1].d.why, 'lever')
end)

T.done()
