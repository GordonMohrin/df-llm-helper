-- BUG-566 (Run 16b i2 y398 'PERIMETER OPEN 123 d' from changing sapling / shrub surface tiles and `inspect entrances key=refresh` clearing it,
-- Run 16d i4 y397 'SEAL_LEAK shrub' beside the R31 fix BUG-503): (1) a tree crown is up to four levels above the ground, not only one;
-- (2) an opening whose tile is a sapling or a shrub on the surface is vegetation only: it stays on inspect entrances' list but readiness
-- (PERIMETER OPEN, R0 open_perimeter, the pop hold) and SEAL_LEAK leave it out; a plant in a rock doorway (a cave tile) still counts;
-- (3) a check that names a way in without a door is re-run (BFS) every game day, not every 28.
local T = require('testlib')
local SW = require('seal_world')
local X = require('wp6_world')

---------------------------------------------------------------- seal: the gatehouse of test_bug503_505_sealreach.lua
local G = 9
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}, {26, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}
local BRANCH, SAPLING = 30, 31
local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function gatehouse(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = MAN}, mode = opts.mode}
  df.tiletype.attrs[BRANCH] = {shape = df.tiletype_shape.BRANCH, material = df.tiletype_material.TREE, special = df.tiletype_special.NONE}
  df.tiletype.attrs[SAPLING] = {shape = df.tiletype_shape.SAPLING, material = df.tiletype_material.PLANT, special = df.tiletype_special.NONE}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {opts.down and '=' or 'H'}, 20, 25)    -- O1 raised (the fort expects to be sealed) or lowered (it leaks by design)
  SW.draw(W, G, {'+'}, 30, 30)
  SW.draw(W, G, {'.'}, 35, 20)                          -- a gap in the north wall
  if opts.crown then
    -- the west wall gap 20,27 and a strip of ground roofed by a crown `opts.crown` levels up: air in between
    SW.draw(W, G, {'.'}, 20, 27)
    SW.fill(W, G, 15, 27, 19, 27, '.')
    for dz = 1, opts.crown - 1 do SW.fill(W, G + dz, 15, 27, 19, 27, '_') end
    SW.fill(W, G + opts.crown, 15, 27, 19, 27, '.')
    for x = 15, 19 do W.tiles[SW.key(x, 27, G + opts.crown)].tt = BRANCH end
    if opts.roof then for x = 15, 19 do W.tiles[SW.key(x, 27, G + opts.roof)].tt = SW.T.floor end end
  end
  if opts.plant then W.tiles[SW.key(35, 20, G)].tt = SAPLING end
  if opts.cave then W.tiles[SW.key(35, 20, G)].des.subterranean = true end
  W.o1 = W.dyn[SW.key(20, 25, G)]
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.gate = SW.fake('gate', {state = function(K, b) if b == nil then return {} end return opts.down and 'down' or 'up' end, fire = function(K, s) end})
  W.load(W.gate)
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  W.load(seal())
  return W
end
local function inspect(W, key)
  local r = W.inbox('inspect', {what = 'entrances', key = key})
  T.ok(r.ok, r.msg)
  return r.data
end

T.test('BUG-566 (1): a crown three levels up (air between) is open sky: the first leak is the wall gap, not the rim of the crown', function()
  local W = gatehouse{crown = 3}
  W.run(400, {skip = 9})
  local d = inspect(W)
  T.eq(d.first.pos, {35, 20, G}, 'the gap in the north wall is the mouth (old code: the crown rim 15,27)')
  local _, x = W.K.call('seal', 'entrance_doors')
  for _, o in ipairs(x.open) do T.ok(o.pos[1] >= 20, 'no way in at the rim of the crown: ' .. T.show(o.pos)) end
end)

T.test('BUG-566 (1b): a built floor between the ground and the crown is a roof: the strip stays inside', function()
  local W = gatehouse{crown = 3, roof = 2}
  W.run(400, {skip = 9})
  local _, x = W.K.call('seal', 'entrance_doors')
  local rim = false
  for _, o in ipairs(x.open) do if o.pos[1] < 20 then rim = true end end
  T.ok(rim, 'the rim of the roofed strip is a way in: ' .. T.show(x.open))
end)

T.test('BUG-566 (2): a sapling on the surface mouth is vegetation (veg 1, still listed); the same tile as a cave tile or a floor is not',
       function()
  local W = gatehouse{plant = true}
  W.run(400, {skip = 9})
  local _, x = W.K.call('seal', 'entrance_doors')
  local o
  for _, e in ipairs(x.open) do if e.pos[1] == 35 and e.pos[2] == 20 then o = e end end
  T.ok(o, 'the sapling mouth is listed: ' .. T.show(x.open))
  T.eq({o.kind, o.veg}, {'sapling', 1})
  local found = false
  for _, w in ipairs(inspect(W).ways) do if w:find('sapling', 1, true) then found = true end end
  T.ok(found, 'inspect entrances still names it')
  local W2 = gatehouse{plant = true, cave = true}
  W2.run(400, {skip = 9})
  local _, x2 = W2.K.call('seal', 'entrance_doors')
  local o2
  for _, e in ipairs(x2.open) do if e.pos[1] == 35 and e.pos[2] == 20 then o2 = e end end
  T.ok(o2 and o2.veg == nil, 'a plant in a cave doorway counts: ' .. T.show(o2))
  local W3 = gatehouse{}
  W3.run(400, {skip = 9})
  local _, x3 = W3.K.call('seal', 'entrance_doors')
  for _, e in ipairs(x3.open) do T.ok(e.veg == nil, 'a floor is no vegetation') end
end)

T.test('BUG-566 (2b): SEAL_LEAK is not raised for a vegetation-only leak in a siege, and is for a plain floor gap', function()
  local W = gatehouse{plant = true, mode = 'SIEGE'}
  W.run(900, {skip = 9})
  T.eq(#W.find_events('SEAL_LEAK'), 0, 'old code: SEAL_LEAK (sapling no door)')
  local W2 = gatehouse{mode = 'SIEGE'}
  W2.run(900, {skip = 9})
  T.ok(#W2.find_events('SEAL_LEAK') >= 1, 'a floor gap is still a leak')
end)

T.test('BUG-566 (3): a way in whose tile changed (the sapling died) is looked at again within a day, its BFS runs; an unchanged one is not re-run',
       function()
  local W = gatehouse{plant = true, down = true}
  W.run(1500, {skip = 9})                                       -- the boot checks (refuge) are over
  local d0 = inspect(W)
  T.ok(d0.bfs, 'a BFS ran')
  W.run(1200 * 3, {skip = 9})
  T.eq(inspect(W).bfs, d0.bfs, 'nothing changed: the answer is re-used (FR-62)')
  W.tiles[SW.key(35, 20, G)].tt = SW.T.floor                   -- the sapling dies: a plain floor gap
  SW.regroup(W)
  W.run(1200 * 2, {skip = 9})
  local d1 = inspect(W)
  T.ok(d1.bfs > d0.bfs, 'a BFS ran again: ' .. tostring(d0.bfs) .. ' -> ' .. tostring(d1.bfs))
  local _, x = W.K.call('seal', 'entrance_doors')
  local o
  for _, e in ipairs(x.open) do if e.pos[1] == 35 and e.pos[2] == 20 then o = e end end
  T.ok(o and o.kind == 'floor' and o.veg == nil, 'the way is a plain floor gap now: ' .. T.show(x.open))
end)

---------------------------------------------------------------- readiness: the perimeter check leaves vegetation out
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local function rworld(entrances)
  local units = X.citizens(50, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = entrances, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, W.seal}, {'sense', 'gate'})
  return W
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

T.test('BUG-566: readiness counts no vegetation-only way in: no open_perimeter, no PERIMETER OPEN, no hold; a floor beside it does',
       function()
  local VEG = {tick = 1, sealed = 0, routes = 2, doors = {{id = 9, pos = {74, 70, 117}}},
               open = {{pos = {81, 75, 139}, kind = 'shrub', veg = 1}, {pos = {66, 102, 139}, kind = 'sapling', veg = 1}}}
  local W = rworld(VEG)
  day(W, 3)
  local r = W.state().ready
  T.eq(r.open, 0, 'old code: 2 ways in')
  T.ok(not has(r.fail, 'open_perimeter'), 'no open_perimeter: ' .. T.show(r.fail))
  T.eq(r.pd, nil)
  T.eq(r.ents, nil)
  local MIX = {tick = 1, sealed = 0, routes = 3, doors = {}, open = {VEG.open[1], {pos = {78, 107, 139}, kind = 'floor'}}}
  local W2 = rworld(MIX)
  day(W2, 3)
  local r2 = W2.state().ready
  T.eq({r2.open, r2.ents}, {1, {'78,107,139 floor'}})
  T.ok(has(r2.fail, 'open_perimeter'))
end)

T.done()
