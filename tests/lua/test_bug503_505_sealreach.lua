-- BUG-503 / BUG-504 / BUG-505 (Run 16a i1 Basementflew y396-y398, Run 16b i2 Roadvises y377; offline, live-untested).
-- BUG-503: a surface tile under a tree crown has `outside` false although only branches roof it, so the entrance check's "inside" ran
--   out through the forest and its rim (the ways in: 'sapling no door', 'shrub no door') moved with every crown; such a tile is open sky.
-- BUG-504: the seal question (DECISION_NEEDED seal_stalled) recommended a wall 'where the citizens keep another way' without naming
--   it; seal.opening_ways now lists the ways that stay (`where`), the question names them, and says 'no wall' where none stays.
-- BUG-505: runner.repair (seal.lua KP.extend / KP.close / the perimeter repair / the lost-bridge repair) queued `Cw` walls with no
--   reach check; its walls that would cut a citizen or a farm off become doors, a closure is refused, the refuge plug is exempt.
local T = require('testlib')
local SW = require('seal_world')
local H = require('runner_world')
local runner = require('dfllm.runner')

---------------------------------------------------------------- BUG-503 / BUG-504 (the gatehouse of test_seal_ways.lua)
local G = 9
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}, {26, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}
local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local BRANCH = 30
local function gatehouse(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = MAN}}
  df.tiletype.attrs[BRANCH] = {shape = df.tiletype_shape.BRANCH, material = df.tiletype_material.TREE,
                               special = df.tiletype_special.NONE}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'H'}, 20, 25)                         -- O1 raised: closed
  if opts.door then SW.draw(W, G, {'+'}, 30, 30) end
  if opts.gap then SW.draw(W, G, {'.'}, 35, 20) end
  if opts.crown then
    -- a gap in the west wall at 20,27 and a strip of crown-roofed ground west of it: 'inside' by its designation (roofed),
    -- branches on the level above
    SW.draw(W, G, {'.'}, 20, 27)
    SW.fill(W, G, 15, 27, 19, 27, '.')
    SW.fill(W, G + 1, 15, 27, 19, 27, '.')
    for x = 15, 19 do W.tiles[SW.key(x, 27, G + 1)].tt = BRANCH end
  end
  W.o1 = W.dyn[SW.key(20, 25, G)]
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.gate_state = 'up'
  W.gate = SW.fake('gate', {state = function(K, b) if b == nil then return {} end return W.gate_state end,
                            fire = function(K, s) end})
  W.load(W.gate)
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  W.load(seal())
  return W
end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

T.test('BUG-503: a strip of ground roofed only by tree crowns is open sky: the way in is the gap in the wall, not the crown rim',
       function()
  local W = gatehouse{crown = true}
  W.run(400, {skip = 9})
  local d = inspect(W, 'entrances')
  T.eq(d.sealed, false)
  T.eq(d.first.pos, {20, 27, G}, 'old code: the rim of the crowns, 15,27 (the way in moved with every crown)')
end)

T.test('BUG-503: without branches above, the same strip is inside (the rim is the first inside tile): the rule is the branch only',
       function()
  local W = gatehouse{crown = true}
  for x = 15, 19 do W.tiles[SW.key(x, 27, G + 1)].tt = SW.T.floor end        -- a built roof, not a crown
  W.run(400, {skip = 9})
  local d = inspect(W, 'entrances')
  T.ok(d.first.pos[1] < 20 and d.first.pos[2] == 27, 'the first inside tile lies in the strip: ' .. T.show(d.first.pos))
end)

T.test('BUG-504: seal.opening_ways names the other ways that stay (a door, a bridge) for the seal question', function()
  local W = gatehouse{door = true, gap = true}
  W.run(400, {skip = 9})
  local ok, r = W.K.call('seal', 'opening_ways', 35, 21, G)
  T.ok(ok and r.known)
  T.eq({r.here, r.others}, {true, 1})
  T.eq(r.where, {'30,30,9 door'})
  local ok2, r2 = W.K.call('seal', 'opening_ways', 25, 24, G)           -- a tile far from every opening
  T.eq({r2.others}, {1})                                                 -- O1 is raised: no way; the door stays
  T.eq(r2.where, {'30,30,9 door'})
end)

---------------------------------------------------------------- BUG-504: the question's text (runner side, stubbed seal)
local SX, SY, Z = 114, 73, 143
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function qworld(tag, ways)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160},
                    cfg = {baseline = {v = 2, runner = {seal_first = {esc_days = 5}, queue = {idle_days = 5}}}}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX, SY, Z, SX, SY)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load({name = 'seal', every = {ticks = 100000}, opening_ways = function() return ways end,
          wall_cuts = function() return {known = true, n = 0, cuts = {}} end})
  W.load(runner)
  W.state()
  return W
end
local function seal_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = SX .. ',' .. SY .. ',' .. Z .. ' floor'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end
local function ask(W)
  H.place(W, 'sl', seal_doc())
  local runs = 0
  local function asks()
    for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'seal_stalled' then return e end end
  end
  while not asks() and runs < 40 do H.runs(W, 1); runs = runs + 1 end
  return asks()
end

T.test('BUG-504: the wall recommendation names the way the citizens keep (old: "where the citizens keep another way", no way named)',
       function()
  local a = ask(qworld('b504a', {known = true, routes = 3, here = true, here_closable = false, others = 2, age = 0,
                                 where = {'30,30,9 door', '20,25,9 gate'}}))
  T.ok(a, 'asked')
  T.ok(a.d.how:find('they keep 30,30,9 door, 20,25,9 gate (2 other ways with a door or bridge)', 1, true), a.d.how)
  T.ok(a.d.cmd and a.d.cmd:find('"close":"wall"', 1, true), 'the wall command stays where a way stays')
end)

T.test('BUG-504: no other way with a door or bridge: no wall command, the text says so', function()
  local a = ask(qworld('b504b', {known = true, routes = 1, here = true, here_closable = false, others = 0, age = 0, where = {}}))
  T.ok(a, 'asked')
  T.eq(a.d.cmd, nil)
  T.ok(a.d.how:find('no wall: the entrance check names no other way', 1, true), a.d.how)
end)

T.test('BUG-504: an entrance check that is not known keeps the wall command and says to look first', function()
  local a = ask(qworld('b504c', {known = false}))
  T.ok(a and a.d.cmd, 'the command stays')
  T.ok(a.d.how:find('the entrance check is not known', 1, true), a.d.how)
end)

---------------------------------------------------------------- BUG-505: runner.repair and the reach check
local CUT = {known = true, n = 2, total = 9, visited = 40, partial = false,
             cuts = {{kind = 'citizen', x = 48, y = 93, z = 121, id = 60}, {kind = 'farm', x = 48, y = 93, z = 121, id = 5}}}
local NOCUT = {known = true, n = 0, cuts = {}, total = 9, visited = 40, partial = false}
local function rworld(tag, cuts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX - 2, SY, Z, SX + 2, SY)
  W.asked = {}
  W.load({name = 'seal', every = {ticks = 50}, wall_cuts = function(K, tiles) W.asked[#W.asked + 1] = tiles; return cuts end})
  W.load(runner)
  W.state()
  return W
end
local function repair(W, cells, opts)
  local ok, r1, r2 = W.K.call('runner', 'repair', cells, 'perimeter after the siege', opts)
  T.ok(ok, 'the call ran')
  return r1, r2
end
local function key_of(W, id)
  local d = W.K.persist.get('bp.' .. id)
  return d and d.stages[1].chunks[1].cells[1][4]
end

T.test('BUG-505: a repair whose wall would cut a citizen and a farm off builds a door instead (WALL_REFUSED how=repair)', function()
  local W = rworld('b505a', CUT)
  local r1, id = repair(W, {{SX, SY, Z, 'Cw'}})
  T.eq(r1, true)
  T.eq(key_of(W, id), 'd', 'old code: the wall was queued unchecked')
  T.eq(W.asked[1], {{SX, SY, Z}})
  local ev = W.find_events('WALL_REFUSED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.at, ev[1].d.how}, {{SX .. ',' .. SY .. ',' .. Z}, 'repair'})
end)

T.test('BUG-505: no cut: the wall stays a wall; doors and other cells need no check at all', function()
  local W = rworld('b505b', NOCUT)
  local r1, id = repair(W, {{SX, SY, Z, 'Cw'}})
  T.eq({r1, key_of(W, id)}, {true, 'Cw'})
  local W2 = rworld('b505c', CUT)
  local r2, id2 = repair(W2, {{SX, SY, Z, 'd'}})
  T.eq({r2, key_of(W2, id2), #W2.asked}, {true, 'd', 0})
end)

T.test('BUG-505: a closure (a bridge replaced by wall + door) that would cut is refused with the reason, not queued', function()
  local W = rworld('b505d', CUT)
  local r1, why = repair(W, {{SX, SY, Z, 'Cw'}, {SX + 1, SY, Z, 'd'}}, {peace = true, closure = true})
  T.eq(r1, false)
  T.ok(tostring(why):find('would cut 2 off the main walk group', 1, true), tostring(why))
end)

T.test('BUG-505: a reach that cannot be proven is a door as well; the refuge plug (opts.noreach) confines on purpose and is not asked',
       function()
  local W = rworld('b505e', {known = false, why = 'no citizen on a walk group'})
  local r1, id = repair(W, {{SX, SY, Z, 'Cw'}})
  T.eq({r1, key_of(W, id)}, {true, 'd'})
  local W2 = rworld('b505f', CUT)
  local r2, id2 = repair(W2, {{SX, SY, Z, 'Cw'}}, {noreach = true})
  T.eq({r2, key_of(W2, id2), #W2.asked}, {true, 'Cw', 0})
end)

T.done()
