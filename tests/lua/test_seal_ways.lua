-- BUG-044 (Run 11 y483-y497): the runner replaces a seal door that stays stuck by a constructed wall, but only where the
-- citizens keep another way. seal.opening_ways answers that from the last entrance check (the openings between the map
-- edge and the interior): is the tile at an opening, does that opening have a door or a bridge on it, how many other
-- openings do. Every test fails on f17e2b3 (no seal.opening_ways).
local T = require('testlib')
local SW = require('seal_world')

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end

-- the gatehouse of test_seal.lua (z 9): field ',' x0-63 y0-63; fort walls x20-40 y20-30, hall x21-39 y21-29; the bridge O1
-- at 20,25 (lowered: a route), a door 30,30 in the south wall (a route with a door; `wide`: the tile 31,30 beside it is
-- open floor), a plain gap 35,20 in the north wall
local G = 9
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}, {26, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}
local function gatehouse(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = MAN}}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'='}, 20, 25)
  if opts.door ~= false then SW.draw(W, G, {'+'}, 30, 30) end
  if opts.wide then SW.draw(W, G, {'.'}, 31, 30) end        -- a second tile beside the door: the opening is 2 wide
  if opts.gap then SW.draw(W, G, {'.'}, 35, 20) end
  W.o1 = W.dyn[SW.key(20, 25, G)]
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.gate_state = 'down'
  W.gate = SW.fake('gate', {state = function(K, b) if b == nil then return {} end return W.gate_state end,
                            fire = function(K, s) end})
  W.load(W.gate)
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  local M = seal()
  W.load(M)
  return W, M
end

local function ways(W, x, y)
  local ok, r = W.K.call('seal', 'opening_ways', x, y, G)
  T.ok(ok, 'seal.opening_ways is called')
  return r
end

T.test('BUG-044: before the first entrance check nothing is known', function()
  local W = gatehouse()
  T.eq(ways(W, 30, 30), {known = false})
end)

T.test('BUG-044: a tile beside the door of a wide opening: a wall there leaves the door as the way (here_closable); a ' ..
       'plain gap and a tile far from every opening are not; the other openings with a door or a bridge are counted',
       function()
  local W = gatehouse{wide = true, gap = true}
  W.run(400, {skip = 9})
  local r = ways(W, 31, 30)                            -- the open tile beside the door 30,30
  T.eq({r.known, r.here, r.here_closable, r.others, r.routes}, {true, true, true, 1, 3})
  T.ok(r.age >= 0 and r.age < 1200, 'age in ticks: ' .. tostring(r.age))
  -- the plain gap in the north wall: no door on it, but the door and the bridge elsewhere
  r = ways(W, 35, 21)
  T.eq({r.known, r.here, r.here_closable, r.others}, {true, true, false, 2})
  -- a tile far from every opening
  r = ways(W, 25, 24)
  T.eq({r.here, r.here_closable, r.others}, {false, false, 2})
end)

T.test('BUG-044: the tile of a narrow opening with a door is no sibling: a wall on the route could cut the door off', function()
  local W = gatehouse{}
  W.run(400, {skip = 9})
  local r = ways(W, 30, 29)                            -- inside the door, 1 wide
  T.eq({r.known, r.here, r.here_closable, r.others}, {true, true, false, 1})
end)

T.test('BUG-044: the only opening, without a door or a bridge: no other way (others 0)', function()
  local W = gatehouse{door = false}
  SW.draw(W, G, {'#'}, 20, 25)                         -- no bridge: wall it
  SW.draw(W, G, {'.'}, 35, 20)                         -- one plain gap in the north wall
  SW.regroup(W)
  W.run(400, {skip = 9})
  local r = ways(W, 35, 21)
  T.eq({r.known, r.here, r.here_closable, r.others, r.routes}, {true, true, false, 0, 1})
end)

T.done()
