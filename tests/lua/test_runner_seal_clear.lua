-- BUG-041 (Run 11, Kilrudrabed site98, y461 summer d45, kernel e8a28a6): the seal c1a149cf2ff540c801 hung on one piece,
-- 'door 59,62,146': kern.log 'seal first: ... built nothing for 5 days at seal.clear: 1 piece open (door 59,62,146)',
-- then 'stuck for 220 d (SEAL_STUCK)' in plan check. Read-only live data: 59,62,146 is a SHRUB in a shrub field at the
-- surface, inside the citizens' walk group 7827 (the map is 192 x 192 x 165: no map edge); its door has the wall
-- 59,63,146 beside it. The CLI's seal template (bp/defense.py) put a gather designation (quickfort #dig p, stage
-- seal.clear) before the door (seal.plant); the runner's measure waits for that tile's designation or GatherPlants job,
-- and nobody gathers: the plant gathering detail is filled only below 30 food days (economy's gather task, BUG-038),
-- the fort had 700+. quickfort builds doors and constructions on SHRUB tiles (build.lua is_valid_tile_generic, 53.16-r2:
-- FLOOR, BOULDER, PEBBLES, TWIG, SAPLING, SHRUB), so the gather step is not needed: the runner skips a seal's gather
-- cells (its piece goes on the shrub), removes a gather designation an older kernel placed (quickfort x, the player's
-- remove designation), and a SEAL_STUCK that still happens names what it waits for (d.wait: a chop nobody has the labor
-- for, a piece no citizen reaches). Every test fails on e8a28a6.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local SX, SY, Z = 59, 62, 146
local SEAL = 'c1a149cf2ff540c801'
local G = 7827                                    -- the citizens' walk group (live)
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

-- the live surroundings on z146 (game session, y461): y61 pebbles / floor / sapling, y62 three shrubs (the target in
-- the middle), y63 floor / WALL (no group) / floor; every tile but the wall on group 7827; two citizens on it
local function world(tag, o)
  o = o or {}
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {12, 12, 165}, census = {u = {cit = 2, adults = 2, ids = {1, 2}}}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  for y = SY - 1, SY + 1 do
    for x = SX - 2, SX + 1 do
      local t = W.tile(x, y, Z)
      t.c, t.g = '.', G
    end
  end
  local wall = W.tile(SX, SY + 1, Z)
  wall.c, wall.g = '#', 0
  for x = SX - 1, SX + 1 do W.tile(x, SY, Z).plant = 'shrub' end
  W.tile(SX + 1, SY - 1, Z).plant = 'sapling'
  W.add_unit{id = 1, citizen = true, pos = {SX, SY - 1, Z}}
  W.add_unit{id = 2, citizen = true, pos = {SX - 1, SY + 1, Z}}
  for _, id in ipairs({1, 2}) do W.unit(id).status.labors = o.labors and o.labors[id] or {} end
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 700, drink_d = 900, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end

-- what bp.emit('seal', {at = '59,62,146 shrub'}) wrote on e8a28a6 (the live c1a149cf2ff540c801): no seal.build stage
local function old_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '59,62,146 shrub', close = 'auto'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.clear', mode = 'dig', orders = 0, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'p'}}}}},
                    {label = 'seal.plant', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end

local function keys_sent(W, key)
  local out = {}
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do
    H.cells(c, function(x, y, z, k) if k == key then out[#out + 1] = x .. ',' .. y .. ',' .. z end end)
  end
  return out
end

T.test('Run 11 y461 replay: the seal door 59,62,146 on a shrub waited at seal.clear for a gather nobody did (no plant ' ..
       'gatherer at 700 food days); now no gather is designated, the door goes on the shrub and the seal is done',
       function()
  local W = world('replay')
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W, SEAL, old_doc())
  H.runs(W, 1)
  T.eq(keys_sent(W, 'p'), {}, 'old code: the gather designation on the shrub (quickfort #dig p)')
  T.eq(W.tile(SX, SY, Z).dig, '')
  T.eq(why(W, 'bd'), 'paused: seal ' .. SEAL, 'seal first holds while the door is open')
  H.runs(W, 2)
  T.eq(H.proj(W, SEAL).stage, 1, 'old code: stage 0 (seal.clear) until somebody gathers')
  T.ok(W.bld_at[SX .. ',' .. SY .. ',' .. Z] ~= nil, 'the door is placed on the shrub tile')
  T.ok(logged(W, 'info', '^' .. SEAL .. ' seal%.clear: no gather at 59,62,146: the door goes on the shrub %(quickfort ' ..
              'builds on shrub tiles; a gather job waits for a plant gatherer%)$'), 'kern.log says why')
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, SEAL).done, 1)
  T.eq(why(W, 'bd'), '', 'the paused bedrooms run again')
  T.eq(#W.find_events('SEAL_STUCK'), 0)
end)

T.test('the live state: a gather designation the old kernel placed is removed (quickfort x, the remove designation of ' ..
       'the designations screen) and the stage completes; a posted GatherPlants job without a flag is left to DF',
       function()
  local W = world('flag')
  W.tile(SX, SY, Z).dig = 'p'                    -- designated by e8a28a6, nobody gathered it
  H.place(W, SEAL, old_doc())
  H.runs(W, 3)
  T.eq(keys_sent(W, 'x'), {'59,62,146'}, 'old code: the stage waits for the designation')
  T.eq(W.tile(SX, SY, Z).dig, '')
  T.ok(logged(W, 'info', '^' .. SEAL .. ' seal%.clear: no gather at 59,62,146: the door goes on the shrub .*; its ' ..
              'gather designation removed$'))
  T.eq(H.proj(W, SEAL).stage, 1)
  T.ok(W.bld_at[SX .. ',' .. SY .. ',' .. Z] ~= nil)
  local W2 = world('job')
  W2.tile(SX, SY, Z).dig = 'job'                 -- DF posted the job (the flag is gone): quickfort x cannot remove it
  H.place(W2, SEAL, old_doc())
  H.runs(W2, 3)
  T.eq(keys_sent(W2, 'x'), {}, 'no remove for a tile without a designation flag')
  T.eq(H.proj(W2, SEAL).stage, 1)
  T.ok(W2.bld_at[SX .. ',' .. SY .. ',' .. Z] ~= nil, 'the door is placed all the same')
end)

-- a chop the seal waits for (seal.clear `t` on a tree branch beside the field): 57,62,146
local function chop_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '57,62,146 branch'},
          anchor = {57, SY, Z}, rot = 0,
          stages = {{label = 'seal.clear', mode = 'dig', orders = 0, defense = 1,
                     chunks = {{pos = {57, SY, Z}, cells = {{0, 0, 0, 't'}}}}}},
          manifest = {v = 2}, materials = {}}
end

T.test('a seal.clear chop that nobody takes: SEAL_STUCK names the job and the labor (d.wait), the bedrooms run again',
       function()
  local W = world('chop')
  W.tile(57, SY, Z).tree = true
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W, 'cx', chop_doc())
  H.runs(W, 8)
  T.eq(W.tile(57, SY, Z).dig, 't', 'the chop stays designated')
  local ev = W.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck after 3 days')
  T.eq(ev.d.wait, 'FellTree at 57,62,146: Wood cutting enabled for 0 of 2 citizens: nobody takes it',
       'old code: no wait')
  T.ok(ev.msg:find('; FellTree at 57,62,146: Wood cutting enabled for 0 of 2 citizens: nobody takes it', 1, true),
       ev.msg)
  T.eq(why(W, 'bd'), '')
  -- a woodcutter: the labor is not the reason; the line says so
  local W2 = world('chop2', {labors = {{CUTWOOD = true}, {}}})
  W2.tile(57, SY, Z).tree = true
  H.place(W2, 'cx', chop_doc())
  H.runs(W2, 8)
  T.eq(W2.find_events('SEAL_STUCK')[1].d.wait, 'FellTree at 57,62,146: Wood cutting enabled for 1 of 2 citizens')
end)

-- a seal door that no citizen can reach: its tile and every tile beside it (and above and below) on another walk group
local function door_doc(x, y)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = x .. ',' .. y .. ',146 floor'},
          anchor = {x, y, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 0, defense = 1,
                     chunks = {{pos = {x, y, Z}, cells = {{0, 0, 0, 'Cw'}}}}}},
          manifest = {v = 2}, materials = {wall = 1}}
end
local function island(W, x, y, g)
  for dy = -1, 1 do
    for dx = -1, 1 do
      local t = W.tile(x + dx, y + dy, Z)
      if dx ~= 0 or dy ~= 0 or t.c == '#' then t.c = '.' end
      t.g = g
    end
  end
end

T.test('a stuck seal piece no citizen reaches (revealed tiles only, informative): d.wait names its walk groups; a ' ..
       'hidden tile beside it or a reachable piece gives no claim; the map edge counts no tile outside the map',
       function()
  local W = world('island')
  island(W, 100, 100, 5018)
  H.place(W, 'w1', door_doc(100, 100))
  H.runs(W, 8)
  local ev = W.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck')
  T.eq(ev.d.wait, 'no citizen reaches wall 100,100,146 or a tile beside it (walk groups 5018; citizens 7827)',
       'old code: no wait')
  T.eq(ev.d.pieces, {'wall 100,100,146'}, 'the piece stays open (no claim drops it)')
  -- a hidden neighbour: unknown (fair play), no claim
  local W2 = world('hidden')
  island(W2, 100, 100, 5018)
  W2.tile(101, 101, Z).hidden = true
  H.place(W2, 'w1', door_doc(100, 100))
  H.runs(W2, 8)
  T.eq(W2.find_events('SEAL_STUCK')[1].d.wait, nil)
  -- one tile beside it on the citizens' group: reachable, no claim
  local W3 = world('reach')
  island(W3, 100, 100, 5018)
  W3.tile(99, 100, Z).g = G
  H.place(W3, 'w1', door_doc(100, 100))
  H.runs(W3, 8)
  T.eq(W3.find_events('SEAL_STUCK')[1].d.wait, nil)
  -- the map edge (x 0): the tiles outside the map are no standing tiles; the ones inside lie on group 5018
  local W4 = world('edge')
  island(W4, 0, 100, 5018)
  H.place(W4, 'w1', door_doc(0, 100))
  H.runs(W4, 8)
  T.eq(W4.find_events('SEAL_STUCK')[1].d.wait,
       'no citizen reaches wall 0,100,146 or a tile beside it (walk groups 5018; citizens 7827)')
end)

T.done()
