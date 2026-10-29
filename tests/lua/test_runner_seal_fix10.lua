-- Run 15c Inkintense (fix10-famine, BUG-298): the seal door 92,99,133 'not suspended, no builder has taken it' for years
-- beside 8-10 idle dwarves, outside Kern+ (y 30-73). economy.build_state names the burrow its builders keep to; seal first
-- paints the piece's own tile (only it: a perimeter door's outer side stays out) into that burrow (the burrows screen's brush) once, in PEACE, before the re-place
-- of BUG-274. Fails on 05dc764.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local SX, SY, Z = 114, 73, 143
local SEAL = 'c1a18844987fd71b01'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local AT = SX .. ',' .. SY .. ',' .. Z

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat, 1, true) then return l end end
end

-- as tests/lua/test_runner_seal_fix6.lua's world
local function world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX - 2, SY, Z, SX + 2, SY)
  W.tile(SX, SY + 1, Z).c = '#'
  W.bs = {}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z) return W.bs[x .. ',' .. y .. ',' .. z] end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load({name = 'seal', every = {ticks = 50}, opening_ways = function()
    return {known = true, routes = 1, here = true, here_closable = false, others = 0, age = 0}
  end})
  W.painted = {}
  W.act_result('burrow_tiles', function(name, tiles)
    W.painted[#W.painted + 1] = {name = name, n = #tiles, first = tiles[1]}
    return true, #tiles
  end)
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

local NOB = 'job 95916 not suspended, no builder has taken it: outside the burrow Kern+ (40 of 42 free citizens assigned to it)'

T.test('BUG-298: a seal door outside the burrow its builders keep to: SEAL_STUCK names the burrow; seal first widens ' ..
       'that burrow over the door once, waits stuck_days, then re-places as BUG-274', function()
  local W = world('burrow')
  W.bs[AT] = {id = 900, kind = 'Door', job = 95916, susp = false, work = false, items = 1, line = NOB, burrow = 'Kern+',
              bwhy = 'assigned'}
  H.place(W, SEAL, seal_doc())
  for _ = 1, 8 do H.runs(W, 1) end
  local ev = W.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck after 3 days')
  T.ok(ev.d.wait:find('outside the burrow Kern+', 1, true), ev.d.wait)
  T.eq(#W.painted, 0, 'not before 2 x stuck_days')
  for _ = 1, 6 do H.runs(W, 1) end
  T.eq(#W.painted, 1, 'old code: never widened (removed and placed again instead)')
  T.eq({W.painted[1].name, W.painted[1].n}, {'Kern+', 1})
  T.eq(W.painted[1].first, {SX, SY, Z}, 'the door tile only')
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0, 'no re-place in the same run')
  T.ok(logged(W, 'warn', 'seal first: ' .. SEAL .. ': door ' .. AT .. ' outside the burrow Kern+ its builders keep to ' ..
              '(assigned): 1 tiles added to it'))
  for _ = 1, 2 do H.runs(W, 1) end
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0, 'stuck_days of waiting after the widening')
  for _ = 1, 4 do H.runs(W, 1) end
  T.eq(#W.painted, 1, 'widened once per piece')
  T.eq(#H.qf_calls(W, 'build', 'undo'), 1, 'still untaken: re-placed (BUG-274)')
end)

T.done()
