-- Run 11 (Kilrudrabed site98 y435, kernel c75b7c0): the seal piece door 128,121,143 (project c1a147087d) stayed
-- build_lost although 26 boulders and 171 logs lay in stock. quickfort on that tile: 'Unsuitable tiles for building: 1',
-- buildings designated 0; the tile is a revealed floor without plant, building, unit or item, and a door stands on its
-- neighbour 127,121,143; `Cw` on the same tile designated at once. quickfort places a door only beside a tile of shape
-- WALL or FORTIFICATION (build.lua is_tile_generic_and_wall_adjacent; another door does not count), and the fake
-- quickfort of runner_world now applies that rule. A seal door quickfort refuses is planned once as a constructed wall
-- on the same tile (runner door_walls), kern.log, PROJECT_BLOCKED and PROJECT_DONE name it, and a seal an older kernel
-- left build_lost with such a door is retried once for it.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local Z = 143
local ID = 'c1a147087d'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end

-- the live tiles: floor 126-130 x 119-123 on z143, a built door on 127,121 (legend '+'), the seal piece on 128,121
local function world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}           -- as in DF: the planned buildings by tile (Lua API.txt:2484)
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, 126, 119, Z, 130, 123)
  local door = H.hatch(W, 127, 121, Z, '.')
  W.buildings[door]._bld = 'Door'
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end})
  return W
end

local function seal_doc(cells)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '128,121,143 floor'},
          anchor = {128, 121, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {128, 121, Z}, cells = cells}}}},
          manifest = {v = 2}, materials = {door = #cells}}
end

local function keys(c)                -- the cell texts of one quickfort call, in x order
  local out = {}
  H.cells(c, function(x, _, _, _, _, _, text) out[#out + 1] = x .. ':' .. text end)
  return table.concat(out, ' ')
end

T.test('Run 11 (site98 y435): a seal door quickfort refuses is planned once as a wall on the same tile, not ' ..
       'build_lost; the log line and PROJECT_DONE name it', function()
  local W = world('live435')
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'd'}}))
  H.runs(W, 1)
  local runs = H.qf_calls(W, 'build', 'run')
  T.eq(#runs, 2, 'the door, then the wall in the next slice')
  T.eq({keys(runs[1]), keys(runs[2])}, {'128:d', '128:Cw'})
  T.ok(logged(W, 'warn', '^' .. ID .. ' seal%.build: door unsuitable at 128,121,143: wall instead %(quickfort refused ' ..
              'the door; no wall or fortification beside it%)$'), 'the kern.log line')
  local d = W.K.persist.get('bp.' .. ID)
  T.eq({d.stages[1].chunks[1].cells[1][4], d.materials}, {'Cw', {wall = 1}})
  T.eq(W.K.persist.get('m.runner').dw[ID], {'128,121,143'})
  H.build(W)
  H.runs(W, 2)
  local P = H.proj(W, ID)
  T.eq({P.done, P.blocked}, {1, ''}, 'old code: the door again and again, build_lost')
  T.eq(W.tile(128, 121, Z).c, 'C')
  T.eq(#W.find_events('PROJECT_BLOCKED'), 0)
  local ev = W.find_events('PROJECT_DONE')[1]
  T.eq(ev.msg, ID .. ' (seal) done; door unsuitable at 128,121,143: wall instead')
  T.eq(ev.d, {proj = ID, tpl = 'seal', walled = {'128,121,143'}})
  T.eq(W.K.persist.get('m.runner').dw[ID], nil, 'the record goes with the project')
end)

T.test('Run 11: a door with a wall beside it stays a door; only the refused one of a chunk becomes a wall', function()
  local W = world('mixed435')
  H.floor(W, 140, 121, Z, 140, 121)                    -- a 1-tile doorway in the rock: the door stands
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'd'}, {12, 0, 0, 'd'}}))
  H.runs(W, 1)
  local runs = H.qf_calls(W, 'build', 'run')
  T.eq({#runs, keys(runs[1]), keys(runs[2])}, {2, '128:d 140:d', '128:Cw 140:d'})
  T.eq(W.K.persist.get('m.runner').dw[ID], {'128,121,143'})
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, ID).done, 1, 'the door placed in the first call is not counted as lost')
  T.eq(W.find_events('PROJECT_DONE')[1].d.walled, {'128,121,143'})
  T.eq(#H.qf_calls(W, 'build', 'run'), 2, 'no re-apply')
end)

T.test('Run 11: the wall refused too: the door is never repeated; PROJECT_BLOCKED names the walled door', function()
  local W = world('both435')
  W.unsuitable['128,121,143'] = true                   -- the tile takes nothing
  W.load(runner)
  H.place(W, ID, seal_doc({{0, 0, 0, 'd'}}))
  for _ = 1, runner.CFG.remake_max + 4 do H.runs(W, 1) end
  local doors = 0
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do if keys(c) == '128:d' then doors = doors + 1 end end
  T.eq(doors, 1, 'the door once, then the wall only')
  T.eq(H.proj(W, ID).blocked, 'build_lost')
  H.runs(W, 5)
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.ok(pb[1].msg:find(ID .. ' (seal) blocked: build_lost at seal.build, missing Cw; door unsuitable at 128,121,143: ' ..
                      'wall instead; retry 1/8', 1, true), pb[1].msg)
  T.eq(pb[1].d.walled, {'128,121,143'})
  T.eq(pb[1].d.missing, {'Cw'})
end)

T.test('Run 11: c1a147087d as kernel c75b7c0 left it (build_lost with its door, material at hand) is retried for ' ..
       'the door within a day and walled', function()
  local W = world('old435')
  local t = W.K.now().tick
  local d = seal_doc({{0, 0, 0, 'd'}})
  d.id = ID
  W.K.persist.set('projects', {v = 2, list = {{id = ID, tpl = 'seal', site = 'S1', class = 'defense', prio = 4,
    stage = 0, chunk = 1, pct = 0, blocked = 'build_lost', since = t - 3 * DAY, created = t - 10 * DAY, done = 0,
    orders_done = 1}}})
  W.K.persist.set('bp.' .. ID, d)
  W.K.persist.set('m.runner', {v = 2, rty = {[ID] = {n = 1, t = t - 3 * DAY, c = t - 3 * DAY}}})
  W.load(runner)
  H.runs(W, 1)                                         -- the retry baseline (economy can make the door: cant false)
  T.eq(H.proj(W, ID).blocked, 'build_lost')
  H.runs(W, 2)
  T.ok(logged(W, 'info', '^' .. ID .. ': build_lost at seal%.build, retry 2/8 from seal%.build %(its door at ' ..
              '128,121,143 has no wall or fortification beside it: a wall if quickfort refuses the door%)$'),
       'old code: no retry before a season has passed')
  H.runs(W, 1)
  T.ok(logged(W, 'warn', 'door unsuitable at 128,121,143: wall instead'))
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, ID).done, 1)
  T.eq(W.tile(128, 121, Z).c, 'C')
  T.eq(W.K.persist.get('m.runner').rty[ID], nil)
  -- once: a door the snapshot shows without a wall but quickfort takes (a hidden wall) is not retried again
  local W2 = world('once435')
  local t2 = W2.K.now().tick
  W2.K.persist.set('projects', {v = 2, list = {{id = ID, tpl = 'seal', site = 'S1', class = 'defense', prio = 4,
    stage = 0, chunk = 1, pct = 0, blocked = 'build_lost', since = t2 - 3 * DAY, created = t2 - 10 * DAY, done = 0,
    orders_done = 1}}})
  W2.K.persist.set('bp.' .. ID, seal_doc({{0, 0, 0, 'd'}}))
  W2.K.persist.set('m.runner', {v = 2, rty = {[ID] = {n = 1, t = t2 - 3 * DAY, c = t2 - 3 * DAY, dw = 1}}})
  W2.load(runner)
  H.runs(W2, 6)
  T.eq(H.proj(W2, ID).blocked, 'build_lost', 'the one retry for the door was spent')
end)

T.done()
